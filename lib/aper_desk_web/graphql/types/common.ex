defmodule AperDeskWeb.Graphql.Types.Common do
  @moduledoc """
  Small shared shapes: errors, people, key/value stats.

  Mutations return their errors in the payload rather than as top-level GraphQL
  errors. A validation failure is a normal outcome of a form submission, not an
  exceptional one, and a client should not have to inspect the `errors` array of
  the response envelope to render a field-level message.
  """

  use Absinthe.Schema.Notation

  @desc "A field-level validation failure."
  object :user_error do
    field(:field, :string)
    field(:message, non_null(:string))
  end

  @desc "A person, as shown on an avatar or a row."
  object :person do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:email, :string)
    field(:role, :string)

    @desc "Two-letter monogram for the avatar, derived from the name."
    field :initials, non_null(:string) do
      resolve(fn person, _, _ ->
        {:ok, AperDeskWeb.Graphql.Resolvers.Helpers.initials(person.name)}
      end)
    end
  end

  @desc "A headline number on a dashboard."
  object :stat do
    field(:key, non_null(:string))
    field(:value, :string)
    field(:amount_usd, :float)
    field(:delta, :string)
    field(:delta_tone, :tone)
  end

  @desc "A row in a checklist of what still needs doing."
  object :readiness_item do
    field(:label, non_null(:string))
    field(:detail, :string)
    field(:state, non_null(:string))
  end

  @desc "One entry in a history feed."
  object :activity_entry do
    field(:time, non_null(:string))
    field(:text, non_null(:string))
  end

  @desc "A label with a visual weight."
  object :chip do
    field(:label, non_null(:string))
    field(:tone, :tone)
  end
end
