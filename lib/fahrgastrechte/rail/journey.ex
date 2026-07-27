defmodule Fahrgastrechte.Rail.Journey do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Claims.Claim
  alias Fahrgastrechte.Rail.Segment

  @primary_key {:id, :binary_id, autogenerate: true}
  @kinds [:planned, :actual]

  @type kind :: :planned | :actual
  @type t :: %__MODULE__{}

  schema "rail_journeys" do
    field :kind, Ecto.Enum, values: @kinds
    field :confirmed_at, :utc_datetime_usec
    field :first_disrupted_segment_id, Ecto.UUID
    field :missed_connection_segment_id, Ecto.UUID
    field :last_used_segment_id, Ecto.UUID
    field :actual_destination_arrival, :utc_datetime_usec

    belongs_to :claim, Claim, type: :binary_id
    belongs_to :user, User
    has_many :segments, Segment, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(journey, attrs) do
    journey
    |> cast(attrs, [:kind, :confirmed_at])
    |> validate_required([:kind, :confirmed_at, :claim_id, :user_id])
    |> unique_constraint([:claim_id, :kind])
  end

  def override_changeset(journey, attrs) do
    cast(journey, attrs, [
      :first_disrupted_segment_id,
      :missed_connection_segment_id,
      :last_used_segment_id,
      :actual_destination_arrival
    ])
  end

  def kinds, do: @kinds
end
