defmodule Fahrgastrechte.Claims.StatusHistory do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Claims.Claim

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "claim_status_history" do
    field :from_status, Ecto.Enum, values: Claim.statuses()
    field :to_status, Ecto.Enum, values: Claim.statuses()
    field :reason, :string
    field :changed_at, :utc_datetime_usec

    belongs_to :claim, Claim, type: :binary_id
    belongs_to :actor_user, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(history, attrs) do
    history
    |> cast(attrs, [:from_status, :to_status, :reason, :changed_at])
    |> validate_required([:claim_id, :actor_user_id, :to_status, :reason, :changed_at])
    |> validate_length(:reason, max: 100)
  end
end
