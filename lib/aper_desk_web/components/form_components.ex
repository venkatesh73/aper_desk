defmodule AperDeskWeb.FormComponents do
  @moduledoc """
  Form building blocks with one consistent layout.

  Every form was previously bare `<label>` and `<input>` siblings, which the
  design system styles individually but never spaces — so labels sat a pixel
  from their controls, nothing was grouped, and the submit button touched the
  last field. Wrapping each control in a `.field` gives the whole application
  one vertical rhythm, defined in one place.

  These are deliberately not `CoreComponents.input/1`: that carries daisyUI
  classes this application does not load, and mixing the two produces a control
  with two competing sets of rules.
  """

  # Phoenix.Component directly, not `use AperDeskWeb, :html` — that imports this
  # module, and a module cannot import itself while being defined.
  use Phoenix.Component

  import AperDeskWeb.CoreComponents, only: [errors: 1]

  @doc """
  One labelled control.

  Renders the label, the control, its hint and its errors as a single unit, so
  the space inside a field always reads as tighter than the space between two.
  """
  attr :label, :string, default: nil
  attr :for, :string, default: nil
  attr :hint, :string, default: nil
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true
  slot :hint_block

  def field(assigns) do
    ~H"""
    <div class={classes(["field", @class])}>
      <label :if={@label} for={@for}>{@label}</label>
      {render_slot(@inner_block)}
      <span :if={@hint} class="formhint">{@hint}</span>
      <span :if={@hint_block != []} class="formhint">{render_slot(@hint_block)}</span>
      <.errors :if={@field} field={@field} />
    </div>
    """
  end

  @doc "A text-like input inside a labelled field."
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :type, :string, default: "text"
  attr :value, :any, default: :from_field

  attr :rest, :global,
    include:
      ~w(placeholder required autocomplete min max step minlength maxlength inputmode pattern)

  def text_field(assigns) do
    assigns = assign_new(assigns, :id, fn -> assigns.field.id end)

    ~H"""
    <.field label={@label} for={@id} hint={@hint} field={@field}>
      <input
        type={@type}
        id={@id}
        name={@field.name}
        value={if @value == :from_field, do: normalise(@field.value), else: @value}
        class={invalid(@field)}
        {@rest}
      />
    </.field>
    """
  end

  @doc "A multi-line input inside a labelled field."
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :rows, :integer, default: 4
  attr :rest, :global, include: ~w(placeholder required)

  def textarea_field(assigns) do
    assigns = assign_new(assigns, :id, fn -> assigns.field.id end)

    ~H"""
    <.field label={@label} for={@id} hint={@hint} field={@field}>
      <textarea id={@id} name={@field.name} rows={@rows} class={invalid(@field)} {@rest}>{normalise(@field.value)}</textarea>
    </.field>
    """
  end

  @doc """
  A native select inside a labelled field.

  For anything a person might have to search — a contact, a package — use
  `AperDeskWeb.Combobox` instead. A native select cannot be filtered.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :options, :list, required: true
  attr :prompt, :string, default: nil
  attr :rest, :global, include: ~w(required)

  def select_field(assigns) do
    assigns = assign_new(assigns, :id, fn -> assigns.field.id end)

    ~H"""
    <.field label={@label} for={@id} hint={@hint} field={@field}>
      <select id={@id} name={@field.name} class={invalid(@field)} {@rest}>
        <option :if={@prompt} value="">{@prompt}</option>
        <option
          :for={{label, value} <- normalise_options(@options)}
          value={value}
          selected={to_string(value) == to_string(normalise(@field.value))}
        >
          {label}
        </option>
      </select>
    </.field>
    """
  end

  @doc """
  A searchable picker inside a labelled field.

  Use this instead of `select_field/1` once a list is long enough that scanning
  it stops being reasonable — roughly ten options, or any list that grows with
  the studio's data. Below that a native select is better: it is lighter, it
  needs no round trip, and a search box over three options is friction.

  ## Example

      <.combo_field
        field={@form[:shoot_type]}
        id="lead-shoot-type"
        label="Shoot type"
        options={Enum.map(shoot_types(), &{humanise(&1), &1})}
      />
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :id, :string, required: true
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :options, :list, required: true
  attr :prompt, :string, default: "Choose one"
  attr :search_placeholder, :string, default: "Type to search"
  attr :empty_message, :string, default: "Nothing matched"
  attr :allow_clear, :boolean, default: true

  def combo_field(assigns) do
    ~H"""
    <.field label={@label} hint={@hint} field={@field}>
      <.live_component
        module={AperDeskWeb.Combobox}
        id={@id}
        name={@field.name}
        value={@field.value}
        options={@options}
        prompt={@prompt}
        search_placeholder={@search_placeholder}
        empty_message={@empty_message}
        allow_clear={@allow_clear}
      />
    </.field>
    """
  end

  @doc "A checkbox that reads as one line, with the hidden false companion."
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :checked_default, :boolean, default: false

  def checkbox_field(assigns) do
    assigns = assign_new(assigns, :id, fn -> assigns.field.id end)

    ~H"""
    <label class="checkfield" for={@id}>
      <input type="hidden" name={@field.name} value="false" />
      <input
        type="checkbox"
        id={@id}
        name={@field.name}
        value="true"
        checked={checked?(@field.value, @checked_default)}
      />
      <span>
        {@label}
        <span :if={@hint} class="formhint">{@hint}</span>
      </span>
    </label>
    """
  end

  @doc "A titled group of fields, separated by a rule."
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <div class="sect">
      <div :if={@title} class="sect-head">
        <h3>{@title}</h3>
        <p :if={@description}>{@description}</p>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The submit row, ruled off from the fields above it."
  slot :inner_block, required: true

  def form_actions(assigns) do
    ~H"""
    <div class="form-actions">{render_slot(@inner_block)}</div>
    """
  end

  @doc "Two or three controls that belong on one line."
  attr :layout, :string, default: "two", values: ~w(two amount wide-narrow)
  slot :inner_block, required: true

  def row(assigns) do
    ~H"""
    <div class={classes(["row", @layout])}>{render_slot(@inner_block)}</div>
    """
  end

  ## Internals

  # Joins only the classes actually set. A nil left in the list renders as a
  # trailing space — harmless to a browser, but it means `class="field "` rather
  # than `class="field"`, which anything matching on the attribute misses.
  defp classes(list) do
    list
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join(" ")
  end

  defp invalid(field) do
    if field_errors?(field), do: "invalid", else: nil
  end

  defp field_errors?(%Phoenix.HTML.FormField{errors: errors, form: %{source: %{action: action}}})
       when not is_nil(action),
       do: errors != []

  defp field_errors?(_field), do: false

  # A Date or DateTime has to reach an <input> as a string, and nil has to reach
  # it as "" rather than the word "nil".
  defp normalise(nil), do: ""
  defp normalise(%Date{} = date), do: Date.to_iso8601(date)
  defp normalise(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp normalise(%Decimal{} = decimal), do: Decimal.to_string(decimal)
  defp normalise(value) when is_binary(value), do: value
  defp normalise(value), do: to_string(value)

  defp normalise_options(options) do
    Enum.map(options, fn
      {label, value} -> {label, value}
      value -> {value, value}
    end)
  end

  defp checked?(value, default) do
    case value do
      nil -> default
      true -> true
      "true" -> true
      false -> false
      "false" -> false
      _ -> default
    end
  end
end
