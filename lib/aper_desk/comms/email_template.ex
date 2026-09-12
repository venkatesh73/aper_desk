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

  The substitution itself is `AperDesk.Templating.interpolate/2`, shared with
  contract templates so the two cannot drift.
  """
  def render(%__MODULE__{} = template, assigns) when is_map(assigns) do
    %{
      subject: AperDesk.Templating.interpolate(template.subject, assigns),
      body: AperDesk.Templating.interpolate(template.body, assigns)
    }
  end
end
