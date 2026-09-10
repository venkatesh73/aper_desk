defmodule AperDesk.Vault do
  @moduledoc """
  Application-level encryption for the handful of columns that must not be
  readable from a database dump: mailbox passwords and OAuth refresh tokens.

  Disk encryption protects against a stolen server. This protects against a
  leaked backup, an over-permissioned read replica, or a support engineer with
  psql access — which are the failure modes that actually happen.
  """
  use Cloak.Vault, otp_app: :aper_desk
end

defmodule AperDesk.Encrypted.Binary do
  @moduledoc "Ecto type for a Cloak-encrypted binary column."
  use Cloak.Ecto.Binary, vault: AperDesk.Vault
end
