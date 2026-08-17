defmodule Fahrgastrechte.Repo.Migrations.AddClaimDeletionPendingAt do
  use Ecto.Migration

  def change do
    alter table(:claims) do
      add :deletion_pending_at, :utc_datetime_usec
    end
  end
end
