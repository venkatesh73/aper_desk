defmodule AperDesk.Templating do
  @moduledoc """
  The `{{token}}` substitution shared by email and contract templates, and the
  sample data a preview renders against.

  It lives here rather than in either schema because both use the same syntax
  and a studio writing a contract expects the same tokens that work in an
  email. Two implementations would drift, and the one that drifted would be
  discovered in a client's inbox.

  Unknown tokens are left as written rather than blanked. A client receiving
  "Hi {{first_name}}" is embarrassing, but a silent empty string reads as a
  half-finished sentence and is much harder to notice in a test send.
  """

  alias AperDesk.Accounts.Studio
  alias AperDesk.Formats
  alias AperDesk.Scope

  @tokens ~w(
    first_name name email phone
    shoot_type shoot_date venue
    studio_name package_name total deposit balance_due
  )

  @doc "Every token a template may use, for the form's own hint and the preview."
  def tokens, do: @tokens

  @doc "Substitute `{{token}}` placeholders in `text` from `assigns`."
  def interpolate(nil, _assigns), do: nil

  def interpolate(text, assigns) when is_binary(text) do
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

  @doc """
  Plausible values for every token, for previewing a template.

  Real where the studio knows it — its own name, its currency, its date
  format — and invented where it cannot. A preview against blank strings would
  show a layout the studio never actually sends, and one against `{{token}}`
  left literal would not answer the question the preview is being asked.
  """
  def sample_assigns(subject \\ nil) do
    studio_name = studio_name(subject)
    date = sample_date(subject)

    %{
      "first_name" => "Anna",
      "name" => "Anna Bell",
      "email" => "anna@example.com",
      "phone" => "+351 912 345 678",
      "shoot_type" => "Wedding",
      "shoot_date" => date,
      "venue" => "Quinta da Regaleira",
      "studio_name" => studio_name,
      "package_name" => "Full day coverage",
      "total" => money(subject, 450_000),
      "deposit" => money(subject, 112_500),
      "balance_due" => money(subject, 337_500)
    }
  end

  defp studio_name(%Scope{studio: %Studio{name: name}}) when is_binary(name), do: name
  defp studio_name(%Studio{name: name}) when is_binary(name), do: name
  defp studio_name(_subject), do: "Your studio"

  defp sample_date(subject) do
    date = Date.add(Formats.today_for(subject), 120)
    Formats.date(subject, date)
  end

  defp money(subject, cents) do
    cents
    |> AperDesk.Money.new(currency(subject))
    |> AperDesk.Money.to_string()
  end

  defp currency(%Scope{currency: currency}) when is_binary(currency), do: currency
  defp currency(_subject), do: "USD"
end
