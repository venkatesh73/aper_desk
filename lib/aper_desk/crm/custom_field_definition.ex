defmodule AperDesk.Crm.CustomFieldDefinition do
  @moduledoc """
  A studio-defined extra field.

  The definition lives here; the values live in the entity's `custom_fields`
  JSONB column. Splitting them that way means adding a field is an INSERT
  rather than a migration — photographers add "venue postcode" and "how did you
  hear about us?" constantly, and neither should require a deploy.

  The cost is that values are not constrained by the database, so `validate/2`
  is the only thing standing between a definition and junk data. It is called
  from the CRM context on every write.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio

  @entities ~w(lead contact job)
  @field_types ~w(text textarea number date select checkbox url)

  schema "custom_field_definitions" do
    belongs_to :studio, Studio

    field :entity, :string, default: "lead"
    field :key, :string
    field :label, :string
    field :field_type, :string, default: "text"
    field :options, {:array, :string}, default: []
    field :required, :boolean, default: false
    field :position, :integer, default: 0

    timestamps()
  end

  def entities, do: @entities
  def field_types, do: @field_types

  def changeset(definition, attrs) do
    definition
    |> cast(attrs, [
      :studio_id,
      :entity,
      :key,
      :label,
      :field_type,
      :options,
      :required,
      :position
    ])
    |> validate_required([:studio_id, :key, :label])
    |> validate_inclusion(:entity, @entities)
    |> validate_inclusion(:field_type, @field_types)
    |> validate_format(:key, ~r/^[a-z][a-z0-9_]*$/,
      message:
        "must start with a letter and contain only lowercase letters, numbers and underscores"
    )
    |> validate_select_options()
    |> unique_constraint([:studio_id, :entity, :key], message: "already exists")
  end

  @doc """
  Validate a `custom_fields` map against `definitions`.

  Returns `{:ok, values}` with unknown keys dropped, or `{:error, errors}`.
  Values are coerced to the declared type so a number field does not end up
  holding the string "12" for some records and the integer 12 for others —
  which would make every later comparison and sum subtly wrong.
  """
  def validate(definitions, values) when is_list(definitions) and is_map(values) do
    known = Map.new(definitions, &{&1.key, &1})
    kept = Map.take(values, Map.keys(known))

    {coerced, errors} =
      Enum.reduce(known, {%{}, []}, fn {key, definition}, {acc, errors} ->
        case Map.fetch(kept, key) do
          :error ->
            if definition.required do
              {acc, [{key, "is required"} | errors]}
            else
              {acc, errors}
            end

          {:ok, value} ->
            case coerce(definition, value) do
              {:ok, coerced_value} -> {Map.put(acc, key, coerced_value), errors}
              {:error, message} -> {acc, [{key, message} | errors]}
            end
        end
      end)

    case errors do
      [] -> {:ok, coerced}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp coerce(%__MODULE__{required: true}, value) when value in [nil, ""],
    do: {:error, "is required"}

  defp coerce(%__MODULE__{}, value) when value in [nil, ""], do: {:ok, nil}

  defp coerce(%__MODULE__{field_type: "number"}, value) do
    case value do
      n when is_integer(n) or is_float(n) ->
        {:ok, n}

      s when is_binary(s) ->
        case Float.parse(s) do
          {n, ""} -> {:ok, n}
          _ -> {:error, "must be a number"}
        end

      _ ->
        {:error, "must be a number"}
    end
  end

  defp coerce(%__MODULE__{field_type: "checkbox"}, value) do
    case value do
      b when is_boolean(b) -> {:ok, b}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, "must be true or false"}
    end
  end

  defp coerce(%__MODULE__{field_type: "date"}, value) do
    case value do
      %Date{} = d ->
        {:ok, Date.to_iso8601(d)}

      s when is_binary(s) ->
        case Date.from_iso8601(s) do
          {:ok, d} -> {:ok, Date.to_iso8601(d)}
          _ -> {:error, "must be a date"}
        end

      _ ->
        {:error, "must be a date"}
    end
  end

  defp coerce(%__MODULE__{field_type: "select", options: options}, value) do
    if to_string(value) in options do
      {:ok, to_string(value)}
    else
      {:error, "must be one of: #{Enum.join(options, ", ")}"}
    end
  end

  defp coerce(%__MODULE__{}, value), do: {:ok, to_string(value)}

  # A select with no options renders as an empty dropdown nobody can complete.
  defp validate_select_options(changeset) do
    if get_field(changeset, :field_type) == "select" and
         get_field(changeset, :options) in [nil, []] do
      add_error(changeset, :options, "a select field needs at least one option")
    else
      changeset
    end
  end
end
