defmodule Fahrgastrechte.Repo.Migrations.CreateClaimsAndStatusHistory do
  use Ecto.Migration

  def change do
    create table(:claims, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :claim_number, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "draft"
      add :travel_date, :date
      add :origin, :string
      add :destination, :string
      add :disruption_type, :string
      add :compensation_method, :string, null: false, default: "bank_transfer"
      add :generated_at, :utc_datetime_usec
      add :sent_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:claims, [:claim_number])
    create index(:claims, [:user_id, :inserted_at])
    create index(:claims, [:user_id, :status])
    create index(:claims, [:user_id, :travel_date])

    create constraint(:claims, :claims_status_must_be_valid,
             check: "status IN ('draft', 'ready', 'sent', 'completed')"
           )

    create constraint(:claims, :claims_disruption_type_must_be_valid,
             check: "disruption_type IS NULL OR disruption_type IN ('delay', 'cancellation')"
           )

    create constraint(:claims, :claims_compensation_method_must_be_bank_transfer,
             check: "compensation_method = 'bank_transfer'"
           )

    create constraint(:claims, :claims_lock_version_must_be_positive, check: "lock_version > 0")

    create table(:claim_status_history, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :claim_id, references(:claims, type: :binary_id, on_delete: :delete_all), null: false
      add :actor_user_id, references(:users, on_delete: :delete_all), null: false
      add :from_status, :string
      add :to_status, :string, null: false
      add :reason, :string, null: false
      add :changed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:claim_status_history, [:claim_id, :changed_at])

    create constraint(:claim_status_history, :claim_history_from_status_must_be_valid,
             check:
               "from_status IS NULL OR from_status IN ('draft', 'ready', 'sent', 'completed')"
           )

    create constraint(:claim_status_history, :claim_history_to_status_must_be_valid,
             check: "to_status IN ('draft', 'ready', 'sent', 'completed')"
           )
  end
end
