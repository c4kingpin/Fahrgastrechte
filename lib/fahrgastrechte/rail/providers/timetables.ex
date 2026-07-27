defmodule Fahrgastrechte.Rail.Providers.Timetables do
  @moduledoc """
  Deutsche-Bahn Timetables adapter implemented with `Req`.

  Timetables has no general start-to-destination search and no dependable
  history. The adapter therefore exposes station and departure reconstruction;
  normalized values and immutable raw-response snapshots are returned to the
  Rail context for scoped persistence.
  """

  @behaviour Fahrgastrechte.Rail.Provider

  alias Fahrgastrechte.Rail.RateLimiter
  alias Fahrgastrechte.Rail.Providers.XML

  @default_base_url "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1"
  @max_window_hours 6

  @impl true
  def search_stations(query, options) do
    path = "/station/#{URI.encode(query, &URI.char_unreserved?/1)}"

    with {:ok, body, snapshot} <- request(path, options),
         {:ok, root} <- XML.parse(body) do
      stations =
        root
        |> XML.elements("//station")
        |> Enum.map(fn station ->
          eva = XML.attr(station, :eva)

          %{
            id: external_id(eva),
            name: XML.attr(station, :name),
            eva_number: eva
          }
        end)

      {:ok, stations, snapshot}
    else
      {:error, reason} -> {:error, normalize_parse_error(reason)}
    end
  end

  @impl true
  def search_connections(_query, _options), do: {:error, :unsupported}

  @impl true
  def departures(%{provider: __MODULE__, value: eva}, from, until, options)
      when is_binary(eva) do
    with :ok <- validate_window(from, until),
         {:ok, plan_results} <- fetch_plans(eva, from, until, options),
         {:ok, changes_body, changes_snapshot} <- request("/fchg/#{eva}", options),
         {:ok, changes} <- parse_changes(changes_body),
         {:ok, journeys} <- normalize_departures(plan_results, changes, from, until) do
      snapshots = Enum.map(plan_results, & &1.snapshot) ++ [changes_snapshot]
      {:ok, journeys, snapshots}
    else
      {:error, reason} -> {:error, normalize_parse_error(reason)}
    end
  end

  def departures(_station_id, _from, _until, _options), do: {:error, :not_found}

  @impl true
  def journey(%{provider: __MODULE__, value: journey_id}, options) do
    station_id = Keyword.get(options, :station_id)

    with %{provider: __MODULE__} <- station_id,
         {:ok, scheduled_at} <- journey_time(journey_id),
         from <- DateTime.add(scheduled_at, -60, :second),
         until <- DateTime.add(scheduled_at, 3_600, :second),
         {:ok, journeys, snapshots} <- departures(station_id, from, until, options),
         journey when not is_nil(journey) <-
           Enum.find(journeys, &(&1.id.value == journey_id)) do
      {:ok, journey, snapshots}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :unsupported}
    end
  end

  def journey(_journey_id, _options), do: {:error, :not_found}

  defp fetch_plans(eva, from, until, options) do
    from
    |> covered_hours(until)
    |> Enum.reduce_while({:ok, []}, fn hour, {:ok, results} ->
      local = utc_to_berlin_naive(hour)
      date = Calendar.strftime(local, "%y%m%d")
      hour_value = Calendar.strftime(local, "%H")

      case request("/plan/#{eva}/#{date}/#{hour_value}", options) do
        {:ok, body, snapshot} ->
          {:cont, {:ok, [%{body: body, snapshot: snapshot} | results]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_departures(plan_results, changes, from, until) do
    plan_results
    |> Enum.reduce_while({:ok, []}, fn %{body: body}, {:ok, journeys} ->
      case parse_plan(body, changes) do
        {:ok, parsed} -> {:cont, {:ok, parsed ++ journeys}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, journeys} ->
        filtered =
          journeys
          |> Enum.filter(fn journey ->
            scheduled_at = journey.events |> List.first() |> Map.get(:scheduled_at)

            scheduled_at && DateTime.compare(scheduled_at, from) in [:eq, :gt] &&
              DateTime.compare(scheduled_at, until) == :lt
          end)
          |> Enum.uniq_by(& &1.id.value)
          |> Enum.sort_by(
            fn journey -> journey.events |> List.first() |> Map.get(:scheduled_at) end,
            DateTime
          )

        {:ok, filtered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_plan(body, changes) do
    with {:ok, root} <- XML.parse(body) do
      station_name = XML.attr(root, :station)

      journeys =
        root
        |> XML.elements("//s")
        |> Enum.flat_map(fn stop ->
          departure = stop |> XML.elements("./dp") |> List.first()
          train = stop |> XML.elements("./tl") |> List.first()

          if departure && train do
            stop_id = XML.attr(stop, :id)
            change = Map.get(changes, stop_id, %{})
            scheduled_at = parse_db_time(XML.attr(departure, :pt))
            path = split_path(XML.attr(departure, :ppth))
            station = station(station_name, XML.attr(stop, :eva))

            first_event = %{
              station: station,
              scheduled_at: scheduled_at,
              estimated_at: change[:estimated_at],
              source_updated_at: change[:source_updated_at],
              cancelled: Map.get(change, :cancelled, false),
              platform: XML.attr(departure, :pp),
              source_id: external_id(stop_id)
            }

            path_events =
              Enum.map(path, fn name ->
                %{
                  station: %{id: external_id("path:#{name}"), name: name},
                  cancelled: Map.get(change, :cancelled, false)
                }
              end)

            [
              %{
                id: external_id(stop_id),
                category: XML.attr(train, :c) || "",
                number: XML.attr(train, :n) || "",
                events: [first_event | path_events],
                fetched_at: now(),
                source_metadata: %{"timetable_stop_id" => stop_id}
              }
            ]
          else
            []
          end
        end)

      {:ok, journeys}
    end
  end

  defp parse_changes(body) do
    with {:ok, root} <- XML.parse(body) do
      changes =
        root
        |> XML.elements("//s")
        |> Map.new(fn stop ->
          event =
            case stop |> XML.elements("./dp") |> List.first() do
              nil -> stop |> XML.elements("./ar") |> List.first()
              departure -> departure
            end

          value =
            if event do
              %{
                estimated_at: parse_db_time(XML.attr(event, :ct)),
                source_updated_at: parse_db_time(XML.attr(event, :clt)),
                cancelled: XML.attr(event, :cs) == "c"
              }
            else
              %{}
            end

          {XML.attr(stop, :id), value}
        end)

      {:ok, changes}
    end
  end

  defp request(path, options) do
    config = Application.get_env(:fahrgastrechte, __MODULE__, [])
    client_id = Keyword.get(options, :client_id, Keyword.get(config, :client_id))
    api_key = Keyword.get(options, :api_key, Keyword.get(config, :api_key))

    if blank?(client_id) or blank?(api_key) do
      {:error, {:upstream, :not_configured}}
    else
      request_options = [
        url:
          Keyword.get(options, :base_url, Keyword.get(config, :base_url, @default_base_url)) <>
            path,
        headers: [{"DB-Client-Id", client_id}, {"DB-Api-Key", api_key}],
        receive_timeout: Keyword.get(options, :receive_timeout, 10_000),
        retry: false
      ]

      request_fun = Keyword.get(options, :request_fun, &Req.get/1)
      limiter = Keyword.get(options, :limiter, RateLimiter)

      max_response_bytes =
        Keyword.get(
          options,
          :max_response_bytes,
          Keyword.get(config, :max_response_bytes, 5 * 1024 * 1024)
        )

      execute_request(
        request_fun,
        request_options,
        limiter,
        path,
        max_response_bytes,
        Keyword.get(options, :sleep_fun, &Process.sleep/1),
        2,
        0
      )
    end
  end

  defp execute_request(
         request_fun,
         request_options,
         limiter,
         path,
         max_response_bytes,
         sleep_fun,
         retries_left,
         attempt
       ) do
    result = limited_request(limiter, fn -> request_fun.(request_options) end)

    if retries_left > 0 and retryable?(result) do
      sleep_fun.(retry_delay(result, attempt))

      execute_request(
        request_fun,
        request_options,
        limiter,
        path,
        max_response_bytes,
        sleep_fun,
        retries_left - 1,
        attempt + 1
      )
    else
      normalize_response(result, path, max_response_bytes)
    end
  end

  defp limited_request(false, callback), do: callback.()

  defp limited_request(limiter, callback) do
    case limiter.with_permit(fn -> {:request_result, callback.()} end) do
      {:request_result, result} -> result
      {:error, :rate_limited} -> {:local_error, :rate_limited}
    end
  end

  defp retryable?({:ok, %{status: status}}) when status in [408, 429], do: true
  defp retryable?({:ok, %{status: status}}) when status >= 500 and status <= 599, do: true
  defp retryable?({:error, _reason}), do: true
  defp retryable?(_result), do: false

  defp retry_delay({:ok, response}, attempt) do
    response
    |> response_retry_after()
    |> case do
      nil -> trunc(100 * :math.pow(2, attempt))
      milliseconds -> milliseconds
    end
  end

  defp retry_delay(_result, attempt), do: trunc(100 * :math.pow(2, attempt))

  defp response_retry_after(%{headers: headers}) when is_map(headers) do
    case Map.get(headers, "retry-after", []) |> List.first() do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> min(seconds * 1_000, 30_000)
          _invalid -> nil
        end

      _missing ->
        nil
    end
  end

  defp response_retry_after(_response), do: nil

  defp normalize_response({:ok, %{status: 200, body: body} = response}, path, max_response_bytes)
       when is_binary(body) and byte_size(body) <= max_response_bytes do
    fetched_at = now()

    snapshot = %{
      payload: body,
      content_type: response_content_type(response),
      fetched_at: fetched_at,
      metadata: %{"endpoint" => path, "status" => 200}
    }

    {:ok, body, snapshot}
  end

  defp normalize_response({:ok, %{status: 200}}, _path, _max_response_bytes),
    do: {:error, {:upstream, :response_too_large}}

  defp normalize_response({:ok, %{status: 404}}, _path, _max_response_bytes),
    do: {:error, :not_found}

  defp normalize_response({:ok, %{status: 429}}, _path, _max_response_bytes),
    do: {:error, :rate_limited}

  defp normalize_response({:local_error, :rate_limited}, _path, _max_response_bytes),
    do: {:error, :rate_limited}

  defp normalize_response({:ok, %{status: status}}, _path, _max_response_bytes),
    do: {:error, {:upstream, status}}

  defp normalize_response({:error, %{reason: reason}}, _path, _max_response_bytes)
       when reason in [:timeout, :closed],
       do: {:error, :timeout}

  defp normalize_response({:error, _reason}, _path, _max_response_bytes),
    do: {:error, {:upstream, :request_failed}}

  defp normalize_response(_other, _path, _max_response_bytes),
    do: {:error, {:upstream, :invalid_response}}

  defp response_content_type(%{headers: headers}) when is_map(headers) do
    headers
    |> Map.get("content-type", ["application/xml"])
    |> List.first()
  end

  defp response_content_type(_response), do: "application/xml"

  defp validate_window(from, until) do
    seconds = DateTime.diff(until, from, :second)

    cond do
      seconds <= 0 -> {:error, {:upstream, :invalid_time_window}}
      seconds > @max_window_hours * 3_600 -> {:error, {:upstream, :time_window_too_large}}
      true -> :ok
    end
  end

  defp covered_hours(from, until) do
    truncated = %{from | minute: 0, second: 0, microsecond: {0, 0}}

    Stream.iterate(truncated, &DateTime.add(&1, 3_600, :second))
    |> Enum.take_while(&(DateTime.compare(&1, until) == :lt))
  end

  defp journey_time(journey_id) do
    case Regex.run(~r/-(\d{10})-/, journey_id, capture: :all_but_first) do
      [value] ->
        case parse_db_time(value) do
          %DateTime{} = datetime -> {:ok, datetime}
          nil -> {:error, :not_found}
        end

      _no_match ->
        {:error, :not_found}
    end
  end

  defp parse_db_time(nil), do: nil

  defp parse_db_time(
         <<year::binary-size(2), month::binary-size(2), day::binary-size(2), hour::binary-size(2),
           minute::binary-size(2)>>
       ) do
    with {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day),
         {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         {:ok, naive} <- NaiveDateTime.new(2000 + year, month, day, hour, minute, 0) do
      berlin_naive_to_utc(naive)
    else
      _invalid -> nil
    end
  end

  defp parse_db_time(_value), do: nil

  defp berlin_naive_to_utc(naive) do
    offset = berlin_offset_for_local(naive)
    naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-offset, :second)
  end

  defp utc_to_berlin_naive(datetime) do
    offset = berlin_offset_for_utc(datetime)
    datetime |> DateTime.add(offset, :second) |> DateTime.to_naive()
  end

  defp berlin_offset_for_local(naive) do
    year = naive.year
    summer_start = NaiveDateTime.new!(last_sunday(year, 3), ~T[02:00:00])
    summer_end = NaiveDateTime.new!(last_sunday(year, 10), ~T[03:00:00])

    if NaiveDateTime.compare(naive, summer_start) != :lt and
         NaiveDateTime.compare(naive, summer_end) == :lt,
       do: 7_200,
       else: 3_600
  end

  defp berlin_offset_for_utc(datetime) do
    year = datetime.year
    summer_start = DateTime.new!(last_sunday(year, 3), ~T[01:00:00], "Etc/UTC")
    summer_end = DateTime.new!(last_sunday(year, 10), ~T[01:00:00], "Etc/UTC")

    if DateTime.compare(datetime, summer_start) != :lt and
         DateTime.compare(datetime, summer_end) == :lt,
       do: 7_200,
       else: 3_600
  end

  defp last_sunday(year, month) do
    last_day = Date.end_of_month(Date.new!(year, month, 1))
    Date.add(last_day, -rem(Date.day_of_week(last_day), 7))
  end

  defp split_path(nil), do: []
  defp split_path(path), do: String.split(path, "|", trim: true)

  defp station(name, eva), do: %{id: external_id(eva), name: name, eva_number: eva}
  defp external_id(value), do: %{provider: __MODULE__, value: value}

  defp normalize_parse_error(reason) when reason in [:unsafe_xml, :invalid_xml],
    do: {:upstream, :invalid_response}

  defp normalize_parse_error(reason), do: reason

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
