defmodule Fahrgastrechte.Repo.Migrations.CreateAccountsUsersAndProfiles do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :issuer, :string, null: false
      add :subject, :string, null: false
      add :email, :string
      add :display_name, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:issuer, :subject])

    create table(:traveller_profiles) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :salutation, :string
      add :title, :string
      add :first_name, :string
      add :last_name, :string
      add :street, :string
      add :house_number, :string
      add :postal_code, :string
      add :city, :string
      add :country, :string
      add :phone_number, :string
      add :account_holder, :string
      add :iban_ciphertext, :binary
      add :bic_ciphertext, :binary
      add :bank_data_key_version, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:traveller_profiles, [:user_id])
  end
end
