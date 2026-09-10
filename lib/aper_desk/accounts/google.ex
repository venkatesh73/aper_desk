defmodule AperDesk.Accounts.Google do
  @moduledoc """
  Google sign-in, over OAuth 2.0 with OpenID Connect.

  Hand-rolled on `Req` rather than pulling in an OAuth stack, because the parts
  that matter here are the parts a library would hide: which claims we trust,
  when we are willing to link a Google account to an existing password account,
  and what happens when the two disagree.

  **`state` is mandatory.** It is minted here, stored in the session, and
  compared on the way back. Without it, an attacker can complete their own
  Google flow and have the victim's browser deliver the resulting code —
  logging the victim into the attacker's account.

  **Only a verified email may link to an existing account.** Google reports
  `email_verified`, and for some Workspace configurations it is false. Linking
  on an unverified address would let anyone who can create a Google account
  claiming `you@example.com` take over that AperDesk account.

  Configured from `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`. When they are
  absent the feature reports itself unconfigured and the button is not shown,
  rather than offering a flow that dead-ends at Google's error page.
  """

  @authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @userinfo_url "https://openidconnect.googleapis.com/v1/userinfo"

  @doc "Whether Google sign-in is configured. Drives whether the button renders."
  def configured? do
    config = config()

    is_binary(config[:client_id]) and is_binary(config[:client_secret]) and
      config[:client_id] != "" and config[:client_secret] != ""
  end

  @doc """
  The URL to send someone to, and the `state` to remember.

  Returns `{url, state}`. The caller must put `state` in the session and check
  it on the callback.
  """
  def authorize_url(redirect_uri) do
    state = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    query =
      URI.encode_query(%{
        "client_id" => config()[:client_id],
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => "openid email profile",
        "state" => state,
        # Ask for a fresh choice rather than silently reusing whichever account
        # the browser happens to be signed into.
        "prompt" => "select_account"
      })

    {"#{@authorize_url}?#{query}", state}
  end

  @doc """
  Exchange the callback code for the signed-in person's profile.

  Returns `{:ok, profile}` with `:sub`, `:email`, `:email_verified`, `:name`
  and `:picture`, or `{:error, reason}`.
  """
  def fetch_profile(code, redirect_uri) do
    with {:ok, access_token} <- exchange_code(code, redirect_uri),
         {:ok, claims} <- fetch_userinfo(access_token) do
      {:ok,
       %{
         sub: claims["sub"],
         email: claims["email"] && String.downcase(claims["email"]),
         email_verified: claims["email_verified"] == true,
         name: claims["name"] || claims["email"],
         picture: claims["picture"]
       }}
    end
  end

  defp exchange_code(code, redirect_uri) do
    body = %{
      "code" => code,
      "client_id" => config()[:client_id],
      "client_secret" => config()[:client_secret],
      "redirect_uri" => redirect_uri,
      "grant_type" => "authorization_code"
    }

    case Req.post(@token_url, form: body, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      {:ok, %{status: status, body: body}} -> {:error, {:token_exchange_failed, status, body}}
      {:error, reason} -> {:error, {:token_exchange_failed, reason}}
    end
  end

  defp fetch_userinfo(access_token) do
    case Req.get(@userinfo_url,
           headers: [{"authorization", "Bearer #{access_token}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: claims}} when is_map(claims) -> {:ok, claims}
      {:ok, %{status: status, body: body}} -> {:error, {:userinfo_failed, status, body}}
      {:error, reason} -> {:error, {:userinfo_failed, reason}}
    end
  end

  defp config, do: Application.get_env(:aper_desk, __MODULE__, [])
end
