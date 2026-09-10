defmodule AperDesk.Directory.Review do
  @moduledoc """
  A client's rating of a completed job.

  A review must reference a job, and `job_id` is uniquely indexed. That single
  constraint is the difference between a directory people trust and one they do
  not: a rating cannot exist without a booking behind it, and a job cannot be
  rated twice.

  Reviews are unpublished until moderated, and a studio may reply once. The
  reply lives on the review rather than as a threaded record because a public
  argument under a one-star rating serves nobody.
  """
  use AperDesk.Schema

  alias AperDesk.Accounts.Studio
  alias AperDesk.Crm.Contact
  alias AperDesk.Scheduling.Job

  schema "reviews" do
    belongs_to :studio, Studio
    belongs_to :job, Job
    belongs_to :contact, Contact

    field :author_name, :string
    field :rating, :integer
    field :body, :string
    field :shoot_type, :string
    field :published_at, :utc_datetime_usec
    field :studio_reply, :string
    field :replied_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [
      :studio_id,
      :job_id,
      :contact_id,
      :author_name,
      :rating,
      :body,
      :shoot_type
    ])
    |> validate_required([:studio_id, :job_id, :author_name, :rating])
    |> validate_inclusion(:rating, 1..5)
    |> validate_length(:body, max: 4000)
    |> unique_constraint(:job_id, message: "this shoot has already been reviewed")
    |> foreign_key_constraint(:job_id)
  end

  def publish_changeset(review, at \\ DateTime.utc_now()),
    do: change(review, published_at: review.published_at || at)

  def unpublish_changeset(review), do: change(review, published_at: nil)

  @doc "A studio's single public reply."
  def reply_changeset(review, reply, at \\ DateTime.utc_now()) do
    review
    |> cast(%{studio_reply: reply}, [:studio_reply])
    |> validate_required([:studio_reply])
    |> validate_length(:studio_reply, max: 2000)
    |> put_change(:replied_at, at)
  end

  def published?(%__MODULE__{published_at: %DateTime{}}), do: true
  def published?(%__MODULE__{}), do: false

  @doc """
  Average and count over a list of reviews, for the listing's denormalised
  rating. Returns `{nil, 0}` for an empty list rather than dividing by zero.
  """
  def aggregate([]), do: {nil, 0}

  def aggregate(reviews) when is_list(reviews) do
    count = length(reviews)
    sum = Enum.reduce(reviews, 0, &(&2 + &1.rating))

    average =
      sum
      |> Decimal.new()
      |> Decimal.div(Decimal.new(count))
      |> Decimal.round(2)

    {average, count}
  end
end
