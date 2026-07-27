defmodule Fahrgastrechte.Rail.ApiSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Claims.Claim

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}

  schema "rail_api_snapshots" do
    field :provider, :string
    field :operation, :string
    field :content_type, :string
    field :payload, :string
    field :sha256, :binary
    field :fetched_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :claim, Claim, type: :binary_id
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :provider,
      :operation,
      :content_type,
      :payload,
      :sha256,
      :fetched_at,
      :metadata
    ])
    |> validate_required([
      :claim_id,
      :user_id,
      :provider,
      :operation,
      :content_type,
      :payload,
      :sha256,
      :fetched_at
    ])
    |> validate_length(:provider, max: 255)
    |> validate_length(:operation, max: 100)
    |> validate_length(:content_type, max: 255)
  end
end
