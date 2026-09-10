defmodule AperDesk.Comms.InboundCapture do
  @moduledoc """
  The audit trail of how one inbound email became (or failed to become) a lead.

  The pipeline is explicit — `received -> parsed -> matched -> drafted ->
  applied` — rather than a worker that quietly does five things. When a lead
  comes out wrong, the row shows which stage produced the bad value and the
  capture can be re-run from there instead of being re-guessed from logs.

  `approved_at` is the gate on the AI-drafted reply. Nothing is ever sent on a
  studio's behalf without a human setting it, which is the promise the FAQ
  makes and the reason it is a column rather than a config flag.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.{Studio, User}
  alias AperDesk.Comms.EmailMessage
  alias AperDesk.Crm.Lead

  @stages ~w(received parsed matched drafted applied rejected failed)
  # Stages a capture can still move forward from.
  @open_stages ~w(received parsed matched drafted)

  schema "inbound_captures" do
    belongs_to :studio, Studio
    belongs_to :message, EmailMessage
    belongs_to :lead, Lead
    belongs_to :approved_by, User

    field :stage, :string, default: "received"
    field :raw_source, :string
    field :parsed, :map, default: %{}
    field :parser_version, :string
    field :confidence, :decimal

    field :draft_subject, :string
    field :draft_body, :string
    field :draft_model, :string
    field :draft_generated_at, :utc_datetime_usec

    field :approved_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec
    field :error, :string

    timestamps()
  end

  def stages, do: @stages
  def open_stages, do: @open_stages

  def changeset(capture, attrs) do
    capture
    |> cast(attrs, [:studio_id, :message_id, :stage, :raw_source])
    |> validate_required([:studio_id])
    |> validate_inclusion(:stage, @stages)
    |> foreign_key_constraint(:studio_id)
  end

  @doc "Record what the parser made of the message."
  def parsed_changeset(capture, parsed, parser_version, confidence) when is_map(parsed) do
    capture
    |> change(
      stage: "parsed",
      parsed: parsed,
      parser_version: parser_version,
      confidence: to_decimal(confidence),
      error: nil
    )
  end

  @doc "Attach the capture to the lead it belongs to, new or existing."
  def matched_changeset(capture, lead_id),
    do: change(capture, stage: "matched", lead_id: lead_id)

  @doc """
  Store a generated reply. Stamping the model makes it possible to tell which
  drafts came from which model version when quality changes after an upgrade.
  """
  def drafted_changeset(capture, attrs) do
    capture
    |> cast(attrs, [:draft_subject, :draft_body, :draft_model])
    |> put_change(:stage, "drafted")
    |> put_change(:draft_generated_at, DateTime.utc_now())
  end

  @doc "A human approved the draft. Only after this may anything be sent."
  def approved_changeset(capture, %User{id: user_id}, at \\ DateTime.utc_now()) do
    change(capture, stage: "applied", approved_by_id: user_id, approved_at: at)
  end

  def rejected_changeset(capture, at \\ DateTime.utc_now()),
    do: change(capture, stage: "rejected", rejected_at: at)

  def failed_changeset(capture, error), do: change(capture, stage: "failed", error: error)

  @doc "Whether a draft may be sent: approved by a person, and not since rejected."
  def sendable?(%__MODULE__{approved_at: %DateTime{}, rejected_at: nil, draft_body: body})
      when is_binary(body),
      do: true

  def sendable?(%__MODULE__{}), do: false

  @doc """
  Whether the parse was confident enough to act on without review.

  Deliberately conservative: a missed auto-apply costs a photographer one click,
  a wrong one sends a stranger a quote.
  """
  def confident?(%__MODULE__{confidence: nil}, _threshold), do: false

  def confident?(%__MODULE__{confidence: confidence}, threshold),
    do: Decimal.compare(confidence, to_decimal(threshold)) != :lt

  @doc "A field the parser extracted, e.g. `field(capture, \"email\")`."
  def field(%__MODULE__{parsed: parsed}, key) when is_binary(key), do: Map.get(parsed || %{}, key)

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_binary(n), do: Decimal.new(n)
end
