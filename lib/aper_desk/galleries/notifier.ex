defmodule AperDesk.Galleries.Notifier do
  @moduledoc """
  Client-facing gallery email.

  Separate from `AperDesk.Accounts.Notifier` because the recipient is not a
  user of the product: they are a couple who were sent a link, and the mail has
  to read as coming from their photographer rather than from a SaaS they have
  never heard of.
  """

  import Swoosh.Email

  alias AperDesk.Mailer

  @doc """
  Send a one-time code for a gallery that requires verification.

  The studio's name leads, because that is who the recipient thinks they are
  hearing from. The gallery title is deliberately the only detail included — a
  code email that quotes the shoot back at someone who should not have it is a
  small leak of its own.
  """
  def deliver_access_code(email, studio_name, gallery_title, code) do
    deliver(email, "Your code for #{gallery_title}", """
    #{studio_name} asked us to check it is you before opening #{gallery_title}.

    Your code is #{code}

    It expires in 15 minutes and can be used once. If you did not ask to open
    the gallery, you can ignore this email — the code does nothing on its own.

    — #{studio_name}, via AperDesk
    """)
  end

  ## Internals

  defp deliver(recipient, subject, body) do
    new()
    |> to(recipient)
    |> from({"AperDesk", from_address()})
    |> subject(subject)
    |> text_body(body)
    |> html_body(to_html(body))
    |> Mailer.deliver()
  end

  defp from_address,
    do: Application.get_env(:aper_desk, :mail)[:from] || "no-reply@aperdesk.com"

  defp to_html(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map_join("\n", fn paragraph ->
      paragraph
      |> String.trim()
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()
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
end
