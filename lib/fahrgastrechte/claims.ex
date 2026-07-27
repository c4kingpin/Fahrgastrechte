defmodule Fahrgastrechte.Claims do
  @moduledoc """
  User-scoped claim lifecycle and status history.

  Every public operation on a claim requires an authenticated `current_scope`.
  A bare claim ID never grants access. Mutations additionally require the
  caller's last seen `lock_version` to protect concurrent autosaves.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Claims.Claim
  alias Fahrgastrechte.Claims.StatusHistory
  alias Fahrgastrechte.Repo

  @claim_number_attempts 5
  @allowed_transitions %{
    draft: [:ready],
    ready: [:draft, :sent],
    sent: [:draft, :completed],
    completed: []
  }
  @status_reasons %{
    {:draft, :ready} => "output_generated",
    {:ready, :draft} => "correction_requested",
    {:ready, :sent} => "marked_sent",
    {:sent, :draft} => "correction_requested",
    {:sent, :completed} => "completed"
  }

  @type domain_error ::
          :not_authenticated
          | :not_found
          | :not_editable
          | :stale
          | :claim_number_unavailable
          | {:invalid_filter, atom()}
          | {:invalid_transition, Claim.status(), Claim.status() | term()}
          | %{type: :incomplete, errors: [map()]}

  @doc "Creates a draft for the current user and records its initial status."
  @spec create_claim(Scope.t(), map()) ::
          {:ok, Claim.t()} | {:error, Changeset.t() | domain_error()}
  def create_claim(scope, attrs \\ %{})

  def create_claim(%Scope{user: %User{id: user_id}}, attrs) when is_map(attrs) do
    do_create_claim(user_id, attrs, @claim_number_attempts)
  end

  def create_claim(_scope, _attrs), do: {:error, :not_authenticated}

  @doc "Loads one claim only when it belongs to the current user."
  @spec get_claim(Scope.t(), Ecto.UUID.t()) :: {:ok, Claim.t()} | {:error, domain_error()}
  def get_claim(%Scope{user: %User{id: user_id}}, claim_id) when is_binary(claim_id) do
    case Repo.one(
           from claim in Claim,
             where: claim.id == ^claim_id and claim.user_id == ^user_id
         ) do
      nil -> {:error, :not_found}
      claim -> {:ok, claim}
    end
  end

  def get_claim(%Scope{}, _claim_id), do: {:error, :not_found}
  def get_claim(_scope, _claim_id), do: {:error, :not_authenticated}

  @doc """
  Lists the current user's claims with optional status, date, route and claim
  number filters.

  Supported keys are `:status`, `:travel_date`, `:date_from`, `:date_to`,
  `:route` and `:claim_number`. Date values may be `Date` structs or ISO dates.
  """
  @spec list_claims(Scope.t(), map() | keyword()) ::
          {:ok, [Claim.t()]} | {:error, domain_error()}
  def list_claims(scope, filters \\ %{})

  def list_claims(%Scope{user: %User{id: user_id}}, filters)
      when is_map(filters) or is_list(filters) do
    query =
      from claim in Claim,
        where: claim.user_id == ^user_id,
        order_by: [desc: claim.inserted_at, desc: claim.id]

    with {:ok, query} <- apply_filters(query, filters) do
      {:ok, Repo.all(query)}
    end
  end

  def list_claims(%Scope{}, _filters), do: {:ok, []}
  def list_claims(_scope, _filters), do: {:error, :not_authenticated}

  @doc """
  Updates editable claim data using optimistic locking.

  Updating a `ready` claim automatically returns it to `draft`, clears
  `generated_at` and records the invalidation in the same transaction. Sent and
  completed claims must be explicitly reopened before editing.
  """
  @spec update_claim(Scope.t(), Ecto.UUID.t(), map(), pos_integer()) ::
          {:ok, Claim.t()} | {:error, Changeset.t() | domain_error()}
  def update_claim(%Scope{} = scope, claim_id, attrs, expected_lock_version)
      when is_map(attrs) do
    with {:ok, claim} <- get_claim(scope, claim_id),
         :ok <- verify_lock_version(claim, expected_lock_version),
         :ok <- editable_status(claim.status) do
      changeset = Claim.update_changeset(claim, attrs)

      cond do
        not changeset.valid? -> {:error, changeset}
        changeset.changes == %{} -> {:ok, claim}
        claim.status == :ready -> update_ready_claim(scope, claim, changeset)
        true -> persist_update(changeset)
      end
    end
  end

  def update_claim(_scope, _claim_id, _attrs, _expected_lock_version),
    do: {:error, :not_authenticated}

  @doc """
  Moves a claim through the allowed lifecycle with optimistic locking.

  `draft -> ready` also performs the C02 claim-field completeness check.
  Timestamps and the status history entry are written atomically.
  """
  @spec transition_claim(Scope.t(), Ecto.UUID.t(), Claim.status(), pos_integer()) ::
          {:ok, Claim.t()} | {:error, Changeset.t() | domain_error()}
  def transition_claim(%Scope{} = scope, claim_id, target_status, expected_lock_version)
      when target_status in [:draft, :ready, :sent, :completed] do
    with {:ok, claim} <- get_claim(scope, claim_id),
         :ok <- verify_lock_version(claim, expected_lock_version),
         :ok <- transition_allowed(claim.status, target_status),
         :ok <- complete_for_transition(claim, target_status) do
      persist_transition(scope, claim, target_status, transition_changes(target_status))
    end
  end

  def transition_claim(%Scope{} = scope, claim_id, target_status, expected_lock_version) do
    with {:ok, claim} <- get_claim(scope, claim_id),
         :ok <- verify_lock_version(claim, expected_lock_version) do
      {:error, {:invalid_transition, claim.status, target_status}}
    end
  end

  def transition_claim(_scope, _claim_id, _target_status, _expected_lock_version),
    do: {:error, :not_authenticated}

  @doc """
  Explicitly invalidates a current output after a dependent context changes.

  This is a no-op for drafts. Ready and sent claims return to draft and lose all
  output/send timestamps in the same status-history transaction.
  """
  @spec invalidate_output(Scope.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, Claim.t()} | {:error, Changeset.t() | domain_error()}
  def invalidate_output(%Scope{} = scope, claim_id, expected_lock_version) do
    with {:ok, claim} <- get_claim(scope, claim_id),
         :ok <- verify_lock_version(claim, expected_lock_version) do
      case claim.status do
        :draft ->
          {:ok, claim}

        status when status in [:ready, :sent] ->
          persist_transition(
            scope,
            claim,
            :draft,
            transition_changes(:draft),
            "dependent_data_changed"
          )

        :completed ->
          {:error, :not_editable}
      end
    end
  end

  def invalidate_output(_scope, _claim_id, _expected_lock_version),
    do: {:error, :not_authenticated}

  @doc "Returns structured C02 readiness errors for export callers."
  @spec export_readiness(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Claim.t()} | {:error, domain_error()}
  def export_readiness(%Scope{} = scope, claim_id) do
    with {:ok, claim} <- get_claim(scope, claim_id) do
      case completeness_errors(claim) do
        [] -> {:ok, claim}
        errors -> {:error, %{type: :incomplete, errors: errors}}
      end
    end
  end

  def export_readiness(_scope, _claim_id), do: {:error, :not_authenticated}

  @doc "Lists the complete, oldest-first status history for one scoped claim."
  @spec list_status_history(Scope.t(), Ecto.UUID.t()) ::
          {:ok, [StatusHistory.t()]} | {:error, domain_error()}
  def list_status_history(%Scope{} = scope, claim_id) do
    with {:ok, claim} <- get_claim(scope, claim_id) do
      history =
        Repo.all(
          from entry in StatusHistory,
            where: entry.claim_id == ^claim.id,
            order_by: [asc: entry.changed_at, asc: entry.inserted_at, asc: entry.id]
        )

      {:ok, history}
    end
  end

  def list_status_history(_scope, _claim_id), do: {:error, :not_authenticated}

  @doc """
  Deletes one scoped claim using optimistic locking.

  Database-owned dependent records must reference claims with
  `on_delete: :delete_all`. Contexts owning external resources must remove
  those resources before calling this final database deletion.
  """
  @spec delete_claim(Scope.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, Claim.t()} | {:error, Changeset.t() | domain_error()}
  def delete_claim(%Scope{} = scope, claim_id, expected_lock_version) do
    with {:ok, claim} <- get_claim(scope, claim_id),
         :ok <- verify_lock_version(claim, expected_lock_version) do
      claim
      |> Changeset.change()
      |> Claim.with_optimistic_lock()
      |> Repo.delete(stale_error_field: :lock_version)
      |> normalize_stale_result()
    end
  end

  def delete_claim(_scope, _claim_id, _expected_lock_version),
    do: {:error, :not_authenticated}

  defp do_create_claim(_user_id, _attrs, 0), do: {:error, :claim_number_unavailable}

  defp do_create_claim(user_id, attrs, attempts_left) do
    claim = %Claim{
      user_id: user_id,
      claim_number: generate_claim_number(),
      status: :draft,
      compensation_method: :bank_transfer
    }

    Multi.new()
    |> Multi.insert(:claim, Claim.create_changeset(claim, attrs))
    |> Multi.insert(:history, fn %{claim: inserted_claim} ->
      history_changeset(inserted_claim, user_id, nil, :draft, "created")
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{claim: inserted_claim}} ->
        {:ok, inserted_claim}

      {:error, :claim, %Changeset{} = changeset, _changes} ->
        if Keyword.has_key?(changeset.errors, :claim_number) do
          do_create_claim(user_id, attrs, attempts_left - 1)
        else
          {:error, changeset}
        end

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp generate_claim_number do
    year = Date.utc_today().year
    random = 5 |> :crypto.strong_rand_bytes() |> Base.encode32(padding: false)
    "FR-#{year}-#{random}"
  end

  defp persist_update(changeset) do
    changeset
    |> Claim.with_optimistic_lock()
    |> Repo.update(stale_error_field: :lock_version)
    |> normalize_stale_result()
  end

  defp update_ready_claim(%Scope{user: %User{id: user_id}}, _claim, changeset) do
    now = now()

    claim_changeset =
      changeset
      |> Changeset.put_change(:status, :draft)
      |> Changeset.put_change(:generated_at, nil)
      |> Claim.with_optimistic_lock()

    Multi.new()
    |> Multi.update(:claim, claim_changeset, stale_error_field: :lock_version)
    |> Multi.insert(:history, fn %{claim: updated_claim} ->
      history_changeset(updated_claim, user_id, :ready, :draft, "claim_updated", now)
    end)
    |> Repo.transaction()
    |> normalize_transaction_result()
  end

  defp persist_transition(
         %Scope{user: %User{id: user_id}},
         claim,
         target_status,
         changes,
         reason \\ nil
       ) do
    now = now()

    claim_changeset =
      claim
      |> Claim.transition_changeset(Map.put(changes, :status, target_status))
      |> Claim.with_optimistic_lock()

    Multi.new()
    |> Multi.update(:claim, claim_changeset, stale_error_field: :lock_version)
    |> Multi.insert(:history, fn %{claim: updated_claim} ->
      history_changeset(
        updated_claim,
        user_id,
        claim.status,
        target_status,
        reason || Map.fetch!(@status_reasons, {claim.status, target_status}),
        now
      )
    end)
    |> Repo.transaction()
    |> normalize_transaction_result()
  end

  defp history_changeset(claim, user_id, from_status, to_status, reason, changed_at \\ now()) do
    StatusHistory.changeset(
      %StatusHistory{claim_id: claim.id, actor_user_id: user_id},
      %{
        from_status: from_status,
        to_status: to_status,
        reason: reason,
        changed_at: changed_at
      }
    )
  end

  defp transition_changes(:ready),
    do: %{generated_at: now(), sent_at: nil, completed_at: nil}

  defp transition_changes(:sent), do: %{sent_at: now(), completed_at: nil}
  defp transition_changes(:completed), do: %{completed_at: now()}

  defp transition_changes(:draft),
    do: %{generated_at: nil, sent_at: nil, completed_at: nil}

  defp transition_allowed(from_status, target_status) do
    if target_status in Map.fetch!(@allowed_transitions, from_status) do
      :ok
    else
      {:error, {:invalid_transition, from_status, target_status}}
    end
  end

  defp complete_for_transition(claim, :ready) do
    case completeness_errors(claim) do
      [] -> :ok
      errors -> {:error, %{type: :incomplete, errors: errors}}
    end
  end

  defp complete_for_transition(_claim, _target_status), do: :ok

  defp completeness_errors(claim) do
    Claim.required_export_fields()
    |> Enum.filter(fn field ->
      value = Map.fetch!(claim, field)
      is_nil(value) or value == ""
    end)
    |> Enum.map(&%{source: :claim, field: &1, code: :required})
  end

  defp editable_status(status) when status in [:draft, :ready], do: :ok
  defp editable_status(_status), do: {:error, :not_editable}

  defp verify_lock_version(%Claim{lock_version: version}, version)
       when is_integer(version) and version > 0,
       do: :ok

  defp verify_lock_version(_claim, _expected_lock_version), do: {:error, :stale}

  defp normalize_transaction_result({:ok, %{claim: claim}}), do: {:ok, claim}

  defp normalize_transaction_result({:error, :claim, %Changeset{} = changeset, _changes}),
    do: normalize_stale_result({:error, changeset})

  defp normalize_transaction_result({:error, _operation, reason, _changes}), do: {:error, reason}

  defp normalize_stale_result({:error, %Changeset{} = changeset}) do
    if Keyword.has_key?(changeset.errors, :lock_version) do
      {:error, :stale}
    else
      {:error, changeset}
    end
  end

  defp normalize_stale_result(result), do: result

  defp apply_filters(query, filters) do
    with {:ok, query} <- filter_status(query, filter_value(filters, :status)),
         {:ok, query} <- filter_date(query, :travel_date, filter_value(filters, :travel_date)),
         {:ok, query} <- filter_date(query, :date_from, filter_value(filters, :date_from)),
         {:ok, query} <- filter_date(query, :date_to, filter_value(filters, :date_to)),
         {:ok, query} <- filter_text(query, :route, filter_value(filters, :route)),
         {:ok, query} <-
           filter_text(query, :claim_number, filter_value(filters, :claim_number)) do
      {:ok, query}
    end
  end

  defp filter_status(query, status) when status in [nil, ""], do: {:ok, query}

  defp filter_status(query, status) when is_binary(status) do
    case Enum.find(Claim.statuses(), &(Atom.to_string(&1) == status)) do
      nil -> {:error, {:invalid_filter, :status}}
      parsed_status -> filter_status(query, parsed_status)
    end
  end

  defp filter_status(query, status) when status in [:draft, :ready, :sent, :completed],
    do: {:ok, from(claim in query, where: claim.status == ^status)}

  defp filter_status(_query, _status), do: {:error, {:invalid_filter, :status}}

  defp filter_date(query, _field, date) when date in [nil, ""], do: {:ok, query}

  defp filter_date(query, field, %Date{} = date) do
    query =
      case field do
        :travel_date -> from claim in query, where: claim.travel_date == ^date
        :date_from -> from claim in query, where: claim.travel_date >= ^date
        :date_to -> from claim in query, where: claim.travel_date <= ^date
      end

    {:ok, query}
  end

  defp filter_date(query, field, date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed_date} -> filter_date(query, field, parsed_date)
      {:error, _reason} -> {:error, {:invalid_filter, field}}
    end
  end

  defp filter_date(_query, field, _date), do: {:error, {:invalid_filter, field}}

  defp filter_text(query, _field, value) when value in [nil, ""], do: {:ok, query}

  defp filter_text(query, field, value) when is_binary(value) do
    pattern = "%#{escape_like(String.trim(value))}%"

    query =
      case field do
        :route ->
          from claim in query,
            where: ilike(claim.origin, ^pattern) or ilike(claim.destination, ^pattern)

        :claim_number ->
          from claim in query, where: ilike(claim.claim_number, ^pattern)
      end

    {:ok, query}
  end

  defp filter_text(_query, field, _value), do: {:error, {:invalid_filter, field}}

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp filter_value(filters, key) when is_map(filters),
    do: Map.get(filters, key, Map.get(filters, Atom.to_string(key)))

  defp filter_value(filters, key) when is_list(filters), do: Keyword.get(filters, key)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
