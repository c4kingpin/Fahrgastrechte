defmodule Fahrgastrechte.Rail.Providers.OpenStation do
  @moduledoc """
  Bulk HTTP client for DB InfraGO's OpenStation API.

  OpenStation has no name-search endpoint: `/netex` is a paginated export of
  the entire German station network (CC0, DB InfraGO). Because there is no
  way to ask it for "stations near X", `Fahrgastrechte.Rail.StationCatalogSync`
  walks every page through `fetch_page/2` to build the local, searchable
  `stations` table that `Fahrgastrechte.Rail.Providers.StationCatalog`
  answers suggestions from.
  """

  alias Fahrgastrechte.Rail.Providers.XML

  @default_base_url "https://apis.deutschebahn.com/db-api-marketplace/apis/open-station/v1"
  @default_limit 100

  @doc """
  Fetches and parses one page of the station catalog.

  Returns `{:ok, stations, has_next?}`, where `stations` is a list of
  `%{name:, eva_number:, dhid:, stop_place_type:, transport_mode:}` maps
  (entries missing a name or EVA number are dropped) and `has_next?` reflects
  whether the response's `Link` header advertises a `rel="next"` page.
  """
  @spec fetch_page(pos_integer(), keyword()) :: {:ok, [map()], boolean()} | {:error, term()}
  def fetch_page(page, options \\ []) when is_integer(page) and page > 0 do
    with {:ok, body, headers} <- request(page, options) do
      case XML.parse(body) do
        {:ok, root} -> {:ok, parse_stations(root), has_next_page?(headers)}
        {:error, reason} -> {:error, {:upstream, reason}}
      end
    end
  end

  defp parse_stations(root) do
    root
    |> XML.elements("//*[local-name()='StopPlace']")
    |> Enum.flat_map(&parse_stop_place/1)
  end

  defp parse_stop_place(stop_place) do
    name = stop_place |> direct_child("Name") |> XML.text()
    eva_number = key_value(stop_place, "EVA")

    if is_binary(name) and name != "" and is_binary(eva_number) and eva_number != "" do
      [
        %{
          name: name,
          eva_number: eva_number,
          dhid: XML.attr(stop_place, :id),
          stop_place_type: stop_place |> direct_child("StopPlaceType") |> XML.text(),
          transport_mode: stop_place |> direct_child("TransportMode") |> XML.text()
        }
      ]
    else
      []
    end
  end

  defp key_value(stop_place, key) do
    stop_place
    |> XML.elements("./*[local-name()='keyList']/*[local-name()='KeyValue']")
    |> Enum.find_value(fn key_value ->
      if key_value |> direct_child("Key") |> XML.text() == key do
        key_value |> direct_child("Value") |> XML.text()
      end
    end)
  end

  defp direct_child(element, local_name) do
    element
    |> XML.elements("./*[local-name()='#{local_name}']")
    |> List.first()
  end

  defp has_next_page?(headers) do
    headers
    |> Map.get("link", [])
    |> Enum.any?(&String.contains?(&1, ~s(rel="next")))
  end

  defp request(page, options) do
    config = Application.get_env(:fahrgastrechte, __MODULE__, [])
    client_id = Keyword.get(options, :client_id, Keyword.get(config, :client_id))
    api_key = Keyword.get(options, :api_key, Keyword.get(config, :api_key))

    if blank?(client_id) or blank?(api_key) do
      {:error, {:upstream, :not_configured}}
    else
      request_options = [
        url:
          Keyword.get(options, :base_url, Keyword.get(config, :base_url, @default_base_url)) <>
            "/netex",
        params: [
          page: page,
          limit: Keyword.get(options, :limit, @default_limit),
          includeSitePathLinks: false
        ],
        headers: [{"DB-Client-Id", client_id}, {"DB-Api-Key", api_key}],
        receive_timeout: Keyword.get(options, :receive_timeout, 30_000),
        retry: false
      ]

      request_fun = Keyword.get(options, :request_fun, &Req.get/1)
      normalize_response(request_fun.(request_options))
    end
  end

  defp normalize_response({:ok, %{status: 200, body: body, headers: headers}})
       when is_binary(body),
       do: {:ok, body, headers}

  defp normalize_response({:ok, %{status: 429}}), do: {:error, :rate_limited}
  defp normalize_response({:ok, %{status: status}}), do: {:error, {:upstream, status}}

  defp normalize_response({:error, %{reason: reason}}) when reason in [:timeout, :closed],
    do: {:error, :timeout}

  defp normalize_response({:error, _reason}), do: {:error, {:upstream, :request_failed}}

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")
end
