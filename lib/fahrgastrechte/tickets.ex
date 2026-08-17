defmodule Fahrgastrechte.Tickets do
  @moduledoc """
  Text-only ticket analysis and traceable, unconfirmed suggestions.

  OCR is deliberately absent. Encrypted or textless PDFs persist a
  `manual_required` analysis result instead of blocking the claim workflow.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Claims.Claim
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Documents.Document
  alias Fahrgastrechte.Documents.PDFJobLimiter
  alias Fahrgastrechte.Rail
  alias Fahrgastrechte.Repo
  alias Fahrgastrechte.Tickets.Classifier
  alias Fahrgastrechte.Tickets.StationNormalizer
  alias Fahrgastrechte.Tickets.Suggestion

  @type domain_error ::
          :not_authenticated
          | :not_found
          | :invalid_document_kind
          | :invalid_state
          | :analysis_failed

  @doc """
  Classifies an unpersisted PDF as `:ticket` or `:invoice` from its embedded text.

  Used to route a single shared upload area to the correct document kind
  before the file is stored. Returns `{:error, :ambiguous}` for extraction
  failures and score ties alike; callers fall back to the document kind the
  claim is still missing.
  """
  @spec classify_upload(Path.t()) :: {:ok, :ticket | :invoice, float()} | {:error, :ambiguous}
  def classify_upload(path) when is_binary(path) do
    extractor = tickets_config(:extractor)

    options = [
      pdftotext_executable: tickets_config(:pdftotext_executable),
      command_timeout_ms: tickets_config(:command_timeout_ms),
      max_text_bytes: tickets_config(:max_text_bytes),
      pages: nil
    ]

    with {:ok, extraction} <-
           PDFJobLimiter.with_permit(fn -> extractor.extract(path, options) end) do
      Classifier.classify(extraction.text)
    else
      {:error, _reason} -> {:error, :ambiguous}
    end
  end

  @doc """
  Analyzes one current ticket or invoice and replaces its previous suggestions.

  Requires the claim to be editable; re-analyzing a `ready` claim invalidates
  its output the same way any other dependent-data change does.
  """
  @spec analyze_document(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, %{document: Document.t(), suggestions: [Suggestion.t()]}}
          | {:error, Changeset.t() | domain_error()}
  def analyze_document(%Scope{} = scope, claim_id, document_id, expected_lock_version) do
    with {:ok, claim} <- Claims.ensure_editable(scope, claim_id, expected_lock_version),
         {:ok, _claim} <- maybe_invalidate_output(scope, claim, expected_lock_version) do
      Documents.with_document_path(scope, claim_id, document_id, fn path, document ->
        analyze_path(scope, claim_id, document, path)
      end)
    end
  end

  def analyze_document(_scope, _claim_id, _document_id, _expected_lock_version),
    do: {:error, :not_authenticated}

  @doc """
  Explicitly confirms a manual fallback for a document whose automatic
  analysis failed with a technical error.

  Only permitted while `analysis_status` is `:failed` — this is a deliberate
  escape hatch after a technical failure, not a way to skip analysis
  proactively. Requires the claim to be editable; on a `ready` claim this
  invalidates its output the same way `analyze_document/4` does.
  """
  @spec confirm_manual_fallback(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, Document.t()} | {:error, Changeset.t() | domain_error()}
  def confirm_manual_fallback(%Scope{} = scope, claim_id, document_id, expected_lock_version) do
    with {:ok, claim} <- Claims.ensure_editable(scope, claim_id, expected_lock_version),
         {:ok, _claim} <- maybe_invalidate_output(scope, claim, expected_lock_version),
         {:ok, document} <- Documents.get_claim_document(scope, claim_id, document_id) do
      case document do
        %Document{analysis_status: :failed} ->
          document
          |> Document.manual_fallback_changeset()
          |> Repo.update()

        %Document{} ->
          {:error, :invalid_state}
      end
    end
  end

  def confirm_manual_fallback(_scope, _claim_id, _document_id, _expected_lock_version),
    do: {:error, :not_authenticated}

  @doc "Lists persisted suggestions only for an authorized current document."
  @spec list_suggestions(Scope.t(), Ecto.UUID.t()) ::
          {:ok, [Suggestion.t()]} | {:error, domain_error()}
  def list_suggestions(%Scope{} = scope, document_id) do
    with {:ok, document} <- Documents.get_document(scope, document_id) do
      suggestions =
        Repo.all(
          from suggestion in Suggestion,
            where: suggestion.document_id == ^document.id,
            order_by: [asc: suggestion.field]
        )

      {:ok, suggestions}
    end
  end

  def list_suggestions(_scope, _document_id), do: {:error, :not_authenticated}

  @doc "Lists suggestions for all current ticket inputs of one scoped claim."
  @spec list_claim_suggestions(Scope.t(), Ecto.UUID.t()) ::
          {:ok, [Suggestion.t()]} | {:error, domain_error()}
  def list_claim_suggestions(%Scope{user: %User{id: user_id}} = scope, claim_id) do
    with {:ok, claim} <- Claims.get_claim(scope, claim_id) do
      suggestions =
        Repo.all(
          from suggestion in Suggestion,
            join: document in Document,
            on: document.id == suggestion.document_id,
            where:
              document.claim_id == ^claim.id and document.user_id == ^user_id and
                document.current == true and is_nil(document.deletion_pending_at) and
                document.kind in [:ticket, :invoice],
            order_by: [asc: document.kind, asc: suggestion.field, asc: suggestion.id]
        )

      {:ok, suggestions}
    end
  end

  def list_claim_suggestions(%Scope{}, _claim_id), do: {:error, :not_found}
  def list_claim_suggestions(_scope, _claim_id), do: {:error, :not_authenticated}

  @doc """
  Marks a scoped suggestion accepted, rejected or proposed without changing its value.

  Requires the claim to be editable; accepting/rejecting on a `ready` claim
  invalidates its output atomically alongside the suggestion change.
  """
  @spec set_suggestion_state(
          Scope.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Suggestion.state() | String.t(),
          pos_integer()
        ) ::
          {:ok, Suggestion.t()} | {:error, Changeset.t() | domain_error()}
  def set_suggestion_state(
        %Scope{user: %User{id: user_id}} = scope,
        claim_id,
        suggestion_id,
        requested_state,
        expected_lock_version
      )
      when is_binary(suggestion_id) do
    with {:ok, state} <- parse_state(requested_state) do
      Repo.transaction(fn ->
        with {:ok, claim} <- Claims.ensure_editable(scope, claim_id, expected_lock_version),
             {:ok, _claim} <- maybe_invalidate_output(scope, claim, expected_lock_version),
             %Suggestion{} = suggestion <- scoped_suggestion(user_id, claim_id, suggestion_id) do
          suggestion
          |> Suggestion.state_changeset(state)
          |> Repo.update!()
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def set_suggestion_state(_scope, _claim_id, _suggestion_id, _state, _expected_lock_version),
    do: {:error, :not_authenticated}

  @doc """
  Marks several scoped suggestions with one state in one transaction.

  Requires the claim to be editable; accepting/rejecting on a `ready` claim
  invalidates its output atomically alongside the suggestion changes.
  """
  @spec set_suggestion_states(
          Scope.t(),
          Ecto.UUID.t(),
          [Ecto.UUID.t()],
          Suggestion.state() | String.t(),
          pos_integer()
        ) ::
          {:ok, [Suggestion.t()]} | {:error, Changeset.t() | domain_error()}
  def set_suggestion_states(
        %Scope{user: %User{id: user_id}} = scope,
        claim_id,
        suggestion_ids,
        requested_state,
        expected_lock_version
      )
      when is_list(suggestion_ids) do
    with {:ok, state} <- parse_state(requested_state),
         {:ok, parsed_ids} <- cast_ids(suggestion_ids) do
      Repo.transaction(fn ->
        with {:ok, claim} <- Claims.ensure_editable(scope, claim_id, expected_lock_version),
             {:ok, _claim} <- maybe_invalidate_output(scope, claim, expected_lock_version),
             suggestions <- scoped_suggestions(user_id, claim_id, parsed_ids),
             true <- length(suggestions) == length(Enum.uniq(parsed_ids)) do
          Enum.map(suggestions, fn suggestion ->
            suggestion
            |> Suggestion.state_changeset(state)
            |> Repo.update!()
          end)
        else
          false -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def set_suggestion_states(_scope, _claim_id, _suggestion_ids, _state, _expected_lock_version),
    do: {:error, :not_authenticated}

  @doc """
  Replaces a proposed origin/destination suggestion's station match.

  Used when the user picks a different candidate than `StationNormalizer`'s
  best guess, or resolves one manually via a free-text station search. Only
  proposed suggestions can be changed this way, matching the accept/reject
  buttons that only ever show for a `:proposed` suggestion. Requires the
  claim to be editable, mirroring `set_suggestion_state/5` — the suggestion
  isn't reflected in the claim's exported data until accepted, so unlike
  accept/reject this never needs to invalidate a `ready` claim's output.
  """
  @spec set_suggestion_station(
          Scope.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          %{name: String.t(), id: map() | nil},
          pos_integer()
        ) ::
          {:ok, Suggestion.t()} | {:error, Changeset.t() | domain_error()}
  def set_suggestion_station(
        %Scope{user: %User{id: user_id}} = scope,
        claim_id,
        suggestion_id,
        %{name: name} = station,
        expected_lock_version
      )
      when is_binary(suggestion_id) and is_binary(name) do
    with {:ok, _claim} <- Claims.ensure_editable(scope, claim_id, expected_lock_version) do
      case scoped_suggestion(user_id, claim_id, suggestion_id) do
        %Suggestion{state: :proposed} = suggestion ->
          value =
            suggestion.value
            |> Map.put("text", name)
            |> put_or_delete_station_id(Map.get(station, :id))
            |> Map.delete("unresolved")

          suggestion
          |> Suggestion.value_changeset(value)
          |> Repo.update()

        %Suggestion{} ->
          {:error, :invalid_state}

        nil ->
          {:error, :not_found}
      end
    end
  end

  def set_suggestion_station(
        _scope,
        _claim_id,
        _suggestion_id,
        _station,
        _expected_lock_version
      ),
      do: {:error, :not_authenticated}

  # Only :draft/:ready reach this function; ensure_editable/3 already rejects
  # :sent and :completed before either caller invokes it.
  defp maybe_invalidate_output(_scope, %Claim{status: :draft} = claim, _expected_lock_version),
    do: {:ok, claim}

  defp maybe_invalidate_output(scope, %Claim{status: :ready} = claim, expected_lock_version),
    do: Claims.invalidate_output(scope, claim.id, expected_lock_version)

  defp analyze_path(_scope, _claim_id, %Document{kind: kind}, _path)
       when kind not in [:ticket, :invoice],
       do: {:error, :invalid_document_kind}

  defp analyze_path(_scope, _claim_id, %Document{encrypted: true} = document, _path) do
    persist_analysis(document, :manual_required, "encrypted", [])
  end

  defp analyze_path(scope, claim_id, %Document{} = document, path) do
    extractor = tickets_config(:extractor)

    options = [
      pdftotext_executable: tickets_config(:pdftotext_executable),
      command_timeout_ms: tickets_config(:command_timeout_ms),
      max_text_bytes: tickets_config(:max_text_bytes),
      pages: document.page_count,
      document_kind: document.kind
    ]

    with {:ok, extraction} <-
           PDFJobLimiter.with_permit(fn -> extractor.extract(path, options) end),
         {:ok, extracted_suggestions} <- extractor.propose(extraction, options) do
      suggestions = normalize_stations(scope, claim_id, extracted_suggestions)
      persist_analysis(document, :completed, nil, suggestions)
    else
      {:error, error} when error in [:no_text, :encrypted] ->
        persist_analysis(document, :manual_required, Atom.to_string(error), [])

      {:error, error}
      when error in [:invalid_pdf, :resource_limit, :timeout, :busy] ->
        persist_analysis(document, :failed, Atom.to_string(error), [])

      {:error, {:backend, _reason}} ->
        persist_analysis(document, :failed, "backend", [])
    end
  end

  defp put_or_delete_station_id(value, nil), do: Map.delete(value, "station_id")
  defp put_or_delete_station_id(value, id), do: Map.put(value, "station_id", id)

  defp normalize_stations(scope, claim_id, suggestions) do
    StationNormalizer.normalize(suggestions, fn query ->
      Rail.search_stations(scope, claim_id, query, provider: Rail.Providers.StationCatalog)
    end)
  end

  defp persist_analysis(document, status, error, suggestions) do
    analyzed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    multi =
      Multi.new()
      |> Multi.update(
        :document,
        Document.analysis_changeset(document, %{
          analysis_status: status,
          analysis_error: error,
          analyzed_at: analyzed_at
        })
      )
      |> Multi.delete_all(
        :old_suggestions,
        from(suggestion in Suggestion, where: suggestion.document_id == ^document.id)
      )

    multi =
      suggestions
      |> Enum.with_index()
      |> Enum.reduce(multi, fn {suggestion, index}, current_multi ->
        changeset =
          Suggestion.changeset(
            %Suggestion{document_id: document.id},
            %{
              field: suggestion.field,
              value: suggestion.value,
              confidence: suggestion.confidence,
              source_page: suggestion.source.page,
              source_excerpt: suggestion.source.excerpt,
              state: :proposed
            }
          )

        Multi.insert(current_multi, {:suggestion, index}, changeset)
      end)

    case Repo.transaction(multi) do
      {:ok, changes} ->
        inserted_suggestions =
          changes
          |> Enum.filter(fn {key, _value} -> match?({:suggestion, _index}, key) end)
          |> Enum.sort_by(fn {{:suggestion, index}, _value} -> index end)
          |> Enum.map(fn {_key, suggestion} -> suggestion end)

        {:ok, %{document: changes.document, suggestions: inserted_suggestions}}

      {:error, _operation, %Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _operation, _reason, _changes} ->
        {:error, :analysis_failed}
    end
  end

  defp scoped_suggestion(user_id, claim_id, suggestion_id) do
    case Ecto.UUID.cast(suggestion_id) do
      {:ok, parsed_id} ->
        Repo.one(
          from suggestion in Suggestion,
            join: document in assoc(suggestion, :document),
            where:
              suggestion.id == ^parsed_id and document.claim_id == ^claim_id and
                document.user_id == ^user_id and
                document.current == true and is_nil(document.deletion_pending_at),
            select: suggestion
        )

      :error ->
        nil
    end
  end

  defp scoped_suggestions(user_id, claim_id, suggestion_ids) do
    Repo.all(
      from suggestion in Suggestion,
        join: document in assoc(suggestion, :document),
        where:
          suggestion.id in ^suggestion_ids and document.claim_id == ^claim_id and
            document.user_id == ^user_id and
            document.current == true and is_nil(document.deletion_pending_at),
        order_by: [asc: suggestion.field, asc: suggestion.id],
        select: suggestion
    )
  end

  defp cast_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, parsed_ids} ->
      case Ecto.UUID.cast(id) do
        {:ok, parsed_id} -> {:cont, {:ok, [parsed_id | parsed_ids]}}
        :error -> {:halt, {:error, :not_found}}
      end
    end)
    |> case do
      {:ok, parsed_ids} -> {:ok, Enum.reverse(parsed_ids)}
      error -> error
    end
  end

  defp parse_state(state) when state in [:proposed, :accepted, :rejected], do: {:ok, state}

  defp parse_state(state) when is_binary(state) do
    case Enum.find([:proposed, :accepted, :rejected], &(Atom.to_string(&1) == state)) do
      nil -> {:error, :invalid_state}
      parsed -> {:ok, parsed}
    end
  end

  defp parse_state(_state), do: {:error, :invalid_state}

  defp tickets_config(key) do
    :fahrgastrechte
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(key)
  end
end
