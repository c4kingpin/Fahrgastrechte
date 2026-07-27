defmodule Fahrgastrechte.Repo.Migrations.CreateExportVersions do
  use Ecto.Migration

  def change do
    create table(:export_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :claim_id, references(:claims, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :version, :integer, null: false
      add :template_version, :string, null: false
      add :template_source, :string, null: false
      add :template_sha256, :binary, null: false
      add :model_sha256, :binary, null: false

      add :cover_document_id,
          references(:documents, type: :binary_id),
          null: false

      add :form_document_id,
          references(:documents, type: :binary_id),
          null: false

      add :bundle_document_id,
          references(:documents, type: :binary_id),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:export_versions, [:claim_id, :version])
    create index(:export_versions, [:user_id, :claim_id])
    create unique_index(:export_versions, [:bundle_document_id])

    create constraint(:export_versions, :export_version_must_be_positive, check: "version > 0")
  end
end
