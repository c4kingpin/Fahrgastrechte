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
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Documents.Document
  alias Fahrgastrechte.Repo
  alias Fahrgastrechte.Tickets.Suggestion

  @type domain_error ::
          :not_authenticated
          | :not_found
          | :not_editable
          | :stale
          | :invalid_document_kind
          | :invalid_state
          | :analysis_failed

  @doc "Analyzes one current ticket or invoice and invalidates its claim output."
  @spec analyze_document(Scope.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, %{document: Document.t(), suggestions: [Suggestion.t()], claim: Claims.Claim.t()}}
          | {:error, Changeset.t() | domain_error()}
  def analyze_document(%Scope{} = scope, document_id, expected_claim_lock_version) do
    Documents.with_document_path(scope, document_id, fn path, document ->
      analyze_path(scope, document, path, expected_claim_lock_version)
    end)
  end

  def analyze_document(_scope, _document_id, _expected_claim_lock_version),
    do: {:error, :not_authenticated}

  def analyze_document(%Scope{} = scope, document_id) do
    with {:ok, document} <- Documents.get_document(scope, document_id),
         {:ok, claim} <- Claims.get_claim(scope, document.claim_id) do
      analyze_document(scope, document_id, claim.lock_version)
    end
  end

  def analyze_document(_scope, _document_id), do: {:error, :not_authenticated}

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

  @doc "Changes a suggestion state and invalidates the owning claim atomically."
  @spec set_suggestion_state(
          Scope.t(),
          Ecto.UUID.t(),
          Suggestion.state() | String.t(),
          pos_integer()
        ) ::
          {:ok, %{suggestion: Suggestion.t(), claim: Claims.Claim.t()}}
          | {:error, Changeset.t() | domain_error()}
  def set_suggestion_state(
        %Scope{user: %User{id: user_id}} = scope,
        suggestion_id,
        requested_state,
        expected_claim_lock_version
      )
      when is_binary(suggestion_id) do
    with {:ok, state} <- parse_state(requested_state),
         {%Suggestion{} = suggestion, claim_id} <- scoped_suggestion(user_id, suggestion_id) do
      Repo.transaction(fn ->
        with {:ok, claim} <-
               Claims.invalidate_output(scope, claim_id, expected_claim_lock_version),
             {:ok, updated_suggestion} <-
               suggestion |> Suggestion.state_changeset(state) |> Repo.update() do
          %{suggestion: updated_suggestion, claim: claim}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def set_suggestion_state(_scope, _suggestion_id, _state, _expected_claim_lock_version),
    do: {:error, :not_authenticated}

  def set_suggestion_state(%Scope{user: %User{id: user_id}} = scope, suggestion_id, state) do
    with {_suggestion, claim_id} <- scoped_suggestion(user_id, suggestion_id),
         {:ok, claim} <- Claims.get_claim(scope, claim_id),
         {:ok, %{suggestion: suggestion}} <-
           set_suggestion_state(scope, suggestion_id, state, claim.lock_version) do
      {:ok, suggestion}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def set_suggestion_state(_scope, _suggestion_id, _state),
    do: {:error, :not_authenticated}

  @doc "Changes several same-claim suggestion states and invalidates that claim atomically."
  @spec set_suggestion_states(
          Scope.t(),
          [Ecto.UUID.t()],
          Suggestion.state() | String.t(),
          pos_integer()
        ) ::
          {:ok, %{suggestions: [Suggestion.t()], claim: Claims.Claim.t()}}
          | {:error, Changeset.t() | domain_error()}
  def set_suggestion_states(
        %Scope{user: %User{id: user_id}} = scope,
        suggestion_ids,
        requested_state,
        expected_claim_lock_version
      )
      when is_list(suggestion_ids) do
    with {:ok, state} <- parse_state(requested_state),
         {:ok, parsed_ids} <- cast_ids(suggestion_ids),
         suggestions_with_claims <- scoped_suggestions(user_id, parsed_ids),
         true <- length(suggestions_with_claims) == length(Enum.uniq(parsed_ids)),
         {:ok, claim_id} <- one_claim_id(suggestions_with_claims) do
      Repo.transaction(fn ->
        with {:ok, claim} <-
               Claims.invalidate_output(scope, claim_id, expected_claim_lock_version) do
          suggestions =
            Enum.map(suggestions_with_claims, fn {suggestion, _claim_id} ->
              suggestion
              |> Suggestion.state_changeset(state)
              |> Repo.update!()
            end)

          %{suggestions: suggestions, claim: claim}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def set_suggestion_states(_scope, _suggestion_ids, _state, _expected_claim_lock_version),
    do: {:error, :not_authenticated}

  def set_suggestion_states(%Scope{user: %User{id: user_id}} = scope, suggestion_ids, state) do
    with {:ok, parsed_ids} <- cast_ids(suggestion_ids),
         suggestions <- scoped_suggestions(user_id, parsed_ids),
         {:ok, claim_id} <- one_claim_id(suggestions),
         {:ok, claim} <- Claims.get_claim(scope, claim_id),
         {:ok, %{suggestions: updated}} <-
           set_suggestion_states(scope, suggestion_ids, state, claim.lock_version) do
      {:ok, updated}
    end
  end

  def set_suggestion_states(_scope, _suggestion_ids, _state),
    do: {:error, :not_authenticated}

  defp analyze_path(_scope, %Document{kind: kind}, _path, _expected_lock_version)
       when kind not in [:ticket, :invoice],
       do: {:error, :invalid_document_kind}

  defp analyze_path(scope, %Document{encrypted: true} = document, _path, expected_lock_version) do
    persist_analysis(
      scope,
      document,
      :manual_required,
      "encrypted",
      [],
      expected_lock_version
    )
  end

  defp analyze_path(scope, %Document{} = document, path, expected_lock_version) do
    extractor = tickets_config(:extractor)

    options = [
      pdftotext_executable: tickets_config(:pdftotext_executable),
      command_timeout_ms: tickets_config(:command_timeout_ms),
      max_text_bytes: tickets_config(:max_text_bytes),
      pages: document.page_count,
      document_kind: document.kind
    ]

    with {:ok, extraction} <- extractor.extract(path, options),
         {:ok, suggestions} <- extractor.propose(extraction, options) do
      persist_analysis(scope, document, :completed, nil, suggestions, expected_lock_version)
    else
      {:error, error} when error in [:no_text, :encrypted] ->
        persist_analysis(
          scope,
          document,
          :manual_required,
          Atom.to_string(error),
          [],
          expected_lock_version
        )

      {:error, error}
      when error in [:invalid_pdf, :resource_limit, :timeout] ->
        persist_analysis(
          scope,
          document,
          :failed,
          Atom.to_string(error),
          [],
          expected_lock_version
        )

      {:error, {:backend, _reason}} ->
        persist_analysis(scope, document, :failed, "backend", [], expected_lock_version)
    end
  end

  defp persist_analysis(
         scope,
         document,
         status,
         error,
         suggestions,
         expected_claim_lock_version
       ) do
    analyzed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    multi =
      Multi.new()
      |> Multi.run(:claim, fn _repo, _changes ->
        Claims.invalidate_output(scope, document.claim_id, expected_claim_lock_version)
      end)
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

        {:ok,
         %{
           document: changes.document,
           suggestions: inserted_suggestions,
           claim: changes.claim
         }}

      {:error, :claim, reason, _changes} ->
        {:error, reason}

      {:error, _operation, %Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _operation, _reason, _changes} ->
        {:error, :analysis_failed}
    end
  end

  defp scoped_suggestion(user_id, suggestion_id) do
    case Ecto.UUID.cast(suggestion_id) do
      {:ok, parsed_id} ->
        Repo.one(
          from suggestion in Suggestion,
            join: document in assoc(suggestion, :document),
            where:
              suggestion.id == ^parsed_id and document.user_id == ^user_id and
                document.current == true and is_nil(document.deletion_pending_at),
            select: {suggestion, document.claim_id}
        )

      :error ->
        nil
    end
  end

  defp scoped_suggestions(user_id, suggestion_ids) do
    Repo.all(
      from suggestion in Suggestion,
        join: document in assoc(suggestion, :document),
        where:
          suggestion.id in ^suggestion_ids and document.user_id == ^user_id and
            document.current == true and is_nil(document.deletion_pending_at),
        order_by: [asc: suggestion.field, asc: suggestion.id],
        select: {suggestion, document.claim_id}
    )
  end

  defp one_claim_id([]), do: {:error, :not_found}

  defp one_claim_id(suggestions_with_claims) do
    case suggestions_with_claims |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [claim_id] -> {:ok, claim_id}
      _claim_ids -> {:error, :not_found}
    end
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
