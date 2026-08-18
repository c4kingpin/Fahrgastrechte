defmodule Fahrgastrechte.ClaimWorkspace.ReadModel do
  @moduledoc """
  Checked, user-scoped snapshot consumed by the claim workspace.

  Collections needed for lookup are indexed here; render-only collections are
  handed to LiveView streams by the caller.
  """

  @enforce_keys [
    :claim,
    :claim_changeset,
    :documents_by_kind,
    :documents_by_id,
    :suggestions_by_id,
    :suggestion_groups,
    :suggestion_duplicates,
    :planned_journey,
    :actual_journey,
    :exports,
    :current_export,
    :api_sources,
    :status_history,
    :profile_complete?,
    :profile_error,
    :claim_complete?,
    :documents_complete?,
    :suggestions_complete?,
    :planned_complete?,
    :actual_complete?,
    :review_complete?,
    :exports_available?,
    :step_states,
    :readiness
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          claim: Fahrgastrechte.Claims.Claim.t(),
          claim_changeset: Ecto.Changeset.t(),
          documents_by_kind: map(),
          documents_by_id: map(),
          suggestions_by_id: map(),
          suggestion_groups: map(),
          suggestion_duplicates: map(),
          planned_journey: struct() | nil,
          actual_journey: struct() | nil,
          exports: [struct()],
          current_export: Fahrgastrechte.Exports.ExportVersion.t() | nil,
          api_sources: [struct()],
          status_history: [struct()],
          profile_complete?: boolean(),
          profile_error: term() | nil,
          claim_complete?: boolean(),
          documents_complete?: boolean(),
          suggestions_complete?: boolean(),
          planned_complete?: boolean(),
          actual_complete?: boolean(),
          review_complete?: boolean(),
          exports_available?: boolean(),
          step_states: map(),
          readiness: {:ok, map()} | {:error, term()}
        }
end
