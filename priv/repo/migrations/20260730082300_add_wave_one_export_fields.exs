defmodule Fahrgastrechte.Repo.Migrations.AddWaveOneExportFields do
  use Ecto.Migration

  def up do
    rename table(:claims), :disruption_type, to: :disruption_cause

    alter table(:claims) do
      add :journey_outcome, :string
      add :journey_direction, :string, null: false, default: "outbound"
    end

    execute("""
    UPDATE claims
    SET journey_outcome = 'delayed_arrival'
    WHERE disruption_cause IS NOT NULL
    """)

    drop constraint(:claims, :claims_disruption_type_must_be_valid)

    create constraint(:claims, :claims_disruption_cause_must_be_valid,
             check:
               "disruption_cause IS NULL OR disruption_cause IN ('delay', 'cancellation', 'missed_connection')"
           )

    create constraint(:claims, :claims_journey_outcome_must_be_valid,
             check:
               "journey_outcome IS NULL OR journey_outcome IN ('delayed_arrival', 'not_started', 'aborted', 'continued_with_other_transport')"
           )

    create constraint(:claims, :claims_journey_direction_must_be_valid,
             check: "journey_direction IN ('outbound', 'return')"
           )
  end

  def down do
    drop constraint(:claims, :claims_disruption_cause_must_be_valid)
    drop constraint(:claims, :claims_journey_outcome_must_be_valid)
    drop constraint(:claims, :claims_journey_direction_must_be_valid)

    execute("""
    UPDATE claims
    SET disruption_cause = 'delay'
    WHERE disruption_cause = 'missed_connection'
    """)

    alter table(:claims) do
      remove :journey_outcome
      remove :journey_direction
    end

    rename table(:claims), :disruption_cause, to: :disruption_type

    create constraint(:claims, :claims_disruption_type_must_be_valid,
             check: "disruption_type IS NULL OR disruption_type IN ('delay', 'cancellation')"
           )
  end
end
