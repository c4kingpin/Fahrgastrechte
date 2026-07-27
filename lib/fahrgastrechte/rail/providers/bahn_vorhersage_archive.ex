defmodule Fahrgastrechte.Rail.Providers.BahnVorhersageArchive do
  @moduledoc """
  Read-only adapter for an administrator-prepared Bahn-Vorhersage projection.

  The adapter never calls Bahn-Vorhersage's website or Web API. `data_path`
  points to a local CSV projection with the columns documented by C00. Missing
  files and uncovered dates immediately return `:history_unavailable`.
  """

  @behaviour Fahrgastrechte.Rail.Provider

  @required_headers ~w(
    trip_id time_schedule time_real update_timestamp delay is_final is_arrival
    is_cancelled category number stop_id initial_scheduled_departure
    initial_stop_id stop_sequence trip_headsign
  )

  @impl true
  def search_stations(query, options) do
    station_names = archive_option(options, :station_names, %{})
    normalized_query = query |> String.trim() |> String.downcase()

    stations =
      station_names
      |> Enum.filter(fn {_eva, name} ->
        String.contains?(String.downcase(name), normalized_query)
      end)
      |> Enum.map(fn {eva, name} -> station(to_string(eva), name) end)

    {:ok, stations}
  end

  @impl true
  def search_connections(_query, _options), do: {:error, :unsupported}

  @impl true
  def departures(%{provider: __MODULE__, value: stop_id}, from, until, options) do
    with {:ok, rows, metadata} <- load_rows(options),
         matching when matching != [] <-
           Enum.filter(rows, fn row ->
             scheduled = parse_datetime(row["time_schedule"])

             ((row["stop_id"] == stop_id and row["is_arrival"] == "false" and scheduled) &&
                DateTime.compare(scheduled, from) in [:eq, :gt]) and
               DateTime.compare(scheduled, until) == :lt
           end) do
      trip_ids = MapSet.new(matching, & &1["trip_id"])

      journeys =
        rows
        |> Enum.filter(&MapSet.member?(trip_ids, &1["trip_id"]))
        |> Enum.group_by(& &1["trip_id"])
        |> Enum.map(fn {_trip_id, trip_rows} ->
          normalize_journey(trip_rows, options, metadata)
        end)
        |> Enum.sort_by(
          fn journey ->
            journey.events |> List.first() |> Map.fetch!(:scheduled_at)
          end,
          DateTime
        )

      {:ok, journeys}
    else
      [] -> {:error, :history_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  def departures(_station_id, _from, _until, _options), do: {:error, :not_found}

  @impl true
  def journey(%{provider: __MODULE__, value: trip_id}, options) do
    with {:ok, rows, metadata} <- load_rows(options),
         matching when matching != [] <- Enum.filter(rows, &(&1["trip_id"] == trip_id)) do
      {:ok, normalize_journey(matching, options, metadata)}
    else
      [] -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def journey(_journey_id, _options), do: {:error, :not_found}

  defp load_rows(options) do
    case archive_option(options, :data_path, nil) do
      path when is_binary(path) ->
        case File.read(path) do
          {:ok, content} -> parse_csv(content, path, options)
          {:error, _reason} -> {:error, :history_unavailable}
        end

      _missing ->
        {:error, :history_unavailable}
    end
  end

  defp parse_csv(content, path, options) do
    case String.split(content, ~r/\R/u, trim: true) do
      [header | lines] ->
        headers = String.split(header, ",")

        if Enum.all?(@required_headers, &(&1 in headers)) do
          rows =
            Enum.map(lines, fn line ->
              headers
              |> Enum.zip(String.split(line, ","))
              |> Map.new()
            end)

          metadata = %{
            "dataset_version" => archive_option(options, :dataset_version, "unknown"),
            "license" => "ODbL-1.0",
            "attribution" => "Bahn-Vorhersage, Deutsche Bahn, Trainline und DELFI",
            "source_sha256" => :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower),
            "source_name" => Path.basename(path)
          }

          {:ok, rows, metadata}
        else
          {:error, {:upstream, :invalid_archive_projection}}
        end

      _empty ->
        {:error, :history_unavailable}
    end
  end

  defp normalize_journey(rows, options, metadata) do
    latest_rows =
      rows
      |> Enum.group_by(& &1["stop_sequence"])
      |> Enum.map(fn {_sequence, updates} ->
        Enum.max_by(updates, &(&1["update_timestamp"] || ""))
      end)
      |> Enum.sort_by(&parse_integer(&1["stop_sequence"]))

    first = List.first(latest_rows)

    events =
      Enum.map(latest_rows, fn row ->
        final? = row["is_final"] == "true"
        real_time = parse_datetime(row["time_real"])

        %{
          station: station(row["stop_id"], station_name(row["stop_id"], options)),
          scheduled_at: parse_datetime(row["time_schedule"]),
          estimated_at: if(final?, do: nil, else: real_time),
          actual_at: if(final?, do: real_time, else: nil),
          source_updated_at: parse_datetime(row["update_timestamp"]),
          final: final?,
          cancelled: row["is_cancelled"] == "true",
          source_id: external_id("#{row["trip_id"]}:#{row["stop_sequence"]}")
        }
      end)

    %{
      id: external_id(first["trip_id"]),
      category: first["category"],
      number: first["number"],
      events: events,
      fetched_at: now(),
      source_metadata: metadata
    }
  end

  defp station_name(stop_id, options) do
    options
    |> archive_option(:station_names, %{})
    |> Map.get(stop_id, stop_id)
  end

  defp station(eva, name) do
    %{id: external_id(eva), name: name, eva_number: eva}
  end

  defp external_id(value), do: %{provider: __MODULE__, value: value}

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      {:error, _reason} -> nil
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value || "") do
      {integer, ""} -> integer
      _invalid -> 0
    end
  end

  defp archive_option(options, key, default) do
    config = Application.get_env(:fahrgastrechte, __MODULE__, [])
    Keyword.get(options, key, Keyword.get(config, key, default))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
