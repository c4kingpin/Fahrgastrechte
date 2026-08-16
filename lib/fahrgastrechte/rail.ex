defmodule Fahrgastrechte.Rail do
  @moduledoc """
  Scoped railway searches, confirmed journeys and export-ready travel values.

  Provider results remain proposals until `confirm_journey/5` persists them.
  A refresh preserves every segment marked as manual. Mutations invalidate a
  current claim output in the same database transaction.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ecto.Changeset
  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Rail.ApiSnapshot
  alias Fahrgastrechte.Rail.BerlinTime
  alias Fahrgastrechte.Rail.Candidate
  alias Fahrgastrechte.Rail.Journey
  alias Fahrgastrechte.Rail.Segment
  alias Fahrgastrechte.Repo

  @segment_fields Segment.editable_fields()
  @segment_string_keys Map.new(@segment_fields, &{Atom.to_string(&1), &1})
  @override_fields [
    :first_disrupted_segment_id,
    :missed_connection_segment_id,
    :last_used_segment_id,
    :actual_destination_arrival
  ]
  @segment_override_fields [
    :first_disrupted_segment_id,
    :missed_connection_segment_id,
    :last_used_segment_id
  ]
  @override_string_keys Map.new(@override_fields, &{Atom.to_string(&1), &1})

  @type domain_error ::
          :not_authenticated
          | :not_found
          | :not_editable
          | :stale
          | :invalid_kind
          | :invalid_segments
          | :invalid_override
          | :history_unavailable
          | :rate_limited
          | :timeout
          | :unsupported
          | {:upstream, term()}
          | %{type: :incomplete, errors: [map()]}

  @doc "Searches stations through the configured provider and stores its raw snapshot."
  @spec search_stations(Scope.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Changeset.t() | domain_error()}
  def search_stations(scope, claim_id, query, options \\ [])

  def search_stations(%Scope{} = scope, claim_id, query, options)
      when is_binary(query) and is_list(options) do
    with {:ok, claim} <- Claims.get_claim(scope, claim_id),
         :ok <- validate_search_query(query) do
      provider_call(scope, claim, :search_stations, [String.trim(query)], options)
    end
  end

  def search_stations(_scope, _claim_id, _query, _options),
    do: {:error, :not_authenticated}

  @doc "Searches direct connection candidates without confirming any result."
  @spec search_connections(Scope.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, [Candidate.t()]} | {:error, Changeset.t() | domain_error()}
  def search_connections(scope, claim_id, query, options \\ [])

  def search_connections(%Scope{} = scope, claim_id, query, options)
      when is_map(query) and is_list(options) do
    with {:ok, claim} <- Claims.get_claim(scope, claim_id),
         {:ok, journeys} <- provider_call(scope, claim, :search_connections, [query], options) do
      {:ok, Enum.map(journeys, &candidate_from_journey/1)}
    end
  end

  def search_connections(_scope, _claim_id, _query, _options),
    do: {:error, :not_authenticated}

  @doc "Loads departure candidates for the provider-neutral reconstruction fallback."
  @spec departures(Scope.t(), Ecto.UUID.t(), map(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, [Candidate.t()]} | {:error, Changeset.t() | domain_error()}
  def departures(scope, claim_id, station_id, from, until, options \\ [])

  def departures(%Scope{} = scope, claim_id, station_id, from, until, options)
      when is_map(station_id) and is_struct(from, DateTime) and is_struct(until, DateTime) and
             is_list(options) do
    with {:ok, claim} <- Claims.get_claim(scope, claim_id),
         :ok <- validate_window(from, until),
         {:ok, journeys} <-
           provider_call(scope, claim, :departures, [station_id, from, until], options) do
      {:ok, Enum.map(journeys, &candidate_from_journey/1)}
    end
  end

  def departures(_scope, _claim_id, _station_id, _from, _until, _options),
    do: {:error, :not_authenticated}

  @doc "Loads a provider journey without confirming or mutating travel data."
  def load_provider_journey(scope, claim_id, journey_id, options \\ [])

  def load_provider_journey(%Scope{} = scope, claim_id, journey_id, options)
      when is_map(journey_id) and is_list(options) do
    with {:ok, claim} <- Claims.get_claim(scope, claim_id) do
      provider_call(scope, claim, :journey, [journey_id], options)
    end
  end

  def load_provider_journey(_scope, _claim_id, _journey_id, _options),
    do: {:error, :not_authenticated}

  @doc """
  Persists a user-confirmed planned or actual journey and its ordered segments.

  Calling this again replaces the previous journey of the same kind. Segment
  positions are assigned from list order rather than trusted caller input.
  """
  @spec confirm_journey(Scope.t(), Ecto.UUID.t(), Journey.kind(), [map()], pos_integer()) ::
          {:ok, %{journey: Journey.t(), claim: Claims.Claim.t()}}
          | {:error, Changeset.t() | domain_error()}
  def confirm_journey(
        %Scope{user: %User{id: user_id}} = scope,
        claim_id,
        kind,
        segment_attrs,
        expected_claim_lock_version
      )
      when is_list(segment_attrs) do
    with {:ok, parsed_kind} <- parse_kind(kind),
         :ok <- validate_segments_input(segment_attrs) do
      Repo.transaction(fn ->
        with {:ok, claim} <-
               Claims.invalidate_output(scope, claim_id, expected_claim_lock_version),
             :ok <- delete_existing_journey(user_id, claim_id, parsed_kind),
             {:ok, journey} <- insert_journey(user_id, claim_id, parsed_kind),
             {:ok, segments} <- insert_segments(journey, segment_attrs) do
          %{journey: %{journey | segments: segments}, claim: claim}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transaction()
    end
  end

  def confirm_journey(_scope, _claim_id, _kind, _segment_attrs, _expected_lock_version),
    do: {:error, :not_authenticated}

  @doc """
  Refreshes a confirmed journey while preserving complete manually edited segments.

  Provider data may replace automatic segments at the same position. A segment
  with `manual: true` is copied unchanged into the replacement journey.
  """
  def refresh_journey(
        %Scope{} = scope,
        claim_id,
        kind,
        segment_attrs,
        expected_claim_lock_version
      )
      when is_list(segment_attrs) do
    with {:ok, parsed_kind} <- parse_kind(kind),
         :ok <- validate_segments_input(segment_attrs),
         {:ok, current} <- get_journey(scope, claim_id, parsed_kind) do
      manual_positions =
        current.segments
        |> Enum.filter(& &1.manual)
        |> MapSet.new(& &1.position)

      automatic_attrs =
        segment_attrs
        |> Enum.with_index(1)
        |> Enum.reject(fn {_attrs, position} -> MapSet.member?(manual_positions, position) end)

      Repo.transaction(fn ->
        with {:ok, claim} <-
               Claims.invalidate_output(scope, claim_id, expected_claim_lock_version),
             {:ok, current} <- clear_replaced_segment_overrides(current),
             :ok <- delete_automatic_segments(current.id),
             {:ok, _segments} <- insert_segments_at_positions(current, automatic_attrs),
             {:ok, refreshed} <-
               current |> Changeset.change(confirmed_at: now()) |> Repo.update() do
          %{
            journey: Repo.preload(refreshed, :segments, force: true),
            claim: claim
          }
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transaction()
    end
  end

  def refresh_journey(_scope, _claim_id, _kind, _segment_attrs, _expected_lock_version),
    do: {:error, :not_authenticated}

  @doc "Loads one confirmed journey only for the claim owner."
  @spec get_journey(Scope.t(), Ecto.UUID.t(), Journey.kind()) ::
          {:ok, Journey.t()} | {:error, domain_error()}
  def get_journey(%Scope{user: %User{id: user_id}} = scope, claim_id, kind) do
    with {:ok, parsed_kind} <- parse_kind(kind),
         {:ok, _claim} <- Claims.get_claim(scope, claim_id),
         %Journey{} = journey <-
           Repo.one(
             from journey in Journey,
               where:
                 journey.user_id == ^user_id and journey.claim_id == ^claim_id and
                   journey.kind == ^parsed_kind,
               preload: [:segments]
           ) do
      {:ok, journey}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_journey(_scope, _claim_id, _kind), do: {:error, :not_authenticated}

  @doc "Marks edits to one scoped segment as manual and invalidates current output."
  def update_segment(%Scope{} = scope, segment_id, attrs, expected_claim_lock_version)
      when is_binary(segment_id) and is_map(attrs) do
    with %Segment{} = segment <- scoped_segment(scope, segment_id) do
      Repo.transaction(fn ->
        with {:ok, claim} <-
               Claims.invalidate_output(
                 scope,
                 segment.journey.claim_id,
                 expected_claim_lock_version
               ),
             {:ok, updated_segment} <-
               segment
               |> Segment.manual_changeset(normalize_segment_attrs(attrs), now())
               |> Repo.update() do
          %{segment: updated_segment, claim: claim}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transaction()
    else
      nil -> {:error, :not_found}
    end
  end

  def update_segment(_scope, _segment_id, _attrs, _expected_claim_lock_version),
    do: {:error, :not_authenticated}

  @doc "Stores optional manual overrides for the derived actual-journey values."
  def set_summary_overrides(%Scope{} = scope, claim_id, attrs, expected_claim_lock_version)
      when is_map(attrs) do
    with {:ok, journey} <- get_journey(scope, claim_id, :actual),
         normalized <- normalize_override_attrs(attrs),
         :ok <- validate_override_segments(journey, normalized) do
      Repo.transaction(fn ->
        with {:ok, claim} <-
               Claims.invalidate_output(scope, claim_id, expected_claim_lock_version),
             {:ok, updated_journey} <-
               journey |> Journey.override_changeset(normalized) |> Repo.update() do
          %{journey: Repo.preload(updated_journey, :segments, force: true), claim: claim}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transaction()
    end
  end

  def set_summary_overrides(_scope, _claim_id, _attrs, _expected_claim_lock_version),
    do: {:error, :not_authenticated}

  @doc "Returns derived, overridable travel facts for UI and export callers."
  def travel_summary(%Scope{} = scope, claim_id) do
    with {:ok, planned} <- get_journey(scope, claim_id, :planned),
         {:ok, actual} <- get_journey(scope, claim_id, :actual) do
      first_disrupted =
        overridden_or_derived(
          actual,
          actual.first_disrupted_segment_id,
          &first_disrupted_segment/1
        )

      missed_connection =
        overridden_or_derived(
          actual,
          actual.missed_connection_segment_id,
          &missed_connection_segment/1
        )

      last_used =
        overridden_or_derived(actual, actual.last_used_segment_id, &last_used_segment/1)

      actual_arrival =
        actual.actual_destination_arrival || effective_arrival(last_used)

      {:ok,
       %{
         planned: planned,
         actual: actual,
         first_disrupted_segment: first_disrupted,
         missed_connection_segment: missed_connection,
         last_used_segment: last_used,
         actual_destination_arrival: actual_arrival
       }}
    else
      {:error, :not_found} ->
        {:error,
         %{
           type: :incomplete,
           errors: [%{source: :rail, field: :journeys, code: :required}]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def travel_summary(_scope, _claim_id), do: {:error, :not_authenticated}

  @doc "Returns outcome-aware C05 form values in Europe/Berlin civil time."
  def form_values(%Scope{} = scope, claim_id) do
    with {:ok, claim} <- Claims.get_claim(scope, claim_id) do
      planned = optional_export_journey(scope, claim_id, :planned)
      actual = optional_export_journey(scope, claim_id, :actual)
      summary = export_summary(planned, actual)

      with :ok <- validate_export_summary(claim, summary) do
        {:ok,
         %{
           scheduled_departure: local_time(summary.scheduled_departure),
           scheduled_arrival: local_time(summary.scheduled_arrival),
           first_disrupted_train: export_segment(summary.first_disrupted_segment),
           missed_connection: export_segment(summary.missed_connection_segment),
           last_used_train: export_segment(summary.last_used_segment),
           actual_destination_arrival:
             form_arrival(claim.journey_outcome, summary.actual_destination_arrival)
         }}
      end
    end
  end

  def form_values(_scope, _claim_id), do: {:error, :not_authenticated}

  @doc "Lists immutable API snapshots only for the scoped claim owner."
  def list_api_snapshots(%Scope{user: %User{id: user_id}} = scope, claim_id) do
    with {:ok, _claim} <- Claims.get_claim(scope, claim_id) do
      {:ok,
       Repo.all(
         from snapshot in ApiSnapshot,
           where: snapshot.user_id == ^user_id and snapshot.claim_id == ^claim_id,
           order_by: [asc: snapshot.fetched_at, asc: snapshot.inserted_at],
           select:
             struct(snapshot, [
               :id,
               :provider,
               :operation,
               :content_type,
               :sha256,
               :fetched_at,
               :metadata,
               :claim_id,
               :user_id,
               :inserted_at
             ])
       )}
    end
  end

  def list_api_snapshots(_scope, _claim_id), do: {:error, :not_authenticated}

  defp provider_call(scope, claim, operation, args, options) do
    provider = Keyword.get(options, :provider, rail_config(:provider))
    provider_options = Keyword.delete(options, :provider)
    do_provider_call(scope, claim, provider, operation, args, provider_options)
  end

  defp do_provider_call(scope, claim, provider, operation, args, provider_options) do
    result = apply(provider, operation, args ++ [provider_options])

    case result do
      {:ok, value} ->
        {:ok, value}

      {:ok, value, snapshot} ->
        snapshots = if is_list(snapshot), do: snapshot, else: [snapshot]

        Enum.reduce_while(snapshots, {:ok, value}, fn item, {:ok, value} ->
          case persist_snapshot(scope, claim, provider, operation, item) do
            {:ok, _snapshot} -> {:cont, {:ok, value}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        log_provider_failure(provider, operation, claim, reason)
        {:error, reason}

      other ->
        reason = {:upstream, {:invalid_provider_response, other}}
        log_provider_failure(provider, operation, claim, reason)
        {:error, reason}
    end
  rescue
    error ->
      reason = {:upstream, :provider_exception}

      Logger.warning(
        "Rail provider call raised: #{Exception.format(:error, error, __STACKTRACE__)}",
        provider: provider,
        operation: operation,
        claim_id: claim.id
      )

      {:error, reason}
  catch
    :exit, {:timeout, _details} ->
      log_provider_failure(provider, operation, claim, :timeout)
      {:error, :timeout}

    :exit, exit_reason ->
      reason = {:upstream, :provider_exit}
      log_provider_failure(provider, operation, claim, reason, exit_reason)
      {:error, reason}
  end

  defp log_provider_failure(provider, operation, claim, reason, exit_reason \\ nil) do
    Logger.warning(
      "Rail provider call failed: #{inspect(reason)}",
      provider: provider,
      operation: operation,
      claim_id: claim.id,
      exit_reason: exit_reason && inspect(exit_reason)
    )
  end

  defp persist_snapshot(
         %Scope{user: %User{id: user_id}},
         claim,
         provider,
         operation,
         snapshot
       ) do
    payload = Map.fetch!(snapshot, :payload)

    if byte_size(payload) > rail_config(:max_snapshot_bytes) do
      {:error, {:upstream, :response_too_large}}
    else
      do_persist_snapshot(user_id, claim, provider, operation, snapshot, payload)
    end
  end

  defp do_persist_snapshot(user_id, claim, provider, operation, snapshot, payload) do
    attrs = %{
      provider: inspect(provider),
      operation: Atom.to_string(operation),
      content_type: Map.fetch!(snapshot, :content_type),
      payload: payload,
      sha256: :crypto.hash(:sha256, payload),
      fetched_at: Map.fetch!(snapshot, :fetched_at),
      metadata: Map.get(snapshot, :metadata, %{})
    }

    %ApiSnapshot{claim_id: claim.id, user_id: user_id}
    |> ApiSnapshot.create_changeset(attrs)
    |> Repo.insert()
  end

  defp insert_journey(user_id, claim_id, kind) do
    %Journey{user_id: user_id, claim_id: claim_id}
    |> Journey.create_changeset(%{kind: kind, confirmed_at: now()})
    |> Repo.insert()
  end

  defp insert_segments(journey, segment_attrs) do
    segment_attrs
    |> Enum.with_index(1)
    |> then(&insert_segments_at_positions(journey, &1))
  end

  defp insert_segments_at_positions(journey, positioned_attrs) do
    positioned_attrs
    |> Enum.reduce_while({:ok, []}, fn {attrs, position}, {:ok, inserted} ->
      normalized =
        attrs
        |> normalize_segment_attrs()
        |> Map.put(:position, position)

      case %Segment{journey_id: journey.id}
           |> Segment.create_changeset(normalized)
           |> Repo.insert() do
        {:ok, segment} -> {:cont, {:ok, [segment | inserted]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_replaced_segment_overrides(journey) do
    automatic_ids =
      journey.segments
      |> Enum.reject(& &1.manual)
      |> MapSet.new(& &1.id)

    attrs =
      Enum.reduce(@segment_override_fields, %{}, fn field, overrides ->
        value = Map.fetch!(journey, field)

        if MapSet.member?(automatic_ids, value),
          do: Map.put(overrides, field, nil),
          else: overrides
      end)

    case attrs do
      attrs when attrs == %{} ->
        {:ok, journey}

      attrs ->
        journey |> Journey.override_changeset(attrs) |> Repo.update()
    end
  end

  defp delete_automatic_segments(journey_id) do
    from(segment in Segment,
      where: segment.journey_id == ^journey_id and segment.manual == false
    )
    |> Repo.delete_all()

    :ok
  end

  defp delete_existing_journey(user_id, claim_id, kind) do
    from(journey in Journey,
      where:
        journey.user_id == ^user_id and journey.claim_id == ^claim_id and
          journey.kind == ^kind
    )
    |> Repo.delete_all()

    :ok
  end

  defp scoped_segment(%Scope{user: %User{id: user_id}}, segment_id) do
    with {:ok, id} <- Ecto.UUID.cast(segment_id) do
      Repo.one(
        from segment in Segment,
          join: journey in assoc(segment, :journey),
          where: segment.id == ^id and journey.user_id == ^user_id,
          preload: [journey: journey]
      )
    else
      :error -> nil
    end
  end

  defp scoped_segment(_scope, _segment_id), do: nil

  defp candidate_from_journey(%{segments: segments} = journey) when is_list(segments) do
    %Candidate{
      id: Map.fetch!(journey, :id),
      segments: segments,
      source: provider_name(journey.id),
      fetched_at: Map.fetch!(journey, :fetched_at)
    }
  end

  defp candidate_from_journey(journey) do
    events = Map.get(journey, :events, [])
    first = List.first(events)
    last = List.last(events)

    segments =
      if first && last do
        [
          %{
            origin_name: first.station.name,
            destination_name: last.station.name,
            origin_external_id: external_id_for_storage(first.station.id),
            destination_external_id: external_id_for_storage(last.station.id),
            train_category: journey.category,
            train_number: journey.number,
            scheduled_departure: first[:scheduled_at],
            scheduled_arrival: last[:scheduled_at],
            estimated_departure: first[:estimated_at],
            estimated_arrival: last[:estimated_at],
            actual_departure: first[:actual_at],
            actual_arrival: last[:actual_at],
            cancelled: Enum.any?(events, &Map.get(&1, :cancelled, false)),
            external_id: external_id_for_storage(journey.id),
            source: provider_name(journey.id),
            source_metadata: Map.get(journey, :source_metadata, %{}),
            fetched_at: journey.fetched_at,
            manual: false
          }
        ]
      else
        []
      end

    %Candidate{
      id: journey.id,
      segments: segments,
      source: provider_name(journey.id),
      fetched_at: journey.fetched_at
    }
  end

  defp provider_name(%{provider: provider}) when is_atom(provider), do: inspect(provider)
  defp provider_name(%{"provider" => provider}) when is_binary(provider), do: provider
  defp provider_name(_external_id), do: "unknown"

  defp external_id_for_storage(nil), do: nil

  defp external_id_for_storage(%{provider: provider, value: value}) do
    %{"provider" => inspect(provider), "value" => value}
  end

  defp external_id_for_storage(external_id) when is_map(external_id), do: external_id

  defp normalize_segment_attrs(attrs) do
    normalized =
      Enum.reduce(attrs, %{}, fn
        {key, value}, acc when is_atom(key) ->
          if key in @segment_fields, do: Map.put(acc, key, value), else: acc

        {key, value}, acc when is_binary(key) ->
          case Map.get(@segment_string_keys, key) do
            nil -> acc
            field -> Map.put(acc, field, value)
          end

        _entry, acc ->
          acc
      end)

    manual? =
      Map.get_lazy(normalized, :manual, fn ->
        Map.get(normalized, :source, "manual") == "manual"
      end)

    normalized
    |> Map.put_new(:manual, manual?)
    |> Map.put_new(:source, "manual")
    |> Map.put_new(:source_metadata, %{})
    |> Map.put_new(:fetched_at, now())
  end

  defp normalize_override_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        if key in @override_fields, do: Map.put(acc, key, value), else: acc

      {key, value}, acc when is_binary(key) ->
        case Map.get(@override_string_keys, key) do
          nil -> acc
          field -> Map.put(acc, field, value)
        end

      _entry, acc ->
        acc
    end)
  end

  defp validate_override_segments(journey, attrs) do
    segment_ids = MapSet.new(journey.segments, & &1.id)

    valid? =
      Enum.all?(
        [:first_disrupted_segment_id, :missed_connection_segment_id, :last_used_segment_id],
        fn field ->
          case Map.get(attrs, field) do
            nil -> true
            id -> MapSet.member?(segment_ids, id)
          end
        end
      )

    if valid?, do: :ok, else: {:error, :invalid_override}
  end

  defp first_disrupted_segment(segments) do
    Enum.find(segments, fn segment ->
      segment.cancelled || delayed?(segment)
    end)
  end

  defp delayed?(%Segment{scheduled_arrival: nil}), do: false

  defp delayed?(segment) do
    case effective_arrival(segment) do
      nil -> false
      arrival -> DateTime.compare(arrival, segment.scheduled_arrival) == :gt
    end
  end

  defp missed_connection_segment(segments) do
    segments
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn [previous, next] ->
      arrival = effective_arrival(previous)

      if arrival && next.scheduled_departure &&
           DateTime.compare(arrival, next.scheduled_departure) == :gt do
        next
      end
    end)
  end

  defp last_used_segment(segments) do
    segments
    |> Enum.reject(& &1.cancelled)
    |> List.last()
  end

  defp effective_arrival(nil), do: nil

  defp effective_arrival(segment) do
    segment.actual_arrival || segment.estimated_arrival || segment.scheduled_arrival
  end

  defp overridden_or_derived(journey, nil, derive), do: derive.(journey.segments)

  defp overridden_or_derived(journey, segment_id, _derive) do
    Enum.find(journey.segments, &(&1.id == segment_id))
  end

  defp export_segment(nil), do: nil

  defp export_segment(segment) do
    %{
      id: segment.id,
      origin: segment.origin_name,
      destination: segment.destination_name,
      train_category: segment.train_category,
      train_number: segment.train_number,
      scheduled_departure: segment.scheduled_departure,
      scheduled_arrival: segment.scheduled_arrival,
      actual_departure: segment.actual_departure,
      actual_arrival: segment.actual_arrival,
      cancelled: segment.cancelled,
      source: segment.source,
      fetched_at: segment.fetched_at,
      manual: segment.manual
    }
  end

  defp optional_export_journey(scope, claim_id, kind) do
    case get_journey(scope, claim_id, kind) do
      {:ok, journey} -> journey
      {:error, :not_found} -> nil
    end
  end

  defp export_summary(planned, actual) do
    planned_segments = if planned, do: planned.segments, else: []
    actual_segments = if actual, do: actual.segments, else: []
    planned_first = List.first(planned_segments)
    planned_last = List.last(planned_segments)

    first_disrupted =
      if actual do
        overridden_or_derived(
          actual,
          actual.first_disrupted_segment_id,
          &first_disrupted_segment/1
        )
      end

    missed_connection =
      if actual do
        overridden_or_derived(
          actual,
          actual.missed_connection_segment_id,
          &missed_connection_segment/1
        )
      end

    last_used =
      if actual do
        overridden_or_derived(actual, actual.last_used_segment_id, &last_used_segment/1)
      end

    %{
      planned_segments: planned_segments,
      actual_segments: actual_segments,
      scheduled_departure: planned_first && planned_first.scheduled_departure,
      scheduled_arrival: planned_last && planned_last.scheduled_arrival,
      first_disrupted_segment: first_disrupted,
      missed_connection_segment: missed_connection,
      last_used_segment: last_used,
      actual_destination_arrival:
        if(actual, do: actual.actual_destination_arrival || effective_arrival(last_used))
    }
  end

  defp validate_export_summary(claim, summary) do
    errors =
      []
      |> required_error(summary.planned_segments, :planned_segments)
      |> required_error(summary.scheduled_departure, :scheduled_departure)
      |> required_error(summary.scheduled_arrival, :scheduled_arrival)
      |> require_actual_journey(claim.journey_outcome, summary)
      |> require_missed_connection(claim.disruption_cause, summary)

    if errors == [], do: :ok, else: {:error, %{type: :incomplete, errors: Enum.reverse(errors)}}
  end

  defp require_actual_journey(errors, outcome, summary)
       when outcome in [:delayed_arrival, :aborted, :continued_with_other_transport] do
    errors =
      errors
      |> required_error(summary.actual_segments, :actual_segments)
      |> required_error(summary.first_disrupted_segment, :first_disrupted_segment)

    case outcome do
      :delayed_arrival ->
        errors
        |> required_error(summary.last_used_segment, :last_used_segment)
        |> required_error(summary.actual_destination_arrival, :actual_destination_arrival)

      :aborted ->
        required_error(errors, summary.last_used_segment, :last_used_segment)

      :continued_with_other_transport ->
        required_error(
          errors,
          summary.actual_destination_arrival,
          :actual_destination_arrival
        )
    end
  end

  defp require_actual_journey(errors, _outcome, _summary), do: errors

  defp require_missed_connection(errors, :missed_connection, summary) do
    required_error(errors, summary.missed_connection_segment, :missed_connection_segment)
  end

  defp require_missed_connection(errors, _cause, _summary), do: errors

  defp required_error(errors, value, field) when value in [nil, []] do
    [%{source: :rail, field: field, code: :required} | errors]
  end

  defp required_error(errors, _value, _field), do: errors

  defp form_arrival(outcome, arrival)
       when outcome in [:delayed_arrival, :continued_with_other_transport],
       do: local_time(arrival)

  defp form_arrival(_outcome, _arrival), do: nil

  defp local_time(nil), do: nil
  defp local_time(%DateTime{} = datetime), do: BerlinTime.to_local(datetime)

  defp validate_search_query(query) do
    if String.trim(query) == "", do: {:error, {:upstream, :invalid_query}}, else: :ok
  end

  defp validate_window(from, until) do
    if DateTime.compare(from, until) == :lt,
      do: :ok,
      else: {:error, {:upstream, :invalid_time_window}}
  end

  defp validate_segments_input([]), do: {:error, :invalid_segments}

  defp validate_segments_input(segments) when is_list(segments) do
    if Enum.all?(segments, &is_map/1), do: :ok, else: {:error, :invalid_segments}
  end

  defp parse_kind(kind) when kind in [:planned, :actual], do: {:ok, kind}

  defp parse_kind(kind) when is_binary(kind) do
    case Enum.find(Journey.kinds(), &(Atom.to_string(&1) == kind)) do
      nil -> {:error, :invalid_kind}
      parsed -> {:ok, parsed}
    end
  end

  defp parse_kind(_kind), do: {:error, :invalid_kind}

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp rail_config(key) do
    :fahrgastrechte
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(key)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
