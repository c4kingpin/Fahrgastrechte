defmodule Fahrgastrechte.Claims.Claim do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Claims.StatusHistory

  @primary_key {:id, :binary_id, autogenerate: true}
  @statuses [:draft, :ready, :sent, :completed]
  @journey_outcomes [
    :delayed_arrival,
    :not_started,
    :aborted,
    :continued_with_other_transport
  ]
  @disruption_causes [:delay, :cancellation, :missed_connection]
  @journey_directions [:outbound, :return]
  @editable_fields [
    :travel_date,
    :origin,
    :destination,
    :journey_outcome,
    :disruption_cause,
    :journey_direction
  ]
  @required_export_fields [
    :travel_date,
    :origin,
    :destination,
    :journey_outcome,
    :disruption_cause,
    :journey_direction
  ]

  @type status :: :draft | :ready | :sent | :completed
  @type journey_outcome ::
          :delayed_arrival | :not_started | :aborted | :continued_with_other_transport
  @type disruption_cause :: :delay | :cancellation | :missed_connection
  @type journey_direction :: :outbound | :return
  @type t :: %__MODULE__{}

  schema "claims" do
    field :claim_number, :string
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :travel_date, :date
    field :origin, :string
    field :destination, :string
    field :journey_outcome, Ecto.Enum, values: @journey_outcomes
    field :disruption_cause, Ecto.Enum, values: @disruption_causes
    field :journey_direction, Ecto.Enum, values: @journey_directions, default: :outbound
    field :compensation_method, Ecto.Enum, values: [bank_transfer: "bank_transfer"]
    field :generated_at, :utc_datetime_usec
    field :sent_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :lock_version, :integer, default: 1

    belongs_to :user, User
    has_many :status_history, StatusHistory

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(claim, attrs) do
    claim
    |> cast(attrs, @editable_fields)
    |> normalize_route()
    |> validate_fields()
    |> validate_required([:claim_number, :user_id, :status, :compensation_method])
    |> unique_constraint(:claim_number)
  end

  @doc false
  def update_changeset(claim, attrs) do
    claim
    |> cast(attrs, @editable_fields)
    |> normalize_route()
    |> validate_fields()
  end

  @doc false
  def transition_changeset(claim, changes) do
    claim
    |> change(changes)
    |> validate_required([:status])
  end

  @doc false
  def with_optimistic_lock(changeset), do: optimistic_lock(changeset, :lock_version)

  def statuses, do: @statuses
  def editable_fields, do: @editable_fields
  def required_export_fields, do: @required_export_fields
  def journey_outcomes, do: @journey_outcomes
  def disruption_causes, do: @disruption_causes
  def journey_directions, do: @journey_directions

  def cause_allowed?(%__MODULE__{
        journey_outcome: :not_started,
        disruption_cause: :missed_connection
      }),
      do: false

  def cause_allowed?(%__MODULE__{}), do: true

  defp normalize_route(changeset) do
    changeset
    |> update_change(:origin, &trim_optional/1)
    |> update_change(:destination, &trim_optional/1)
  end

  defp trim_optional(nil), do: nil

  defp trim_optional(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_fields(changeset) do
    changeset
    |> validate_length(:origin, max: 200)
    |> validate_length(:destination, max: 200)
  end
end
