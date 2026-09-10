defmodule AperDesk.Comms.EmailThread do
  @moduledoc """
  A conversation, tied to the lead it concerns.

  Threads are per-studio rather than per-account so that a conversation which
  starts on the shared `hello@` address and continues from a photographer's
  personal mailbox stays one thread in the UI.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Comms.EmailMessage
  alias AperDesk.Crm.{Contact, Lead}

  schema "email_threads" do
    belongs_to :studio, Studio
    belongs_to :lead, Lead
    belongs_to :contact, Contact

    field :subject, :string
    field :provider_thread_id, :string
    field :message_count, :integer, default: 0
    field :last_message_at, :utc_datetime_usec
    field :unread_count, :integer, default: 0

    has_many :messages, EmailMessage, foreign_key: :thread_id

    timestamps()
  end

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:studio_id, :lead_id, :contact_id, :subject, :provider_thread_id])
    |> validate_required([:studio_id])
    |> foreign_key_constraint(:studio_id)
  end

  @doc "Roll the counters forward as a message lands. Direction decides the unread count."
  def message_added_changeset(thread, %EmailMessage{} = message) do
    change(thread,
      message_count: (thread.message_count || 0) + 1,
      last_message_at: message.received_at || message.sent_at || DateTime.utc_now(),
      unread_count:
        if(message.direction == "inbound",
          do: (thread.unread_count || 0) + 1,
          else: thread.unread_count || 0
        )
    )
  end

  def read_changeset(thread), do: change(thread, unread_count: 0)
end
