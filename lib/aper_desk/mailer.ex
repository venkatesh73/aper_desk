defmodule AperDesk.Mailer do
  @moduledoc """
  Outbound mail.

  Local adapter in development, which writes to the mailbox previewer at
  `/dev/mailbox` rather than sending anything; SMTP in production, configured
  from the environment in `runtime.exs`.
  """
  use Swoosh.Mailer, otp_app: :aper_desk
end
