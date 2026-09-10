defmodule AperDesk.Comms.EmailMessage do
  @moduledoc """
  One email, in or out.

  The `(account_id, message_id)` unique index is what makes IMAP sync safe to
  re-run: a mailbox re-scan that sees the same RFC-822 Message-ID twice hits
  the index instead of duplicating the message and re-triggering whatever
  automation the first copy fired.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Comms.{EmailAccount, EmailThread}
  alias AperDesk.Crm.Lead

  @directions ~w(inbound outbound)
  @states ~w(received queued sending sent delivered bounced failed)

  schema "email_messages" do
    belongs_to :studio, Studio
    belongs_to :thread, EmailThread
    belongs_to :account, EmailAccount
    belongs_to :lead, Lead

    field :direction, :string
    field :message_id, :string
    field :in_reply_to, :string
    field :from_address, :string
    field :from_name, :string
    field :to_addresses, {:array, :string}, default: []
    field :cc_addresses, {:array, :string}, default: []
    field :subject, :string
    field :body_text, :string
    field :body_html, :string
    field :has_attachments, :boolean, default: false

    field :state, :string, default: "received"
    field :sent_at, :utc_datetime_usec
    field :received_at, :utc_datetime_usec
    field :read_at, :utc_datetime_usec
    field :failed_reason, :string

    timestamps()
  end

  def directions, do: @directions
  def states, do: @states

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :studio_id,
      :thread_id,
      :account_id,
      :lead_id,
      :direction,
      :message_id,
      :in_reply_to,
      :from_address,
      :from_name,
      :to_addresses,
      :cc_addresses,
      :subject,
      :body_text,
      :body_html,
      :has_attachments,
      :state,
      :sent_at,
      :received_at
    ])
    |> validate_required([:studio_id, :direction])
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:state, @states)
    |> validate_recipients()
    |> unique_constraint([:account_id, :message_id],
      message: "this message has already been imported"
    )
  end

  @doc "Mark an outbound message as delivered to the provider."
  def sent_changeset(message, at \\ DateTime.utc_now()),
    do: change(message, state: "sent", sent_at: at)

  def failed_changeset(message, reason),
    do: change(message, state: "failed", failed_reason: reason)

  def read_changeset(message, at \\ DateTime.utc_now()),
    do: change(message, read_at: message.read_at || at)

  @doc "The address a reply should go to."
  def reply_to(%__MODULE__{direction: "inbound", from_address: from}), do: from
  def reply_to(%__MODULE__{to_addresses: [first | _]}), do: first
  def reply_to(%__MODULE__{}), do: nil

  # An outbound message with no recipient is a bug that only shows up as a
  # provider error minutes later, so catch it at the changeset.
  defp validate_recipients(changeset) do
    if get_field(changeset, :direction) == "outbound" and
         get_field(changeset, :to_addresses) in [nil, []] do
      add_error(changeset, :to_addresses, "an outbound message needs at least one recipient")
    else
      changeset
    end
  end
end
