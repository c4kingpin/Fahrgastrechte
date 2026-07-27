defmodule Fahrgastrechte.Exports.ExportVersion do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Claims.Claim
  alias Fahrgastrechte.Documents.Document

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}

  schema "export_versions" do
    field :version, :integer
    field :template_version, :string
    field :template_source, :string
    field :template_sha256, :binary, redact: true
    field :model_sha256, :binary, redact: true

    belongs_to :claim, Claim, type: :binary_id
    belongs_to :user, User
    belongs_to :cover_document, Document, type: :binary_id
    belongs_to :form_document, Document, type: :binary_id
    belongs_to :bundle_document, Document, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def create_changeset(export, attrs) do
    export
    |> cast(attrs, [
      :version,
      :template_version,
      :template_source,
      :template_sha256,
      :model_sha256,
      :cover_document_id,
      :form_document_id,
      :bundle_document_id
    ])
    |> validate_required([
      :claim_id,
      :user_id,
      :version,
      :template_version,
      :template_source,
      :template_sha256,
      :model_sha256,
      :cover_document_id,
      :form_document_id,
      :bundle_document_id
    ])
    |> validate_number(:version, greater_than: 0)
    |> validate_length(:template_version, min: 1, max: 100)
    |> validate_length(:template_source, min: 1, max: 500)
    |> unique_constraint([:claim_id, :version])
    |> unique_constraint(:bundle_document_id)
  end
end
