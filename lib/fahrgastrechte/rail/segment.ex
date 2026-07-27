defmodule Fahrgastrechte.Rail.Segment do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fahrgastrechte.Rail.Journey

  @primary_key {:id, :binary_id, autogenerate: true}
  @editable_fields [
    :origin_name,
    :destination_name,
    :origin_external_id,
    :destination_external_id,
    :train_category,
    :train_number,
    :scheduled_departure,
    :scheduled_arrival,
    :estimated_departure,
    :estimated_arrival,
    :actual_departure,
    :actual_arrival,
    :cancelled,
    :external_id,
    :source,
    :source_metadata,
    :fetched_at,
    :manual
  ]

  @type t :: %__MODULE__{}

  schema "rail_segments" do
    field :position, :integer
    field :origin_name, :string
    field :destination_name, :string
    field :origin_external_id, :map
    field :destination_external_id, :map
    field :train_category, :string
    field :train_number, :string
    field :scheduled_departure, :utc_datetime_usec
    field :scheduled_arrival, :utc_datetime_usec
    field :estimated_departure, :utc_datetime_usec
    field :estimated_arrival, :utc_datetime_usec
    field :actual_departure, :utc_datetime_usec
    field :actual_arrival, :utc_datetime_usec
    field :cancelled, :boolean, default: false
    field :external_id, :map
    field :source, :string
    field :source_metadata, :map, default: %{}
    field :fetched_at, :utc_datetime_usec
    field :manual, :boolean, default: false

    belongs_to :journey, Journey, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(segment, attrs) do
    segment
    |> cast(attrs, [:position | @editable_fields])
    |> normalize_strings()
    |> validate_required([
      :journey_id,
      :position,
      :origin_name,
      :destination_name,
      :source,
      :fetched_at,
      :manual
    ])
    |> validate_number(:position, greater_than: 0)
    |> validate_length(:origin_name, max: 200)
    |> validate_length(:destination_name, max: 200)
    |> validate_length(:train_category, max: 40)
    |> validate_length(:train_number, max: 40)
    |> validate_length(:source, max: 200)
    |> validate_time_order()
    |> unique_constraint([:journey_id, :position])
  end

  def manual_changeset(segment, attrs, fetched_at) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:manual, true)
      |> Map.put(:source, "manual")
      |> Map.put(:fetched_at, fetched_at)

    segment
    |> cast(attrs, @editable_fields)
    |> normalize_strings()
    |> validate_required([:origin_name, :destination_name, :source, :fetched_at, :manual])
    |> validate_time_order()
  end

  def editable_fields, do: @editable_fields

  defp normalize_strings(changeset) do
    Enum.reduce(
      [:origin_name, :destination_name, :train_category, :train_number, :source],
      changeset,
      fn field, current ->
        update_change(current, field, fn
          nil -> nil
          value -> value |> String.trim() |> blank_to_nil()
        end)
      end
    )
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp validate_time_order(changeset) do
    changeset
    |> validate_pair(:scheduled_departure, :scheduled_arrival)
    |> validate_pair(:estimated_departure, :estimated_arrival)
    |> validate_pair(:actual_departure, :actual_arrival)
  end

  defp validate_pair(changeset, departure_field, arrival_field) do
    departure = get_field(changeset, departure_field)
    arrival = get_field(changeset, arrival_field)

    if departure && arrival && DateTime.compare(arrival, departure) == :lt do
      add_error(changeset, arrival_field, "must not be before departure")
    else
      changeset
    end
  end
end
