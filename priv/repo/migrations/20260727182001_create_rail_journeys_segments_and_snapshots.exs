defmodule Fahrgastrechte.Repo.Migrations.CreateRailJourneysSegmentsAndSnapshots do
  use Ecto.Migration

  def change do
    create table(:rail_journeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :confirmed_at, :utc_datetime_usec, null: false
      add :first_disrupted_segment_id, :binary_id
      add :missed_connection_segment_id, :binary_id
      add :last_used_segment_id, :binary_id
      add :actual_destination_arrival, :utc_datetime_usec

      add :claim_id, references(:claims, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:rail_journeys, :rail_journeys_kind_check,
             check: "kind IN ('planned', 'actual')"
           )

    create unique_index(:rail_journeys, [:claim_id, :kind])
    create index(:rail_journeys, [:user_id, :claim_id])

    create table(:rail_segments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :position, :integer, null: false
      add :origin_name, :string, null: false
      add :destination_name, :string, null: false
      add :origin_external_id, :map
      add :destination_external_id, :map
      add :train_category, :string
      add :train_number, :string
      add :scheduled_departure, :utc_datetime_usec
      add :scheduled_arrival, :utc_datetime_usec
      add :estimated_departure, :utc_datetime_usec
      add :estimated_arrival, :utc_datetime_usec
      add :actual_departure, :utc_datetime_usec
      add :actual_arrival, :utc_datetime_usec
      add :cancelled, :boolean, null: false, default: false
      add :external_id, :map
      add :source, :string, null: false
      add :source_metadata, :map, null: false, default: %{}
      add :fetched_at, :utc_datetime_usec, null: false
      add :manual, :boolean, null: false, default: false

      add :journey_id,
          references(:rail_journeys, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:rail_segments, :rail_segments_position_check, check: "position > 0")
    create unique_index(:rail_segments, [:journey_id, :position])
    create index(:rail_segments, [:journey_id])

    create table(:rail_api_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :operation, :string, null: false
      add :content_type, :string, null: false
      add :payload, :text, null: false
      add :sha256, :binary, null: false
      add :fetched_at, :utc_datetime_usec, null: false
      add :metadata, :map, null: false, default: %{}

      add :claim_id, references(:claims, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:rail_api_snapshots, [:user_id, :claim_id, :fetched_at])
  end
end
