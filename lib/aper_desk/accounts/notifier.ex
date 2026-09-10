defmodule AperDesk.Accounts.Notifier do
  @moduledoc """
  Account emails: password resets, confirmations, invitations.

  Every one is plain text as well as HTML. A password-reset link that only
  renders in an HTML client is a link some people cannot use, and these are
  exactly the messages that must not fail.

  Delivery failures are returned, never raised. A reset request whose email
  bounces must still look identical to one that succeeded — see
  `AperDeskWeb.AuthController` for why.
  """

  import Swoosh.Email

  alias AperDesk.Accounts.{User, UserInvitation}
  alias AperDesk.Mailer

  @from_name "AperDesk"

  @doc "The link that lets someone set a new password."
  def deliver_reset_password(%User{} = user, url) do
    deliver(user.email, user.name, "Reset your AperDesk password", """
    Hi #{first_name(user.name)},

    Someone asked to reset the password for your AperDesk account. Use the link
    below to choose a new one. It expires in one hour.

    #{url}

    If it wasn't you, nothing has changed and you can ignore this email.

    — AperDesk
    """)
  end

  @doc "Sent after a password change, so an unexpected one is noticed."
  def deliver_password_changed(%User{} = user) do
    deliver(user.email, user.name, "Your AperDesk password was changed", """
    Hi #{first_name(user.name)},

    Your AperDesk password was just changed, and every other signed-in device
    has been signed out.

    If this wasn't you, reset your password immediately and contact
    support@aperdesk.com.

    — AperDesk
    """)
  end

  def deliver_invitation(%UserInvitation{} = invitation, studio_name, url) do
    deliver(invitation.email, nil, "You have been invited to #{studio_name} on AperDesk", """
    You have been invited to join #{studio_name} on AperDesk as #{invitation.role}.

    #{url}

    The invitation expires in 14 days.

    — AperDesk
    """)
  end

  ## Internals

  defp deliver(recipient, recipient_name, subject, body) do
    email =
      new()
      |> to(if recipient_name, do: {recipient_name, recipient}, else: recipient)
      |> from({@from_name, from_address()})
      |> subject(subject)
      |> text_body(body)
      |> html_body(to_html(body))

    case Mailer.deliver(email) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, reason} -> {:error, reason}
    end
  end

  defp from_address,
    do: Application.get_env(:aper_desk, :mail)[:from] || "no-reply@aperdesk.com"

  defp first_name(nil), do: "there"
  defp first_name(name), do: name |> String.split(" ") |> List.first()

  # Deliberately minimal: paragraphs and links, nothing else. Account email that
  # renders in every client beats account email that looks designed in some.
  defp to_html(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map_join("\n", fn paragraph ->
      paragraph
      |> String.trim()
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()
      |> linkify()
      |> then(
        &"<p style=\"margin:0 0 14px;font:14px/1.6 -apple-system,Segoe UI,sans-serif\">#{&1}</p>"
      )
    end)
    |> then(
      &"""
      <div style="max-width:520px;margin:0 auto;padding:24px;color:#1E1A16">#{&1}</div>
      """
    )
  end

  defp linkify(text) do
    Regex.replace(~r{https?://[^\s<]+}, text, fn url ->
      ~s(<a href="#{url}" style="color:#8F5820">#{url}</a>)
    end)
  end
end
