defmodule Fahrgastrechte.Repo.Migrations.CreateStations do
  use Ecto.Migration

  def change do
    create table(:stations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :eva_number, :string, null: false
      add :dhid, :string
      add :stop_place_type, :string
      add :transport_mode, :string
      add :source_metadata, :map, null: false, default: %{}
      add :synced_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stations, [:eva_number])
  end
end
