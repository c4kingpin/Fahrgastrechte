defmodule Fahrgastrechte.ClaimWorkspace do
  @moduledoc """
  Application boundary for the scoped claim workspace.

  The module composes public context APIs into one checked read model and owns
  cross-context actions that must succeed or roll back as a unit. It does not
  expose unscoped record access.
  """

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Claims.Claim
  alias Fahrgastrechte.ClaimWorkspace.ReadModel
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Documents.Document
  alias Fahrgastrechte.Exports
  alias Fahrgastrechte.GermanDateTime
  alias Fahrgastrechte.Rail
  alias Fahrgastrechte.Rail.BerlinTime
  alias Fahrgastrechte.Repo
  alias Fahrgastrechte.Tickets

  @upload_kinds [:ticket, :invoice]

  @doc "Returns the document kinds accepted by the workspace."
  def upload_kinds, do: @upload_kinds

  @doc "Loads all scoped data needed to render one claim workspace."
  @spec load(Scope.t(), Ecto.UUID.t()) :: {:ok, ReadModel.t()} | {:error, term()}
  def load(%Scope{} = scope, claim_id) when is_binary(claim_id) do
    with {:ok, claim} <- Claims.get_claim(scope, claim_id),
         {:ok, claim_changeset} <- Claims.change_claim(scope, claim.id),
         {:ok, documents} <- Documents.list_documents(scope, claim.id),
         {:ok, suggestions} <- Tickets.list_claim_suggestions(scope, claim.id),
         {:ok, exports} <- Exports.list_exports(scope, claim.id),
         {:ok, api_sources} <- Rail.list_api_snapshots(scope, claim.id),
         {:ok, status_history} <- Claims.list_status_history(scope, claim.id),
         {:ok, planned_journey} <- optional_journey(scope, claim.id, :planned),
         {:ok, actual_journey} <- optional_journey(scope, claim.id, :actual) do
      {:ok,
       build_read_model(
         scope,
         claim,
         claim_changeset,
         documents,
         suggestions,
         exports,
         api_sources,
         status_history,
         planned_journey,
         actual_journey
       )}
    end
  end

  def load(_scope, _claim_id), do: {:error, :not_authenticated}

  @doc """
  Translates step completeness into user-facing open questions.

  Ordered by where each question appears in the flow; empty once every
  question the concrete case actually needs has been answered.
  """
  @spec required_inputs(ReadModel.t()) :: [%{id: atom(), step: atom(), label: String.t()}]
  def required_inputs(%ReadModel{} = workspace) do
    claim = workspace.claim

    [
      required_input(
        :documents,
        :documents,
        "Ticket und Rechnung hochladen",
        !workspace.documents_complete?
      ),
      required_input(
        :facts,
        :suggestions,
        "Erkannte Angaben bestätigen",
        !workspace.suggestions_complete?
      ),
      required_input(
        :case_data,
        :claim,
        "Angaben zu deiner Reise vervollständigen",
        !workspace.claim_complete?
      ),
      required_input(
        :journey_direction,
        :claim,
        "Hin- oder Rückfahrt bestätigen",
        ambiguous_direction?(workspace)
      ),
      required_input(
        :planned_journey,
        :planned,
        "Geplante Verbindung ergänzen",
        !workspace.planned_complete?
      ),
      required_input(
        :actual_arrival,
        :actual,
        actual_arrival_label(claim),
        !workspace.actual_complete?
      ),
      required_input(
        :payout,
        :review,
        "IBAN für die Auszahlung ergänzen",
        !workspace.profile_complete?
      )
    ]
    |> Enum.filter(& &1)
  end

  defp required_input(_id, _step, _label, false), do: nil
  defp required_input(id, step, label, true), do: %{id: id, step: step, label: label}

  defp actual_arrival_label(%Claim{disruption_cause: :cancellation}),
    do: "Ersatzverbindung ergänzen"

  defp actual_arrival_label(%Claim{disruption_cause: :missed_connection}),
    do: "Anschlussverbindung ergänzen"

  defp actual_arrival_label(_claim), do: "Tatsächliche Ankunft ergänzen"

  defp ambiguous_direction?(workspace) do
    Enum.any?(Map.values(workspace.suggestions_by_id), &(&1.field == :valid_until))
  end

  @doc """
  Flags ticket and invoice as possibly unrelated documents.

  Returns `nil` unless both carry a recognized order number and those order
  numbers disagree, so an accidental cross-claim upload can be caught early.
  """
  @spec order_number_mismatch(ReadModel.t()) :: %{ticket: String.t(), invoice: String.t()} | nil
  def order_number_mismatch(%ReadModel{} = workspace) do
    order_numbers =
      workspace.suggestions_by_id
      |> Map.values()
      |> Enum.filter(&(&1.field == :order_number))
      |> Enum.reduce(%{}, fn suggestion, acc ->
        case {Map.get(workspace.documents_by_id, suggestion.document_id), suggestion.value} do
          {%{kind: kind}, %{"text" => text}} when kind in [:ticket, :invoice] ->
            Map.put(acc, kind, text)

          _other ->
            acc
        end
      end)

    case order_numbers do
      %{ticket: ticket, invoice: invoice} when ticket != invoice ->
        %{ticket: ticket, invoice: invoice}

      _match_or_incomplete ->
        nil
    end
  end

  @doc "Applies claim values and accepts suggestions in one transaction."
  @spec accept_suggestions(Scope.t(), Claim.t(), [map()]) ::
          {:ok, %{claim: Claim.t(), suggestions: [struct()]}} | {:error, term()}
  def accept_suggestions(%Scope{} = scope, %Claim{} = claim, suggestions)
      when is_list(suggestions) and suggestions != [] do
    suggestion_ids = Enum.map(suggestions, & &1.id)
    attrs = claim_attrs_for_suggestions(suggestions)

    Repo.transaction(fn ->
      with {:ok, updated_claim} <- maybe_update_claim(scope, claim, attrs),
           {:ok, updated_suggestions} <-
             Tickets.set_suggestion_states(
               scope,
               claim.id,
               suggestion_ids,
               :accepted,
               updated_claim.lock_version
             ),
           {:ok, final_claim} <- Claims.get_claim(scope, claim.id) do
        %{claim: final_claim, suggestions: updated_suggestions}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction()
  end

  def accept_suggestions(_scope, _claim, _suggestions), do: {:error, :not_found}

  @doc "Rejects a checked set of suggestions for one claim."
  @spec reject_suggestions(Scope.t(), Claim.t(), [map()]) ::
          {:ok, %{claim: Claim.t(), suggestions: [struct()]}} | {:error, term()}
  def reject_suggestions(%Scope{} = scope, %Claim{} = claim, suggestions)
      when is_list(suggestions) and suggestions != [] do
    Repo.transaction(fn ->
      with {:ok, updated_suggestions} <-
             Tickets.set_suggestion_states(
               scope,
               claim.id,
               Enum.map(suggestions, & &1.id),
               :rejected,
               claim.lock_version
             ),
           {:ok, final_claim} <- Claims.get_claim(scope, claim.id) do
        %{claim: final_claim, suggestions: updated_suggestions}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction()
  end

  def reject_suggestions(_scope, _claim, _suggestions), do: {:error, :not_found}

  @doc """
  Accepts one suggestion chosen among duplicate values, rejecting the rest.

  Used when a field (e.g. the fare) was extracted from both the ticket and
  the invoice: the user picks the correct value and its duplicate siblings
  are rejected in the same transaction so they stop showing as open questions.
  """
  @spec accept_suggestion_choice(Scope.t(), Claim.t(), struct(), [struct()]) ::
          {:ok, %{claim: Claim.t(), suggestions: [struct()]}} | {:error, term()}
  def accept_suggestion_choice(%Scope{} = scope, %Claim{} = claim, suggestion, siblings)
      when is_list(siblings) do
    attrs = claim_attrs_for_suggestions([suggestion])

    Repo.transaction(fn ->
      with {:ok, updated_claim} <- maybe_update_claim(scope, claim, attrs),
           {:ok, accepted} <-
             Tickets.set_suggestion_states(
               scope,
               claim.id,
               [suggestion.id],
               :accepted,
               updated_claim.lock_version
             ),
           {:ok, rejected} <- reject_siblings(scope, claim.id, Enum.map(siblings, & &1.id)),
           {:ok, final_claim} <- Claims.get_claim(scope, claim.id) do
        %{claim: final_claim, suggestions: accepted ++ rejected}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction()
  end

  def accept_suggestion_choice(_scope, _claim, _suggestion, _siblings), do: {:error, :not_found}

  defp reject_siblings(_scope, _claim_id, []), do: {:ok, []}

  defp reject_siblings(scope, claim_id, sibling_ids) do
    with {:ok, current_claim} <- Claims.get_claim(scope, claim_id) do
      Tickets.set_suggestion_states(
        scope,
        claim_id,
        sibling_ids,
        :rejected,
        current_claim.lock_version
      )
    end
  end

  @doc "Confirms one provider candidate as planned and actual journey atomically."
  @spec confirm_connection(Scope.t(), Claim.t(), map()) ::
          {:ok, %{claim: Claim.t(), planned_journey: struct(), actual_journey: struct()}}
          | {:error, term()}
  def confirm_connection(%Scope{} = scope, %Claim{} = claim, candidate) do
    case candidate_segments(candidate, claim) do
      [] ->
        {:error, :invalid_connection}

      segments ->
        Repo.transaction(fn ->
          with {:ok, %{claim: planned_claim, journey: planned_journey}} <-
                 Rail.confirm_journey(
                   scope,
                   claim.id,
                   :planned,
                   planned_segments(segments),
                   claim.lock_version
                 ),
               {:ok, %{claim: actual_claim, journey: actual_journey}} <-
                 Rail.confirm_journey(
                   scope,
                   claim.id,
                   :actual,
                   segments,
                   planned_claim.lock_version
                 ) do
            %{
              claim: actual_claim,
              planned_journey: planned_journey,
              actual_journey: actual_journey
            }
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
        |> normalize_transaction()
    end
  end

  @doc "Validates and confirms the manually entered planned journey."
  def confirm_planned_journey(%Scope{} = scope, %Claim{} = claim, params)
      when is_map(params) do
    with {:ok, segments} <- build_planned_segments(params) do
      Rail.confirm_journey(scope, claim.id, :planned, segments, claim.lock_version)
    end
  end

  @doc "Validates and confirms the manually entered actual journey."
  def confirm_actual_journey(
        %Scope{} = scope,
        %Claim{} = claim,
        planned_journey,
        params
      )
      when is_map(params) do
    with {:ok, segments} <-
           build_actual_segments(params, claim.disruption_cause, planned_journey) do
      Rail.confirm_journey(scope, claim.id, :actual, segments, claim.lock_version)
    end
  end

  @doc """
  Builds automatic connection-search params from claim and ticket facts.

  Returns `nil` while route, date or a scheduled departure time are still
  unknown, so the caller can fall back to the manual search form.
  """
  @spec automatic_connection_query(Claim.t(), map()) :: map() | nil
  def automatic_connection_query(%Claim{} = claim, suggestions_by_id)
      when is_map(suggestions_by_id) do
    with origin when is_binary(origin) <- claim.origin,
         destination when is_binary(destination) <- claim.destination,
         %Date{} = travel_date <- claim.travel_date,
         %Time{} = departure_time <- suggested_departure_time(suggestions_by_id) do
      %{
        "origin" => origin,
        "destination" => destination,
        "departure_at" =>
          "#{Date.to_iso8601(travel_date)}T#{departure_time |> Time.to_iso8601() |> String.slice(0, 5)}",
        "train_number" => suggested_train_number(suggestions_by_id)
      }
    else
      _missing -> nil
    end
  end

  defp suggested_departure_time(suggestions_by_id) do
    suggestions_by_id
    |> Map.values()
    |> Enum.find_value(fn
      %{field: :scheduled_departure, value: %{"time" => time}} ->
        case Time.from_iso8601(time <> ":00") do
          {:ok, parsed} -> parsed
          {:error, _reason} -> nil
        end

      _other ->
        nil
    end)
  end

  defp suggested_train_number(suggestions_by_id) do
    suggestions_by_id
    |> Map.values()
    |> Enum.find_value(fn
      %{field: :scheduled_train, value: %{"number" => number}} -> number
      _other -> nil
    end)
  end

  @doc "Returns station name options for both route fields."
  def station_options(%Scope{} = scope, claim_id, params) when is_map(params) do
    {
      station_options_for(scope, claim_id, params["origin"]),
      station_options_for(scope, claim_id, params["destination"])
    }
  end

  @doc "Searches provider stations for a suggestion's manual override, name and id kept."
  @spec station_search_options(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, [%{name: String.t(), id: map()}]} | {:error, term()}
  def station_search_options(%Scope{} = scope, claim_id, query) do
    if is_binary(query) && String.length(String.trim(query)) >= 2 do
      case Rail.search_stations(scope, claim_id, query, provider: Rail.Providers.StationCatalog) do
        {:ok, stations} ->
          {:ok, stations |> Enum.map(&%{name: &1.name, id: Map.get(&1, :id)}) |> Enum.take(5)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  @doc "Searches provider connections with the departures fallback."
  def search_connections(%Scope{} = scope, %Claim{} = claim, params) when is_map(params) do
    with {:ok, departure_at} <- parse_datetime(params["departure_at"]),
         {:ok, origin} <- resolve_station(scope, claim, :origin, params["origin"]),
         {:ok, destination} <- resolve_station(scope, claim, :destination, params["destination"]) do
      query = %{origin: origin.id, destination: destination.id, departure_at: departure_at}

      case Rail.search_connections(scope, claim.id, query) do
        {:ok, candidates} ->
          {:ok, filter_candidates(candidates, params)}

        {:error, :unsupported} ->
          until = DateTime.add(departure_at, 6, :hour)

          case Rail.departures(scope, claim.id, origin.id, departure_at, until) do
            {:ok, candidates} -> {:ok, filter_candidates(candidates, params)}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :station_not_found} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # Reuses the claim's already-resolved station id when the search text still
  # matches what was resolved (the untouched auto-search/default case), so a
  # confirmed station is never re-derived by fuzzy text match on every
  # search. Any edited text always goes through a fresh station lookup.
  defp resolve_station(scope, claim, field, text) do
    with true <- text == Map.fetch!(claim, field),
         stored when not is_nil(stored) <- Map.fetch!(claim, :"#{field}_station_id"),
         {:ok, id} <- Rail.external_id_from_storage(stored) do
      {:ok, %{id: id}}
    else
      _unresolved ->
        case Rail.search_stations(scope, claim.id, text || "",
               provider: Rail.Providers.StationCatalog
             ) do
          {:ok, [station | _]} -> {:ok, station}
          {:ok, []} -> {:error, :station_not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Filters the indexed workspace suggestions by state and topic."
  def proposed_suggestions(suggestions_by_id, topic) when is_map(suggestions_by_id) do
    suggestions_by_id
    |> Map.values()
    |> Enum.filter(fn suggestion ->
      suggestion.state == :proposed && (topic == :all || suggestion_topic(suggestion) == topic)
    end)
  end

  @doc "Parses the status values accepted by the workspace controls."
  def transition_status("draft"), do: {:ok, :draft}
  def transition_status("sent"), do: {:ok, :sent}
  def transition_status("completed"), do: {:ok, :completed}
  def transition_status(_status), do: {:error, :invalid_status}

  defp build_read_model(
         scope,
         claim,
         claim_changeset,
         documents,
         suggestions,
         exports,
         api_sources,
         status_history,
         planned_journey,
         actual_journey
       ) do
    upload_documents = Enum.filter(documents, &(&1.kind in @upload_kinds))
    documents_by_kind = Map.new(documents, &{&1.kind, &1})
    documents_by_id = Map.new(documents, &{&1.id, &1})
    suggestions_by_id = Map.new(suggestions, &{&1.id, &1})
    suggestion_duplicates = build_suggestion_duplicates(suggestions)

    visible_suggestions =
      Enum.reject(suggestions, &hidden_duplicate?(&1, suggestion_duplicates))

    suggestion_groups =
      %{route: [], booking: [], other: []}
      |> Map.merge(Enum.group_by(visible_suggestions, &suggestion_topic/1))

    claim_complete? = claim_complete?(claim)
    claim_started? = claim_started?(claim)
    documents_complete? = Enum.all?(@upload_kinds, &Map.has_key?(documents_by_kind, &1))
    documents_started? = upload_documents != []

    analysis_complete? =
      documents_complete? && Enum.all?(upload_documents, &document_analysis_resolved?/1)

    suggestions_complete? =
      analysis_complete? && Enum.all?(suggestions, &(&1.state != :proposed))

    {profile_complete?, profile_error} =
      case Accounts.profile_completeness(scope) do
        {:ok, completeness} -> {completeness.complete?, nil}
        {:error, reason} -> {false, reason}
      end

    planned_complete? = journey_complete?(planned_journey, :planned)
    actual_complete? = actual_journey_complete?(claim, actual_journey)

    actual_started? =
      !is_nil(actual_journey) || claim.journey_outcome == :not_started ||
        !is_nil(claim.disruption_cause)

    readiness = Exports.readiness(scope, claim.id)
    review_complete? = match?({:ok, _prerequisites}, readiness) && suggestions_complete?
    current_export = current_export(exports, readiness)
    exports_available? = !is_nil(current_export)

    review_started? =
      Enum.any?(
        [claim_started?, documents_started?, !is_nil(planned_journey), actual_started?],
        & &1
      )

    step_states = %{
      claim: step_state(claim_complete?, claim_started?),
      documents: step_state(documents_complete?, documents_started?),
      suggestions: step_state(suggestions_complete?, documents_started?),
      planned: step_state(planned_complete?, !is_nil(planned_journey)),
      actual: step_state(actual_complete?, actual_started?),
      review: step_state(exports_available?, review_complete? || review_started?)
    }

    %ReadModel{
      claim: claim,
      claim_changeset: claim_changeset,
      documents_by_kind: documents_by_kind,
      documents_by_id: documents_by_id,
      suggestions_by_id: suggestions_by_id,
      suggestion_groups: suggestion_groups,
      suggestion_duplicates: suggestion_duplicates,
      planned_journey: planned_journey,
      actual_journey: actual_journey,
      exports: exports,
      current_export: current_export,
      api_sources: api_sources,
      status_history: status_history,
      profile_complete?: profile_complete?,
      profile_error: profile_error,
      claim_complete?: claim_complete?,
      documents_complete?: documents_complete?,
      suggestions_complete?: suggestions_complete?,
      planned_complete?: planned_complete?,
      actual_complete?: actual_complete?,
      review_complete?: review_complete?,
      exports_available?: exports_available?,
      step_states: step_states,
      readiness: readiness
    }
  end

  @doc false
  # Fields extracted from both ticket and invoice can yield two still-proposed
  # suggestions for the same field. Rather than showing them as separate
  # cards, one representative (highest confidence) stays visible and carries
  # the others as selectable candidates; see `suggestion_duplicate_candidates/2`.
  defp build_suggestion_duplicates(suggestions) do
    suggestions
    |> Enum.filter(&(&1.state == :proposed))
    |> Enum.group_by(& &1.field)
    |> Enum.filter(fn {_field, group} -> length(group) > 1 end)
    |> Enum.flat_map(fn {_field, group} ->
      ids =
        group
        |> Enum.sort_by(&{-&1.confidence, &1.inserted_at, &1.id})
        |> Enum.map(& &1.id)

      representative_id = List.first(ids)

      Enum.map(ids, fn id ->
        {id, %{representative?: id == representative_id, sibling_ids: ids -- [id]}}
      end)
    end)
    |> Map.new()
  end

  defp hidden_duplicate?(suggestion, suggestion_duplicates) do
    case Map.get(suggestion_duplicates, suggestion.id) do
      nil -> false
      %{representative?: representative?} -> !representative?
    end
  end

  defp current_export([], _readiness), do: nil

  defp current_export(exports, {:ok, prerequisites}) do
    latest = List.last(exports)
    if Exports.model_current?(prerequisites, latest), do: latest
  end

  defp current_export(_exports, {:error, _reason}), do: nil

  defp optional_journey(scope, claim_id, kind) do
    case Rail.get_journey(scope, claim_id, kind) do
      {:ok, journey} -> {:ok, journey}
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_update_claim(_scope, claim, attrs) when attrs == %{}, do: {:ok, claim}

  defp maybe_update_claim(scope, claim, attrs) do
    Claims.update_claim(scope, claim.id, attrs, claim.lock_version)
  end

  defp claim_attrs_for_suggestions(suggestions) do
    Enum.reduce(suggestions, %{}, fn suggestion, attrs ->
      Map.merge(attrs, claim_attrs_for_suggestion(suggestion))
    end)
  end

  defp claim_attrs_for_suggestion(%{field: :travel_date, value: value}),
    do: present_attr("travel_date", Map.get(value, "date"))

  defp claim_attrs_for_suggestion(%{field: :origin, value: value}) do
    Map.merge(
      present_attr("origin", Map.get(value, "text")),
      station_id_attr("origin_station_id", value)
    )
  end

  defp claim_attrs_for_suggestion(%{field: :destination, value: value}) do
    Map.merge(
      present_attr("destination", Map.get(value, "text")),
      station_id_attr("destination_station_id", value)
    )
  end

  defp claim_attrs_for_suggestion(_suggestion), do: %{}

  defp present_attr(_key, value) when value in [nil, ""], do: %{}
  defp present_attr(key, value), do: %{key => value}

  # Only present when StationNormalizer confirmed a match — an unresolved
  # suggestion's raw text carries no id, so origin/destination_station_id
  # is left absent and Claim.update_changeset/2 clears any stale one.
  defp station_id_attr(key, %{"station_id" => id}) when not is_nil(id),
    do: %{key => Rail.external_id_for_storage(id)}

  defp station_id_attr(_key, _value), do: %{}

  defp normalize_transaction({:ok, result}), do: {:ok, result}
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp station_options_for(scope, claim_id, query) do
    if is_binary(query) && String.length(String.trim(query)) >= 2 do
      case Rail.search_stations(scope, claim_id, query, provider: Rail.Providers.StationCatalog) do
        {:ok, stations} -> stations |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.take(8)
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  defp filter_candidates(candidates, params) do
    train_number = params["train_number"] |> to_string() |> String.trim()

    if train_number == "" do
      candidates
    else
      Enum.filter(candidates, fn candidate ->
        Enum.any?(candidate.segments, &(&1.train_number == train_number))
      end)
    end
  end

  defp candidate_segments(candidate, claim) do
    last_index = length(candidate.segments) - 1

    candidate.segments
    |> Enum.with_index()
    |> Enum.map(fn {segment, index} ->
      segment
      |> Map.new()
      |> Map.put(:origin_name, if(index == 0, do: claim.origin, else: segment.origin_name))
      |> Map.put(
        :destination_name,
        if(index == last_index, do: claim.destination, else: segment.destination_name)
      )
    end)
  end

  defp planned_segments(segments) do
    Enum.map(segments, fn segment ->
      segment
      |> Map.put(:actual_departure, nil)
      |> Map.put(:actual_arrival, nil)
      |> Map.put(:estimated_departure, nil)
      |> Map.put(:estimated_arrival, nil)
      |> Map.put(:cancelled, false)
    end)
  end

  defp build_planned_segments(params) do
    with {:ok, scheduled_departure} <- parse_datetime(params["scheduled_departure"]),
         {:ok, scheduled_arrival} <- parse_datetime(params["scheduled_arrival"]),
         :ok <- validate_order(scheduled_departure, scheduled_arrival) do
      first = %{
        origin_name: params["origin_name"],
        destination_name: params["destination_name"],
        train_category: params["train_category"],
        train_number: params["train_number"],
        scheduled_departure: scheduled_departure,
        scheduled_arrival: scheduled_arrival,
        source: "manual",
        manual: true
      }

      build_transfer_segments(first, params)
    end
  end

  defp build_transfer_segments(first, %{"via_name" => via_name} = params)
       when is_binary(via_name) and via_name != "" do
    with {:ok, transfer_arrival} <- parse_datetime(params["transfer_arrival"]),
         {:ok, transfer_departure} <- parse_datetime(params["transfer_departure"]),
         :ok <- validate_order(first.scheduled_departure, transfer_arrival),
         :ok <- validate_order(transfer_arrival, transfer_departure),
         :ok <- validate_order(transfer_departure, first.scheduled_arrival) do
      {:ok,
       [
         %{first | destination_name: String.trim(via_name), scheduled_arrival: transfer_arrival},
         %{
           origin_name: String.trim(via_name),
           destination_name: first.destination_name,
           train_category: params["second_category"],
           train_number: params["second_number"],
           scheduled_departure: transfer_departure,
           scheduled_arrival: first.scheduled_arrival,
           source: "manual",
           manual: true
         }
       ]}
    end
  end

  defp build_transfer_segments(first, _params), do: {:ok, [first]}

  defp parse_datetime(value) when is_binary(value) do
    with {:ok, naive} <- GermanDateTime.parse_datetime(value),
         {:ok, utc} <- BerlinTime.from_local(naive) do
      {:ok, utc}
    else
      _error -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_datetime}

  defp parse_optional_datetime(value) when value in [nil, ""], do: {:ok, nil}
  defp parse_optional_datetime(value), do: parse_datetime(value)

  defp validate_order(from, until) do
    if DateTime.compare(until, from) == :lt,
      do: {:error, :invalid_time_order},
      else: :ok
  end

  defp build_actual_segments(params, :delay, _planned_journey), do: build_delay_segment(params)

  defp build_actual_segments(params, :cancellation, planned_journey),
    do: build_cancellation_segments(params, planned_journey)

  defp build_actual_segments(params, :missed_connection, planned_journey),
    do: build_missed_connection_segments(params, planned_journey)

  defp build_actual_segments(_params, _cause, _planned_journey),
    do: {:error, :missing_disruption}

  defp build_delay_segment(params) do
    with {:ok, scheduled_departure} <- parse_datetime(params["scheduled_departure"]),
         {:ok, scheduled_arrival} <- parse_datetime(params["scheduled_arrival"]),
         {:ok, actual_departure} <- parse_optional_datetime(params["actual_departure"]),
         {:ok, actual_arrival} <- parse_datetime(params["actual_arrival"]),
         :ok <- validate_order(scheduled_departure, scheduled_arrival) do
      {:ok,
       [
         %{
           origin_name: params["origin_name"],
           destination_name: params["destination_name"],
           train_category: params["train_category"],
           train_number: params["train_number"],
           scheduled_departure: scheduled_departure,
           scheduled_arrival: scheduled_arrival,
           actual_departure: actual_departure,
           actual_arrival: actual_arrival,
           cancelled: false,
           source: "manual",
           manual: true
         }
       ]}
    end
  end

  defp build_cancellation_segments(_params, nil), do: {:error, :missing_planned}

  defp build_cancellation_segments(params, planned_journey) do
    planned = List.first(planned_journey.segments)

    with {:ok, replacement_departure} <- parse_datetime(params["replacement_departure"]),
         {:ok, replacement_arrival} <- parse_datetime(params["replacement_arrival"]),
         :ok <- validate_order(replacement_departure, replacement_arrival) do
      cancelled =
        planned
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :journey, :journey_id, :inserted_at, :updated_at, :position])
        |> Map.put(:actual_departure, nil)
        |> Map.put(:actual_arrival, nil)
        |> Map.put(:estimated_departure, nil)
        |> Map.put(:estimated_arrival, nil)
        |> Map.put(:cancelled, true)
        |> Map.put(:source, "manual")
        |> Map.put(:manual, true)

      replacement = %{
        origin_name: params["origin_name"],
        destination_name: params["destination_name"],
        train_category: params["replacement_category"],
        train_number: params["replacement_number"],
        scheduled_departure: replacement_departure,
        scheduled_arrival: replacement_arrival,
        actual_departure: replacement_departure,
        actual_arrival: replacement_arrival,
        cancelled: false,
        source: "manual",
        manual: true
      }

      {:ok, [cancelled, replacement]}
    end
  end

  defp document_analysis_resolved?(%Document{analysis_status: status})
       when status in [:completed, :manual_required],
       do: true

  defp document_analysis_resolved?(%Document{
         analysis_status: :failed,
         manual_fallback_confirmed_at: confirmed_at
       }),
       do: not is_nil(confirmed_at)

  defp document_analysis_resolved?(%Document{}), do: false

  defp build_missed_connection_segments(_params, nil), do: {:error, :missing_planned}

  defp build_missed_connection_segments(params, planned_journey) do
    with {:ok, [feeder]} <- build_delay_segment(params),
         {:ok, onward_departure} <- parse_datetime(params["missed_connection_departure"]),
         {:ok, onward_arrival} <- parse_datetime(params["missed_connection_arrival"]),
         :ok <- validate_order(onward_departure, onward_arrival) do
      onward = %{
        origin_name: feeder.destination_name,
        destination_name: List.last(planned_journey.segments).destination_name,
        train_category: params["missed_connection_category"],
        train_number: params["missed_connection_number"],
        scheduled_departure: onward_departure,
        scheduled_arrival: onward_arrival,
        actual_departure: onward_departure,
        actual_arrival: onward_arrival,
        cancelled: false,
        source: "manual",
        manual: true
      }

      {:ok, [feeder, onward]}
    end
  end

  defp journey_complete?(nil, _kind), do: false

  defp journey_complete?(journey, :planned) do
    journey.segments != [] &&
      Enum.all?(journey.segments, &(&1.scheduled_departure && &1.scheduled_arrival))
  end

  defp actual_journey_complete?(%{journey_outcome: :not_started}, _journey), do: true
  defp actual_journey_complete?(_claim, nil), do: false

  defp actual_journey_complete?(_claim, journey) do
    journey.segments != [] &&
      Enum.any?(journey.segments, &(&1.actual_arrival || &1.estimated_arrival))
  end

  defp suggestion_topic(%{field: field})
       when field in [
              :travel_date,
              :valid_until,
              :origin,
              :destination,
              :scheduled_train,
              :scheduled_departure,
              :scheduled_arrival
            ],
       do: :route

  defp suggestion_topic(%{field: field}) when field in [:order_number, :fare, :product],
    do: :booking

  defp suggestion_topic(_suggestion), do: :other

  defp claim_started?(claim) do
    Enum.any?(
      [
        claim.travel_date,
        claim.origin,
        claim.destination,
        claim.journey_outcome,
        claim.disruption_cause
      ],
      &(&1 not in [nil, ""])
    )
  end

  defp claim_complete?(claim) do
    Enum.all?(
      [
        claim.travel_date,
        claim.origin,
        claim.destination,
        claim.journey_outcome,
        claim.disruption_cause,
        claim.journey_direction
      ],
      &(!is_nil(&1))
    )
  end

  defp step_state(true, _started?), do: :confirmed
  defp step_state(false, true), do: :incomplete
  defp step_state(false, false), do: :open
end
