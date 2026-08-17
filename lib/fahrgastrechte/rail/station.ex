defmodule Fahrgastrechte.Rail.Station do
  @moduledoc """
  A station from the locally imported OpenStation catalog.

  Populated by `Fahrgastrechte.Rail.StationCatalogSync`; read by
  `Fahrgastrechte.Rail.Providers.StationCatalog` to answer station-name
  searches from a complete, real dataset instead of a live "best match only"
  upstream lookup.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}

  schema "stations" do
    field :name, :string
    field :eva_number, :string
    field :dhid, :string
    field :stop_place_type, :string
    field :transport_mode, :string
    field :source_metadata, :map, default: %{}
    field :synced_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(station, attrs) do
    station
    |> cast(attrs, [
      :name,
      :eva_number,
      :dhid,
      :stop_place_type,
      :transport_mode,
      :source_metadata,
      :synced_at
    ])
    |> validate_required([:name, :eva_number])
    |> validate_length(:name, max: 255)
    |> validate_length(:eva_number, max: 32)
    |> unique_constraint(:eva_number)
  end
end
