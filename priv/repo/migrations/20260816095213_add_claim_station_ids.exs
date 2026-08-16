defmodule Fahrgastrechte.Repo.Migrations.AddClaimStationIds do
  use Ecto.Migration

  def change do
    alter table(:claims) do
      add :origin_station_id, :map
      add :destination_station_id, :map
    end
  end
end
