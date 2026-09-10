defmodule AperDesk.Sales.Contract do
  @moduledoc """
  A contract sent for signature.

  The rendered `body` and its `body_checksum` are frozen at send time. A signed
  contract is never re-rendered from its template — the template may have
  changed, and "what did they actually agree to" must have exactly one answer.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Crm.{Contact, Lead}
  alias AperDesk.Sales.{ContractTemplate, Quote, Signature}
  alias AperDesk.Scheduling.Job

  @statuses ~w(draft sent viewed signed declined voided expired)

  schema "contracts" do
    belongs_to :studio, Studio
    belongs_to :lead, Lead
    belongs_to :job, Job
    belongs_to :quote, Quote
    belongs_to :contact, Contact
    belongs_to :template, ContractTemplate

    field :reference, :string, read_after_writes: true
    field :status, :string, default: "draft"
    field :title, :string
    field :body, :string
    field :body_checksum, :string

    field :share_token_hash, :binary
    field :sent_at, :utc_datetime_usec
    field :signed_at, :utc_datetime_usec
    field :voided_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    has_many :signatures, Signature

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(contract, attrs) do
    contract
    |> cast(attrs, [
      :studio_id,
      :lead_id,
      :job_id,
      :quote_id,
      :contact_id,
      :template_id,
      :reference,
      :status,
      :title,
      :body,
      :expires_at
    ])
    |> validate_required([:studio_id, :title, :body])
    |> validate_inclusion(:status, @statuses)
    |> put_checksum()
    |> unique_constraint([:studio_id, :reference])
  end

  # SHA-256 of the exact bytes presented to the signer. Stored on the signature
  # too, so tampering after the fact is detectable.
  defp put_checksum(changeset) do
    case get_change(changeset, :body) do
      nil -> changeset
      body -> put_change(changeset, :body_checksum, checksum(body))
    end
  end

  def checksum(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end

defmodule AperDesk.Sales.ContractTemplate do
  @moduledoc "A reusable contract body with `{{variable}}` placeholders."
  use AperDesk.Schema

  schema "contract_templates" do
    belongs_to :studio, AperDesk.Accounts.Studio
    field :name, :string
    field :shoot_type, :string
    field :body, :string
    field :requires_deposit, :boolean, default: true
    field :archived_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [:studio_id, :name, :shoot_type, :body, :requires_deposit])
    |> validate_required([:studio_id, :name, :body])
  end
end

defmodule AperDesk.Sales.Signature do
  @moduledoc """
  Evidence that a specific person signed a specific document.

  IP address, user agent, timestamp and the document checksum are all recorded,
  because those four things together are what makes an electronic signature
  defensible if it is ever disputed.
  """
  use AperDesk.Schema

  schema "signatures" do
    belongs_to :contract, AperDesk.Sales.Contract
    field :signer_name, :string
    field :signer_email, :string
    field :signature_svg, :string
    field :typed_name, :string
    field :signed_at, :utc_datetime_usec
    field :ip_address, :string
    field :user_agent, :string
    field :document_checksum, :string

    timestamps(updated_at: false)
  end

  def changeset(signature, attrs) do
    signature
    |> cast(attrs, [
      :contract_id,
      :signer_name,
      :signer_email,
      :signature_svg,
      :typed_name,
      :signed_at,
      :ip_address,
      :user_agent,
      :document_checksum
    ])
    |> validate_required([
      :contract_id,
      :signer_name,
      :signer_email,
      :signed_at,
      :document_checksum
    ])
    |> validate_signature_present()
  end

  # Either a drawn signature or a typed name, but not neither.
  defp validate_signature_present(changeset) do
    drawn = get_field(changeset, :signature_svg)
    typed = get_field(changeset, :typed_name)

    if is_nil(drawn) and is_nil(typed) do
      add_error(changeset, :signature_svg, "a drawn or typed signature is required")
    else
      changeset
    end
  end
end
