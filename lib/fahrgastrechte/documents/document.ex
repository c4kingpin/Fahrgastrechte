defmodule Fahrgastrechte.Documents.Document do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Claims.Claim
  alias Fahrgastrechte.Tickets.Suggestion

  @primary_key {:id, :binary_id, autogenerate: true}
  @kinds [:ticket, :invoice, :generated_cover, :generated_form, :generated_bundle]
  @original_kinds [:ticket, :invoice]
  @analysis_statuses [:not_started, :completed, :manual_required, :failed]

  @type kind ::
          :ticket | :invoice | :generated_cover | :generated_form | :generated_bundle
  @type analysis_status :: :not_started | :completed | :manual_required | :failed
  @type t :: %__MODULE__{}

  schema "documents" do
    field :kind, Ecto.Enum, values: @kinds
    field :original_filename, :string
    field :storage_key, :string, redact: true
    field :size_bytes, :integer
    field :page_count, :integer
    field :sha256, :binary, redact: true
    field :mime_type, :string
    field :encrypted, :boolean, default: false
    field :current, :boolean, default: true
    field :deletion_pending_at, :utc_datetime_usec
    field :analysis_status, Ecto.Enum, values: @analysis_statuses, default: :not_started
    field :analysis_error, :string
    field :analyzed_at, :utc_datetime_usec
    field :manual_fallback_confirmed_at, :utc_datetime_usec

    belongs_to :claim, Claim, type: :binary_id
    belongs_to :user, User
    has_many :suggestions, Suggestion

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(document, attrs) do
    document
    |> cast(attrs, [
      :kind,
      :original_filename,
      :storage_key,
      :size_bytes,
      :page_count,
      :sha256,
      :mime_type,
      :encrypted,
      :current
    ])
    |> validate_required([
      :claim_id,
      :user_id,
      :kind,
      :original_filename,
      :storage_key,
      :size_bytes,
      :page_count,
      :sha256,
      :mime_type
    ])
    |> validate_length(:original_filename, min: 1, max: 255)
    |> validate_length(:storage_key, is: 64)
    |> validate_number(:size_bytes, greater_than: 0)
    |> validate_number(:page_count, greater_than: 0)
    |> validate_inclusion(:mime_type, ["application/pdf"])
    |> unique_constraint(:storage_key)
    |> unique_constraint([:claim_id, :kind], name: :documents_one_current_kind_per_claim)
  end

  @doc """
  Applies a new automatic analysis result.

  Always clears any prior explicit manual-fallback confirmation: a new result
  (even a repeated failure) needs a fresh, deliberate confirmation rather than
  inheriting one that applied to a previous analysis attempt.
  """
  def analysis_changeset(document, attrs) do
    document
    |> change(manual_fallback_confirmed_at: nil)
    |> cast(attrs, [:analysis_status, :analysis_error, :analyzed_at])
    |> validate_required([:analysis_status, :analyzed_at])
    |> validate_length(:analysis_error, max: 100)
  end

  @doc "Explicit user confirmation to proceed manually after a failed analysis."
  def manual_fallback_changeset(document) do
    change(document,
      manual_fallback_confirmed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    )
  end

  @doc false
  def replacement_changeset(document, timestamp) do
    change(document, current: false, deletion_pending_at: timestamp)
  end

  @doc false
  def deletion_changeset(document, timestamp) do
    change(document, current: false, deletion_pending_at: timestamp)
  end

  def kinds, do: @kinds
  def original_kinds, do: @original_kinds
end
