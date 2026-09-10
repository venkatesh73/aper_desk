defmodule AperDeskWeb.Graphql.Middleware.HandleErrors do
  @moduledoc """
  Turns the tagged errors contexts return into GraphQL errors a client can act
  on.

  Contexts return things like `{:error, {:limit_reached, "active_leads", 50, 50}}`.
  Rendering that with `inspect/1` would give the mobile app a string to
  pattern-match, which is how clients end up parsing error prose. Instead each
  shape becomes a message plus a stable machine-readable `code`, so the app can
  branch on the code and show the message.
  """

  @behaviour Absinthe.Middleware

  def call(resolution, _config) do
    %{resolution | errors: Enum.flat_map(resolution.errors, &format/1)}
  end

  defp format({:limit_reached, key, used, limit}) do
    [
      %{
        message: "Your plan allows #{limit} #{humanise(key)}; you are using #{used}.",
        code: "LIMIT_REACHED",
        limit_key: key,
        used: used,
        limit: limit
      }
    ]
  end

  defp format(:unauthorized),
    do: [%{message: "You do not have permission to do that.", code: "FORBIDDEN"}]

  defp format(:not_found), do: [%{message: "Not found.", code: "NOT_FOUND"}]

  defp format(:invalid_credentials),
    do: [%{message: "That email and password do not match.", code: "INVALID_CREDENTIALS"}]

  defp format(:already_recorded),
    do: [%{message: "That payment has already been recorded.", code: "ALREADY_RECORDED"}]

  defp format({:clash, assignments}) do
    [
      %{
        message: "That person is already committed for part of this window.",
        code: "SCHEDULE_CLASH",
        clashing_ids: Enum.map(assignments, & &1.id)
      }
    ]
  end

  defp format(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message ->
        %{message: "#{humanise(field)} #{message}", code: "VALIDATION", field: to_string(field)}
      end)
    end)
  end

  defp format(message) when is_binary(message), do: [%{message: message}]
  defp format(%{message: _} = error), do: [error]
  defp format(other), do: [%{message: to_string(inspect(other)), code: "ERROR"}]

  defp humanise(key),
    do: key |> to_string() |> String.replace("_", " ")
end
