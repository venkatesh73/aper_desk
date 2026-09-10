defmodule AperDesk.Sales do
  @moduledoc """
  Quotes and contracts — the path from "here is the price" to a signed booking.

  Two properties matter more than anything else here.

  **Accepting a quote is one transaction.** It marks the quote accepted, moves
  the lead to booked, and emits the event that triggers the contract workflow.
  A partial commit would leave a client believing they have booked while the
  studio's pipeline still shows an open enquiry.

  **A signed contract is tamper-evident.** The signature stores a SHA-256
  checksum of the exact body that was signed. If the contract text is later
  edited, the stored checksum no longer matches and `signature_valid?/2` says
  so. Without that, "they signed it" is an assertion; with it, it is checkable.
  """

  import Ecto.Query

  alias AperDesk.Authorization
  alias AperDesk.Crm.Lead
  alias AperDesk.Events
  alias AperDesk.Repo
  alias AperDesk.Sales.{Contract, ContractTemplate, Quote, Signature}
  alias AperDesk.Scope
  alias AperDesk.Scoped
  alias Ecto.Multi

  @share_token_bytes 32

  ## Quotes

  def list_quotes(%Scope{} = scope, opts \\ []) do
    with :ok <- Authorization.authorize(scope, :"quote.read") do
      {:ok,
       Quote
       |> Scoped.for_studio(scope)
       |> then(fn q ->
         case opts[:status] do
           nil -> q
           status -> where(q, [x], x.status == ^status)
         end
       end)
       |> preload([:contact, :line_items])
       |> order_by([q], desc: q.inserted_at)
       |> Scoped.paginate(opts)
       |> Repo.all()}
    end
  end

  def fetch_quote(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"quote.read") do
      case Quote
           |> Scoped.for_studio(scope)
           |> preload([:line_items, :contact, :lead])
           |> Repo.get(id) do
        nil -> {:error, :not_found}
        quote -> {:ok, quote}
      end
    end
  end

  def create_quote(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"quote.write") do
      %Quote{}
      |> Quote.changeset(Scoped.put_studio(attrs, scope))
      |> Repo.insert()
    end
  end

  def update_quote(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"quote.write"),
         {:ok, quote} <- Scoped.fetch(Quote, scope, id),
         :ok <- ensure_editable(quote) do
      quote |> Quote.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Send a quote to the client.

  Mints a share token so the client can open it without an account; only the
  hash is stored. Returns `{:ok, quote, token}` — the token exists for exactly
  this response.
  """
  def send_quote(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"quote.write"),
         {:ok, quote} <- Scoped.fetch(Quote, scope, id) do
      {token, hash} = mint_token()

      Multi.new()
      |> Multi.update(
        :quote,
        Ecto.Changeset.change(quote,
          status: "sent",
          sent_at: DateTime.utc_now(),
          share_token_hash: hash
        )
      )
      |> Events.record(:quote, "quote.sent", "Quote sent to client", scope)
      |> Repo.transaction()
      |> case do
        {:ok, %{quote: quote}} -> {:ok, quote, token}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  @doc "Resolve a client's share link to the quote behind it."
  def fetch_quote_by_token(token) when is_binary(token) do
    hash = :crypto.hash(:sha256, token)

    case Repo.one(
           from q in Quote, where: q.share_token_hash == ^hash, preload: [:line_items, :studio]
         ) do
      nil -> {:error, :not_found}
      quote -> {:ok, quote}
    end
  end

  @doc "Record that the client opened it. First view is kept separately for the SLA view."
  def record_quote_view(%Quote{} = quote) do
    now = DateTime.utc_now()

    quote
    |> Ecto.Changeset.change(
      first_viewed_at: quote.first_viewed_at || now,
      view_count: (quote.view_count || 0) + 1
    )
    |> Repo.update()
  end

  @doc """
  The client accepts.

  Quote, lead and event move together — see the module doc. Guarded on the
  quote still being open, so a second click on the accept button cannot
  re-accept and re-trigger the booking workflow.
  """
  def accept_quote(%Scope{} = scope, id) do
    with {:ok, quote} <- Scoped.fetch(Quote, scope, id),
         :ok <- ensure_open(quote) do
      now = DateTime.utc_now()

      Multi.new()
      |> Multi.update(:quote, Ecto.Changeset.change(quote, status: "accepted", accepted_at: now))
      |> Multi.run(:lead, fn repo, _ -> move_lead_to_booked(repo, quote) end)
      |> Events.record(:quote, "quote.accepted", "Client accepted the quote", scope)
      |> Repo.transaction()
      |> case do
        {:ok, %{quote: quote}} -> {:ok, quote}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  def decline_quote(%Scope{} = scope, id, reason \\ nil) do
    with {:ok, quote} <- Scoped.fetch(Quote, scope, id),
         :ok <- ensure_open(quote) do
      Multi.new()
      |> Multi.update(
        :quote,
        Ecto.Changeset.change(quote, status: "declined", declined_at: DateTime.utc_now())
      )
      |> Events.record(:quote, "quote.declined", "Client declined the quote", scope,
        payload: %{"reason" => reason}
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{quote: quote}} -> {:ok, quote}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  @doc "Quotes past their validity date that nobody has acted on."
  def expire_quotes(%Scope{} = scope, today \\ Date.utc_today()) do
    {count, _} =
      Repo.update_all(
        from(q in Quote,
          where:
            q.studio_id == ^Scope.studio_id(scope) and q.status in ^Quote.open_statuses() and
              not is_nil(q.valid_until) and q.valid_until < ^today
        ),
        set: [status: "expired", updated_at: DateTime.utc_now()]
      )

    count
  end

  ## Contract templates

  def list_templates(%Scope{} = scope) do
    ContractTemplate
    |> Scoped.for_studio(scope)
    |> where([t], is_nil(t.archived_at))
    |> order_by([t], asc: t.name)
    |> Repo.all()
  end

  def create_template(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"contract.write") do
      %ContractTemplate{}
      |> ContractTemplate.changeset(Scoped.put_studio(attrs, scope))
      |> Repo.insert()
    end
  end

  def fetch_template(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"contract.read") do
      Scoped.fetch(ContractTemplate, scope, id)
    end
  end

  def update_template(%Scope{} = scope, id, attrs) do
    with :ok <- Authorization.authorize(scope, :"contract.write"),
         {:ok, template} <- Scoped.fetch(ContractTemplate, scope, id) do
      template |> ContractTemplate.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Retire a template. Contracts already drafted from it are untouched."
  def archive_template(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"contract.write"),
         {:ok, template} <- Scoped.fetch(ContractTemplate, scope, id) do
      template |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update()
    end
  end

  def change_template(template \\ %ContractTemplate{}, attrs \\ %{}),
    do: ContractTemplate.changeset(template, attrs)

  ## Contracts

  def fetch_contract(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"contract.read") do
      case Contract
           |> Scoped.for_studio(scope)
           |> preload([:signatures, :contact])
           |> Repo.get(id) do
        nil -> {:error, :not_found}
        contract -> {:ok, contract}
      end
    end
  end

  @doc """
  Draft a contract, stamping the checksum of the body as drafted.

  The checksum is computed here rather than at signing time so that any later
  edit is detectable even if nobody has signed yet.
  """
  def create_contract(%Scope{} = scope, attrs) do
    with :ok <- Authorization.authorize(scope, :"contract.write") do
      attrs = Scoped.put_studio(attrs, scope)

      %Contract{}
      |> Contract.changeset(attrs)
      |> put_checksum()
      |> Repo.insert()
    end
  end

  def send_contract(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, :"contract.write"),
         {:ok, contract} <- Scoped.fetch(Contract, scope, id) do
      {token, hash} = mint_token()

      Multi.new()
      |> Multi.update(
        :contract,
        Ecto.Changeset.change(contract,
          status: "sent",
          sent_at: DateTime.utc_now(),
          share_token_hash: hash
        )
      )
      |> Events.record(:contract, "contract.sent", "Contract sent for signature", scope)
      |> Repo.transaction()
      |> case do
        {:ok, %{contract: contract}} -> {:ok, contract, token}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  def fetch_contract_by_token(token) when is_binary(token) do
    hash = :crypto.hash(:sha256, token)

    case Repo.one(
           from c in Contract, where: c.share_token_hash == ^hash, preload: [:signatures, :studio]
         ) do
      nil -> {:error, :not_found}
      contract -> {:ok, contract}
    end
  end

  @doc """
  Sign a contract.

  The signature records the checksum of the body as it stood at signing, along
  with the signer's IP and user agent. Signing is guarded on the contract not
  already being signed, so a double submit cannot produce two signatures for
  one party.
  """
  def sign_contract(%Scope{} = scope, contract_id, attrs) do
    with {:ok, contract} <- Scoped.fetch(Contract, scope, contract_id),
         :ok <- ensure_signable(contract) do
      now = DateTime.utc_now()
      checksum = Contract.checksum(contract.body || "")

      Multi.new()
      |> Multi.insert(
        :signature,
        Signature.changeset(%Signature{}, %{
          contract_id: contract.id,
          signer_name: attrs["signer_name"] || attrs[:signer_name],
          signer_email: attrs["signer_email"] || attrs[:signer_email],
          signature_svg: attrs["signature_svg"] || attrs[:signature_svg],
          typed_name: attrs["typed_name"] || attrs[:typed_name],
          ip_address: attrs["ip_address"] || attrs[:ip_address],
          user_agent: attrs["user_agent"] || attrs[:user_agent],
          signed_at: now,
          document_checksum: checksum
        })
      )
      |> Multi.update(
        :contract,
        Ecto.Changeset.change(contract,
          status: "signed",
          signed_at: now,
          body_checksum: checksum
        )
      )
      |> Events.record(:contract, "contract.signed", "Contract signed", scope)
      |> Repo.transaction()
      |> case do
        {:ok, %{contract: contract}} -> {:ok, contract}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  @doc """
  Whether a signature still matches the contract body.

  Returns false if the text has been edited since it was signed — which is the
  entire reason the checksum exists.
  """
  def signature_valid?(%Contract{body: body}, %Signature{document_checksum: checksum}),
    do: Contract.checksum(body || "") == checksum

  ## Internals

  defp move_lead_to_booked(_repo, %Quote{lead_id: nil}), do: {:ok, nil}

  defp move_lead_to_booked(repo, %Quote{lead_id: lead_id}) do
    case repo.get(Lead, lead_id) do
      nil ->
        {:ok, nil}

      lead ->
        # Already booked is fine — a second quote accepted on the same lead
        # should not fail, it just does not move anything.
        if lead.stage == "booked" do
          {:ok, lead}
        else
          lead |> Lead.stage_changeset("booked") |> repo.update()
        end
    end
  end

  defp put_checksum(changeset) do
    case Ecto.Changeset.get_field(changeset, :body) do
      nil -> changeset
      body -> Ecto.Changeset.put_change(changeset, :body_checksum, Contract.checksum(body))
    end
  end

  defp mint_token do
    token = @share_token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    {token, :crypto.hash(:sha256, token)}
  end

  defp ensure_editable(%Quote{status: status}) when status in ~w(draft sent), do: :ok
  defp ensure_editable(%Quote{status: status}), do: {:error, {:not_editable, status}}

  defp ensure_open(%Quote{status: status}) do
    if status in Quote.open_statuses(), do: :ok, else: {:error, {:not_open, status}}
  end

  defp ensure_signable(%Contract{status: "signed"}), do: {:error, :already_signed}
  defp ensure_signable(%Contract{status: "voided"}), do: {:error, :voided}
  defp ensure_signable(%Contract{}), do: :ok
end
