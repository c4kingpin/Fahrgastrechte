defmodule Fahrgastrechte.Repo.Migrations.CreateReferenceDataVersions do
  use Ecto.Migration

  def change do
    create table(:reference_data_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :version, :string, null: false
      add :source_url, :text
      add :original_filename, :string, null: false
      add :storage_key, :string, null: false
      add :size_bytes, :bigint, null: false
      add :sha256, :binary, null: false
      add :metadata, :map, null: false, default: %{}
      add :current, :boolean, null: false, default: true

      add :uploaded_by_user_id, references(:users, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:reference_data_versions, [:storage_key])
    create index(:reference_data_versions, [:kind, :inserted_at])

    create unique_index(:reference_data_versions, [:kind],
             where: "current = true",
             name: :reference_data_one_current_version_per_kind
           )

    create constraint(:reference_data_versions, :reference_data_kind_must_be_valid,
             check: "kind IN ('official_form', 'bahn_vorhersage_archive')"
           )

    create constraint(:reference_data_versions, :reference_data_size_must_be_positive,
             check: "size_bytes > 0"
           )
  end
end
