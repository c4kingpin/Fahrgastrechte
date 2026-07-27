defmodule Fahrgastrechte.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fahrgastrechte.Accounts.Identity
  alias Fahrgastrechte.Accounts.Profile

  @type t :: %__MODULE__{}

  schema "users" do
    field :issuer, :string
    field :subject, :string
    field :email, :string
    field :display_name, :string

    has_one :profile, Profile

    timestamps(type: :utc_datetime)
  end

  @doc false
  def identity_changeset(user, %Identity{} = identity) do
    user
    |> cast(Map.from_struct(identity), [:issuer, :subject, :email, :display_name])
    |> validate_required([:issuer, :subject])
    |> validate_length(:issuer, max: 500)
    |> validate_length(:subject, max: 255)
    |> validate_length(:email, max: 320)
    |> validate_length(:display_name, max: 255)
    |> unique_constraint([:issuer, :subject])
  end
end
