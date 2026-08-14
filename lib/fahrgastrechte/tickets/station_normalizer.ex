defmodule Fahrgastrechte.Tickets.StationNormalizer do
  @moduledoc false

  @text_fields [:origin, :destination]
  @timed_fields [:scheduled_departure, :scheduled_arrival]
  @minimum_score 60

  @doc "Replaces extracted station text with the best canonical provider result."
  def normalize(suggestions, search_stations)
      when is_list(suggestions) and is_function(search_stations, 1) do
    {normalized, _cache} =
      Enum.map_reduce(suggestions, %{}, fn suggestion, cache ->
        case station_text(suggestion) do
          nil ->
            {suggestion, cache}

          station_text ->
            {canonical_name, cache} =
              cached_station_name(station_text, cache, search_stations)

            {put_station_text(suggestion, canonical_name || station_text), cache}
        end
      end)

    normalized
  end

  defp cached_station_name(station_text, cache, search_stations) do
    case Map.fetch(cache, station_text) do
      {:ok, canonical_name} ->
        {canonical_name, cache}

      :error ->
        canonical_name = find_station_name(station_text, search_stations)
        {canonical_name, Map.put(cache, station_text, canonical_name)}
    end
  end

  defp find_station_name(station_text, search_stations) do
    station_text
    |> search_queries()
    |> Enum.reduce_while(nil, fn query, _result ->
      case search_stations.(query) do
        {:ok, stations} when is_list(stations) ->
          case best_station_name(station_text, query, stations) do
            nil -> {:cont, nil}
            station_name -> {:halt, station_name}
          end

        _error ->
          {:cont, nil}
      end
    end)
  end

  defp best_station_name(source, query, stations) do
    stations
    |> Enum.flat_map(fn
      %{name: name} when is_binary(name) -> [{station_score(source, query, name), name}]
      _station -> []
    end)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
    |> case do
      {score, name} when score >= @minimum_score -> name
      _no_match -> nil
    end
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

  defp put_station_text(%{field: field, value: value} = suggestion, station_name)
       when field in @text_fields,
       do: %{suggestion | value: Map.put(value, "text", station_name)}

  defp put_station_text(%{field: field, value: value} = suggestion, station_name)
       when field in @timed_fields,
       do: %{suggestion | value: Map.put(value, "station", station_name)}

  defp long_distance_ticket?(source),
    do: Regex.match?(~r/\b(?:ICE|IC|EC|ECE|RJX?|TGV|FLX)\b/u, source)

  defp city_ticket?(source), do: Regex.match?(~r/\+City(?:-Ticket)?\b/iu, source)
end
