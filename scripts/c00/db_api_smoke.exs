required_environment = ["DB_CLIENT_ID", "DB_API_KEY"]

missing_environment =
  Enum.reject(required_environment, fn name ->
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      _other -> false
    end
  end)

if missing_environment != [] do
  IO.puts(:stderr, "missing environment: #{Enum.join(missing_environment, ", ")}")
  System.halt(2)
end

case Application.ensure_all_started(:req) do
  {:ok, _applications} ->
    :ok

  {:error, {application, reason}} ->
    IO.puts(:stderr, "failed_to_start=#{application}: #{inspect(reason)}")
    System.halt(1)
end

base_url =
  System.get_env(
    "DB_TIMETABLES_BASE_URL",
    "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1"
  )

url = "#{String.trim_trailing(base_url, "/")}/station/Berlin%20Hbf"

headers = [
  {"accept", "application/xml"},
  {"db-client-id", System.fetch_env!("DB_CLIENT_ID")},
  {"db-api-key", System.fetch_env!("DB_API_KEY")}
]

case Req.get(url,
       headers: headers,
       retry: false,
       receive_timeout: 5_000,
       connect_options: [timeout: 5_000]
     ) do
  {:ok, %Req.Response{status: 200, body: body} = response} when is_binary(body) ->
    content_type =
      response
      |> Req.Response.get_header("content-type")
      |> List.first()
      |> Kernel.||("unknown")

    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    IO.puts("status=200")
    IO.puts("content_type=#{content_type}")
    IO.puts("bytes=#{byte_size(body)}")
    IO.puts("sha256=#{digest}")

  {:ok, %Req.Response{status: status}} ->
    IO.puts(:stderr, "unexpected_status=#{status}")
    System.halt(1)

  {:error, exception} ->
    IO.puts(:stderr, "request_failed=#{Exception.message(exception)}")
    System.halt(1)
end
