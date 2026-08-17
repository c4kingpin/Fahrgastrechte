defmodule Fahrgastrechte.Repo.Migrations.AddManualFallbackConfirmedAtToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :manual_fallback_confirmed_at, :utc_datetime_usec
    end
  end
end
