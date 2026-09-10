defmodule AperDesk.Comms.LeadCaptureForm do
  @moduledoc """
  An embeddable enquiry form.

  The field definitions live in `fields` as data rather than as a schema per
  form, because photographers add "how did you hear about us?" and "venue
  postcode" constantly and neither a migration nor a deploy should be involved.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}

  @field_types ~w(text textarea email phone date select checkbox number)

  schema "lead_capture_forms" do
    belongs_to :studio, Studio
    belongs_to :assign_to, User

    field :name, :string
    field :slug, :string
    field :headline, :string
    field :intro, :string
    field :success_message, :string
    field :fields, :map, default: %{}
    field :notify_emails, {:array, :string}, default: []
    field :redirect_url, :string
    field :active, :boolean, default: true
    field :submission_count, :integer, default: 0

    timestamps()
  end

  def field_types, do: @field_types

  def changeset(form, attrs) do
    form
    |> cast(attrs, [
      :studio_id,
      :assign_to_id,
      :name,
      :slug,
      :headline,
      :intro,
      :success_message,
      :fields,
      :notify_emails,
      :redirect_url,
      :active
    ])
    |> validate_required([:studio_id, :name])
    |> put_slug()
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "may only contain lowercase letters, numbers and hyphens"
    )
    |> validate_field_definitions()
    |> unique_constraint([:studio_id, :slug])
  end

  @doc "The ordered field definitions, as a list."
  def field_list(%__MODULE__{fields: %{"fields" => fields}}) when is_list(fields), do: fields
  def field_list(%__MODULE__{}), do: []

  @doc "The field keys a submission is allowed to carry."
  def permitted_keys(%__MODULE__{} = form),
    do: form |> field_list() |> Enum.map(&Map.get(&1, "key")) |> Enum.reject(&is_nil/1)

  @doc """
  Validate a public submission against the form's own definition.

  Returns `{:ok, answers}` with unknown keys dropped, or `{:error, errors}`.
  Unknown keys are dropped rather than rejected so that a stale cached copy of
  an embedded form still submits successfully after a field is removed.
  """
  def validate_submission(%__MODULE__{} = form, answers) when is_map(answers) do
    definitions = field_list(form)
    permitted = permitted_keys(form)
    kept = Map.take(answers, permitted)

    errors =
      for definition <- definitions,
          definition["required"] in [true, "true"],
          blank?(Map.get(kept, definition["key"])),
          do: {definition["key"], "is required"}

    case errors do
      [] -> {:ok, kept}
      errors -> {:error, errors}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?([]), do: true
  defp blank?(_), do: false

  defp put_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        case get_field(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :slug, slugify(name))
        end

      slug ->
        put_change(changeset, :slug, slugify(slug))
    end
  end

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
  end

  # A form whose definition is malformed renders as a blank page on the
  # client's site, so reject it at save time rather than at render time.
  defp validate_field_definitions(changeset) do
    case get_field(changeset, :fields) do
      %{"fields" => fields} when is_list(fields) ->
        if Enum.all?(fields, &valid_definition?/1) do
          changeset
        else
          add_error(changeset, :fields, "each field needs a key, a label and a known type")
        end

      %{} ->
        changeset

      _ ->
        add_error(changeset, :fields, "must be a map")
    end
  end

  defp valid_definition?(%{"key" => key, "label" => label, "type" => type})
       when is_binary(key) and is_binary(label),
       do: type in @field_types and key != ""

  defp valid_definition?(_), do: false
end
