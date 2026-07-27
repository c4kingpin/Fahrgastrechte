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
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Documents.Document
  alias Fahrgastrechte.Repo
  alias Fahrgastrechte.Tickets.Suggestion

  @type domain_error ::
          :not_authenticated
          | :not_found
          | :invalid_document_kind
          | :invalid_state
          | :analysis_failed

  @doc "Analyzes one current ticket or invoice and replaces its previous suggestions."
  @spec analyze_document(Scope.t(), Ecto.UUID.t()) ::
          {:ok, %{document: Document.t(), suggestions: [Suggestion.t()]}}
          | {:error, Changeset.t() | domain_error()}
  def analyze_document(%Scope{} = scope, document_id) do
    Documents.with_document_path(scope, document_id, fn path, document ->
      analyze_path(document, path)
    end)
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

  @doc "Marks a scoped suggestion accepted, rejected or proposed without changing its value."
  @spec set_suggestion_state(Scope.t(), Ecto.UUID.t(), Suggestion.state() | String.t()) ::
          {:ok, Suggestion.t()} | {:error, Changeset.t() | domain_error()}
  def set_suggestion_state(
        %Scope{user: %User{id: user_id}},
        suggestion_id,
        requested_state
      )
      when is_binary(suggestion_id) do
    with {:ok, state} <- parse_state(requested_state),
         %Suggestion{} = suggestion <- scoped_suggestion(user_id, suggestion_id) do
      suggestion
      |> Suggestion.state_changeset(state)
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def set_suggestion_state(_scope, _suggestion_id, _state),
    do: {:error, :not_authenticated}

  defp analyze_path(%Document{kind: kind}, _path) when kind not in [:ticket, :invoice],
    do: {:error, :invalid_document_kind}

  defp analyze_path(%Document{encrypted: true} = document, _path) do
    persist_analysis(document, :manual_required, "encrypted", [])
  end

  defp analyze_path(%Document{} = document, path) do
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
      persist_analysis(document, :completed, nil, suggestions)
    else
      {:error, error} when error in [:no_text, :encrypted] ->
        persist_analysis(document, :manual_required, Atom.to_string(error), [])

      {:error, error}
      when error in [:invalid_pdf, :resource_limit, :timeout] ->
        persist_analysis(document, :failed, Atom.to_string(error), [])

      {:error, {:backend, _reason}} ->
        persist_analysis(document, :failed, "backend", [])
    end
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

  defp scoped_suggestion(user_id, suggestion_id) do
    case Ecto.UUID.cast(suggestion_id) do
      {:ok, parsed_id} ->
        Repo.one(
          from suggestion in Suggestion,
            join: document in assoc(suggestion, :document),
            where:
              suggestion.id == ^parsed_id and document.user_id == ^user_id and
                document.current == true and is_nil(document.deletion_pending_at),
            select: suggestion
        )

      :error ->
        nil
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
