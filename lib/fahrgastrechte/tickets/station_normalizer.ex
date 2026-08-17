defmodule Fahrgastrechte.Tickets.StationNormalizer do
  @moduledoc false

  @text_fields [:origin, :destination]
  @timed_fields [:scheduled_departure, :scheduled_arrival]
  @minimum_score 60
  @candidate_floor 20
  @max_candidates 5

  @doc """
  Replaces extracted station text with the best canonical provider result.

  When the provider can't confirm a match (API error, no candidate above the
  minimum score), the raw extracted text is kept but the suggestion is marked
  `"unresolved" => true` instead of being silently presented as a confirmed
  station name. When it can, `:origin`/`:destination` suggestions also carry
  the provider's station id under `"station_id"` so callers can persist it
  instead of re-resolving the name by text later.
  """
  def normalize(suggestions, search_stations)
      when is_list(suggestions) and is_function(search_stations, 1) do
    {normalized, _cache} =
      Enum.map_reduce(suggestions, %{}, fn suggestion, cache ->
        case station_text(suggestion) do
          nil ->
            {suggestion, cache}

          station_text ->
            {match, cache} = cached_station_match(station_text, cache, search_stations)

            case match do
              nil ->
                {put_station_text(suggestion, station_text, nil, [], unresolved: true), cache}

              {false, _best, candidates} ->
                {put_station_text(suggestion, station_text, nil, candidates, unresolved: true),
                 cache}

              {true, {name, id}, candidates} ->
                {put_station_text(suggestion, name, id, candidates, unresolved: false), cache}
            end
        end
      end)

    normalized
  end

  defp cached_station_match(station_text, cache, search_stations) do
    case Map.fetch(cache, station_text) do
      {:ok, match} ->
        {match, cache}

      :error ->
        match = find_station_match(station_text, search_stations)
        {match, Map.put(cache, station_text, match)}
    end
  end

  defp find_station_match(station_text, search_stations) do
    matches =
      station_text
      |> search_queries()
      |> Enum.flat_map(fn query ->
        case search_stations.(query) do
          {:ok, stations} when is_list(stations) -> score_stations(station_text, query, stations)
          _error -> []
        end
      end)
      |> Enum.uniq_by(fn {_score, name, _id} -> normalize_name(name) end)
      |> Enum.filter(fn {score, _name, _id} -> score > @candidate_floor end)
      |> Enum.sort_by(fn {score, _name, _id} -> score end, :desc)
      |> Enum.take(@max_candidates)

    case matches do
      [] ->
        nil

      [{best_score, best_name, best_id} | _rest] = matches ->
        candidates = Enum.map(matches, fn {_score, name, id} -> {name, id} end)
        resolved? = best_score >= @minimum_score
        {resolved?, {best_name, best_id}, candidates}
    end
  end

  defp score_stations(source, query, stations) do
    Enum.flat_map(stations, fn
      %{name: name} = station when is_binary(name) ->
        [{station_score(source, query, name), name, Map.get(station, :id)}]

      _station ->
        []
    end)
  end

  defp station_score(source, query, candidate) do
    normalized_query = normalize_name(query)
    normalized_candidate = normalize_name(candidate)

    base_score =
      cond do
        normalized_query == "" or normalized_candidate == "" ->
          0

        normalized_query == normalized_candidate ->
          100

        String.starts_with?(normalized_candidate, normalized_query <> " ") ->
          80

        String.starts_with?(normalized_query, normalized_candidate <> " ") ->
          75

        String.contains?(normalized_candidate, normalized_query) ->
          65

        true ->
          token_score(normalized_query, normalized_candidate)
      end

    base_score + station_type_bonus(source, normalized_candidate)
  end

  defp token_score(query, candidate) do
    query_tokens = query |> String.split() |> MapSet.new()
    candidate_tokens = candidate |> String.split() |> MapSet.new()

    if MapSet.size(query_tokens) == 0 do
      0
    else
      matching_tokens = query_tokens |> MapSet.intersection(candidate_tokens) |> MapSet.size()
      round(55 * matching_tokens / MapSet.size(query_tokens))
    end
  end

  defp station_type_bonus(source, candidate) do
    cond do
      long_distance_ticket?(source) and String.contains?(candidate, "fernbahnhof") -> 30
      long_distance_ticket?(source) and String.contains?(candidate, "regionalbahnhof") -> -30
      city_ticket?(source) and String.contains?(candidate, "hauptbahnhof") -> 25
      city_ticket?(source) -> -30
      true -> 0
    end
  end

  defp search_queries(station_text) do
    without_product =
      station_text
      |> String.trim()
      |> then(
        &Regex.replace(
          ~r/\s+(?:nur\s+)?mit\s+(?:ICE|IC|EC|ECE|RJX?|TGV|FLX)(?:\s.*)?$/iu,
          &1,
          ""
        )
      )

    base =
      without_product
      |> then(&Regex.replace(~r/\+City(?:-Ticket)?(?:\s.*)?$/iu, &1, ""))
      |> String.trim()
      |> String.trim_trailing(".,;")

    expanded =
      base
      |> String.replace(~r/\s*Flugh\.?$/iu, " Flughafen")
      |> String.replace(~r/\s+/u, " ")

    [expanded, base]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  defp normalize_name(name) do
    name
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace("ß", "ss")
    |> String.replace(~r/\(\s*m(?:ain)?\s*\)/u, " main ")
    |> String.replace(~r/\bflugh\b/u, "flughafen")
    |> String.replace(~r/\bfernbf\b/u, "fernbahnhof")
    |> String.replace(~r/\bregionalbf\b/u, "regionalbahnhof")
    |> String.replace(~r/\bhbf\b/u, "hauptbahnhof")
    |> String.replace(~r/\bbf\b/u, "bahnhof")
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp station_text(%{field: field, value: %{"text" => text}})
       when field in @text_fields and is_binary(text),
       do: text

  defp station_text(%{field: field, value: %{"station" => station}})
       when field in @timed_fields and is_binary(station),
       do: station

  defp station_text(_suggestion), do: nil

  defp put_station_text(
         %{field: field, value: value} = suggestion,
         station_name,
         station_id,
         candidates,
         unresolved: unresolved?
       )
       when field in @text_fields do
    value =
      value
      |> Map.put("text", station_name)
      |> put_unresolved(unresolved?)
      |> put_station_id(station_id)
      |> put_candidates(candidates)

    %{suggestion | value: value}
  end

  defp put_station_text(
         %{field: field, value: value} = suggestion,
         station_name,
         _station_id,
         _candidates,
         unresolved: unresolved?
       )
       when field in @timed_fields,
       do: %{
         suggestion
         | value: value |> Map.put("station", station_name) |> put_unresolved(unresolved?)
       }

  defp put_unresolved(value, true), do: Map.put(value, "unresolved", true)
  defp put_unresolved(value, false), do: Map.delete(value, "unresolved")

  defp put_station_id(value, nil), do: Map.delete(value, "station_id")
  defp put_station_id(value, id), do: Map.put(value, "station_id", id)

  defp put_candidates(value, []), do: Map.delete(value, "candidates")

  defp put_candidates(value, candidates) do
    Map.put(
      value,
      "candidates",
      Enum.map(candidates, fn {name, id} -> %{"text" => name, "station_id" => id} end)
    )
  end

  defp long_distance_ticket?(source),
    do: Regex.match?(~r/\b(?:ICE|IC|EC|ECE|RJX?|TGV|FLX)\b/u, source)

  defp city_ticket?(source), do: Regex.match?(~r/\+City(?:-Ticket)?\b/iu, source)
end
