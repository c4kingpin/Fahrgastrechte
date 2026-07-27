defmodule Fahrgastrechte.Repo.Migrations.CreateDocumentsAndTicketSuggestions do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :claim_id, references(:claims, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :original_filename, :string, null: false
      add :storage_key, :string, null: false
      add :size_bytes, :bigint, null: false
      add :page_count, :integer, null: false
      add :sha256, :binary, null: false
      add :mime_type, :string, null: false
      add :encrypted, :boolean, null: false, default: false
      add :current, :boolean, null: false, default: true
      add :deletion_pending_at, :utc_datetime_usec
      add :analysis_status, :string, null: false, default: "not_started"
      add :analysis_error, :string
      add :analyzed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:documents, [:storage_key])
    create index(:documents, [:user_id, :claim_id])
    create index(:documents, [:claim_id, :kind])

    create unique_index(:documents, [:claim_id, :kind],
             where: "current = true",
             name: :documents_one_current_kind_per_claim
           )

    create constraint(:documents, :documents_kind_must_be_valid,
             check:
               "kind IN ('ticket', 'invoice', 'generated_cover', 'generated_form', 'generated_bundle')"
           )

    create constraint(:documents, :documents_size_must_be_positive, check: "size_bytes > 0")
    create constraint(:documents, :documents_page_count_must_be_positive, check: "page_count > 0")

    create constraint(:documents, :documents_analysis_status_must_be_valid,
             check: "analysis_status IN ('not_started', 'completed', 'manual_required', 'failed')"
           )

    create table(:ticket_suggestions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :field, :string, null: false
      add :value, :map, null: false
      add :confidence, :float, null: false
      add :source_page, :integer, null: false
      add :source_excerpt, :text, null: false
      add :state, :string, null: false, default: "proposed"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ticket_suggestions, [:document_id, :field])

    create constraint(:ticket_suggestions, :ticket_suggestions_field_must_be_valid,
             check:
               "field IN ('order_number', 'travel_date', 'valid_until', 'origin', 'destination', 'product', 'fare', 'scheduled_train', 'scheduled_departure', 'scheduled_arrival')"
           )

    create constraint(:ticket_suggestions, :ticket_suggestions_state_must_be_valid,
             check: "state IN ('proposed', 'accepted', 'rejected')"
           )

    create constraint(:ticket_suggestions, :ticket_suggestions_confidence_must_be_valid,
             check: "confidence >= 0.0 AND confidence <= 1.0"
           )

    create constraint(:ticket_suggestions, :ticket_suggestions_page_must_be_positive,
             check: "source_page > 0"
           )
  end
end
