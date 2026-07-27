defmodule Fahrgastrechte.Tickets.Suggestion do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fahrgastrechte.Documents.Document

  @primary_key {:id, :binary_id, autogenerate: true}
  @fields [
    :order_number,
    :travel_date,
    :valid_until,
    :origin,
    :destination,
    :product,
    :fare,
    :scheduled_train,
    :scheduled_departure,
    :scheduled_arrival
  ]

  @type field ::
          :order_number
          | :travel_date
          | :valid_until
          | :origin
          | :destination
          | :product
          | :fare
          | :scheduled_train
          | :scheduled_departure
          | :scheduled_arrival
  @type state :: :proposed | :accepted | :rejected
  @type t :: %__MODULE__{}

  schema "ticket_suggestions" do
    field :field, Ecto.Enum, values: @fields
    field :value, :map
    field :confidence, :float
    field :source_page, :integer
    field :source_excerpt, :string
    field :state, Ecto.Enum, values: [:proposed, :accepted, :rejected], default: :proposed

    belongs_to :document, Document, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(suggestion, attrs) do
    suggestion
    |> cast(attrs, [:field, :value, :confidence, :source_page, :source_excerpt, :state])
    |> validate_required([
      :document_id,
      :field,
      :value,
      :confidence,
      :source_page,
      :source_excerpt,
      :state
    ])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:source_page, greater_than: 0)
    |> validate_length(:source_excerpt, min: 1, max: 500)
    |> unique_constraint([:document_id, :field])
  end

  @doc false
  def state_changeset(suggestion, state) do
    suggestion
    |> change(state: state)
    |> validate_inclusion(:state, [:proposed, :accepted, :rejected])
  end

  def fields, do: @fields
end
