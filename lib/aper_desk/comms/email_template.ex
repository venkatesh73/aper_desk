defmodule AperDesk.Comms.EmailTemplate do
  @moduledoc """
  A reusable message.

  `system_template` marks the starter set seeded per shoot type. Those can be
  edited but not deleted, so the automation that references one by `key` cannot
  be left pointing at nothing.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio

  schema "email_templates" do
    belongs_to :studio, Studio

    field :key, :string
    field :name, :string
    field :subject, :string
    field :body, :string
    field :shoot_type, :string
    field :system_template, :boolean, default: false
    field :archived_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [
      :studio_id,
      :key,
      :name,
      :subject,
      :body,
      :shoot_type,
      :system_template
    ])
    |> validate_required([:studio_id, :key, :name, :subject, :body])
    |> validate_format(:key, ~r/^[a-z0-9_]+$/,
      message: "may only contain lowercase letters, numbers and underscores"
    )
    |> unique_constraint([:studio_id, :key])
  end

  @doc """
  Render a template against `assigns`, substituting `{{token}}` placeholders.

  Unknown tokens are left as-is rather than blanked: a client receiving
  "Hi {{first_name}}" is embarrassing, but a silent empty string reads as a
  half-written message and is harder to notice in a test send.
  """
  def render(%__MODULE__{} = template, assigns) when is_map(assigns) do
    %{subject: interpolate(template.subject, assigns), body: interpolate(template.body, assigns)}
  end

  defp interpolate(nil, _assigns), do: nil

  defp interpolate(text, assigns) do
    Regex.replace(~r/\{\{\s*([a-z0-9_.]+)\s*\}\}/i, text, fn full, key ->
      case fetch_token(assigns, key) do
        {:ok, value} -> to_string(value)
        :error -> full
      end
    end)
  end

  defp fetch_token(assigns, key) do
    case Map.fetch(assigns, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(assigns, String.to_existing_atom(key))
    end
  rescue
    # An unknown token must not create an atom from user-supplied template text.
    ArgumentError -> :error
  end
end
