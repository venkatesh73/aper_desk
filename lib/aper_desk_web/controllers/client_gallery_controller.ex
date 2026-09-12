defmodule AperDeskWeb.ClientGalleryController do
  @moduledoc """
  The session round-trip behind a gated gallery.

  A LiveView cannot write the session — it runs in its own process long after
  the cookie was sent — so the code is checked in the LiveView and the *result*
  is carried here by a short-lived signed token, which is the only thing this
  controller trusts. Holding the unlock in the session rather than in the
  socket is what makes a refresh not ask for a new code.
  """
  use AperDeskWeb, :controller

  @salt "gallery unlock"
  @max_age 60
  @keep 20

  @doc "Stamp a verified gallery into the session, then hand back to the gallery."
  def unlock(conn, %{"token" => token, "pass" => pass}) do
    case Phoenix.Token.verify(AperDeskWeb.Endpoint, @salt, pass, max_age: @max_age) do
      {:ok, gallery_id} ->
        conn
        |> put_session("unlocked_galleries", add(unlocked(conn), gallery_id))
        |> redirect(to: ~p"/g/#{token}")

      {:error, _reason} ->
        # An expired or forged pass is not an error worth explaining. Send them
        # back to the gate, which will ask for a code again.
        redirect(conn, to: ~p"/g/#{token}")
    end
  end

  def unlock(conn, %{"token" => token}), do: redirect(conn, to: ~p"/g/#{token}")

  @doc "Sign the fact that this browser proved itself for `gallery_id`."
  def sign(gallery_id), do: Phoenix.Token.sign(AperDeskWeb.Endpoint, @salt, gallery_id)

  @doc "The gallery ids this session has already unlocked."
  def unlocked(conn), do: get_session(conn, "unlocked_galleries") || []

  # Bounded, because this rides in a cookie. A client who has opened twenty
  # galleries is not going to notice the oldest being asked for again.
  defp add(ids, id), do: [id | List.delete(ids, id)] |> Enum.take(@keep)
end
