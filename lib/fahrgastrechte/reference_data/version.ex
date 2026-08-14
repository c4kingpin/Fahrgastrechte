defmodule Fahrgastrechte.ReferenceData.Version do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fahrgastrechte.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @kinds [:official_form, :bahn_vorhersage_archive]

  @type kind :: :official_form | :bahn_vorhersage_archive
  @type t :: %__MODULE__{}

  schema "reference_data_versions" do
    field :kind, Ecto.Enum, values: @kinds
    field :version, :string
    field :source_url, :string
    field :original_filename, :string
    field :storage_key, :string, redact: true
    field :size_bytes, :integer
    field :sha256, :binary, redact: true
    field :metadata, :map, default: %{}
    field :current, :boolean, default: true

    belongs_to :uploaded_by_user, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def create_changeset(version, attrs) do
    version
    |> cast(attrs, [
      :kind,
      :version,
      :source_url,
      :original_filename,
      :storage_key,
      :size_bytes,
      :sha256,
      :metadata,
      :current
    ])
    |> validate_required([
      :uploaded_by_user_id,
      :kind,
      :version,
      :original_filename,
      :storage_key,
      :size_bytes,
      :sha256,
      :metadata
    ])
    |> validate_length(:version, min: 1, max: 120)
    |> validate_length(:source_url, max: 2_000)
    |> validate_length(:original_filename, min: 1, max: 255)
    |> validate_length(:storage_key, is: 64)
    |> validate_number(:size_bytes, greater_than: 0)
    |> validate_source_url()
    |> unique_constraint(:storage_key)
    |> unique_constraint(:kind, name: :reference_data_one_current_version_per_kind)
  end

  def kinds, do: @kinds

  defp validate_source_url(changeset) do
    validate_change(changeset, :source_url, fn :source_url, source_url ->
      uri = URI.parse(source_url)

      if uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo) and
           is_nil(uri.fragment) do
        []
      else
        [source_url: "muss eine gültige HTTPS-Adresse sein"]
      end
    end)
  end
end
