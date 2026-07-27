defmodule Fahrgastrechte.Rail.Provider do
  @moduledoc """
  Contract for timetable providers used by `Fahrgastrechte.Rail`.

  Provider-specific responses must be normalized before they cross this
  boundary. External identifiers are always namespaced with the provider
  module because identifiers are not interchangeable between upstream APIs.
  """

  @type external_id :: %{
          required(:provider) => module(),
          required(:value) => String.t()
        }

  @type station :: %{
          required(:id) => external_id(),
          required(:name) => String.t(),
          optional(:eva_number) => String.t(),
          optional(:location) => %{latitude: float(), longitude: float()}
        }

  @type event :: %{
          required(:station) => station(),
          optional(:scheduled_at) => DateTime.t(),
          optional(:estimated_at) => DateTime.t(),
          optional(:actual_at) => DateTime.t(),
          optional(:source_updated_at) => DateTime.t(),
          optional(:final) => boolean(),
          optional(:cancelled) => boolean(),
          optional(:platform) => String.t(),
          optional(:source_id) => external_id()
        }

  @type journey :: %{
          required(:id) => external_id(),
          required(:category) => String.t(),
          required(:number) => String.t(),
          required(:events) => [event()],
          required(:fetched_at) => DateTime.t()
        }

  @type connection_query :: %{
          required(:origin) => external_id(),
          required(:destination) => external_id(),
          required(:departure_at) => DateTime.t()
        }

  @type provider_error ::
          :history_unavailable
          | :not_found
          | :rate_limited
          | :timeout
          | :unsupported
          | {:upstream, term()}

  @type snapshot :: %{
          required(:payload) => binary(),
          required(:content_type) => String.t(),
          required(:fetched_at) => DateTime.t(),
          optional(:metadata) => map()
        }

  @type result(value) ::
          {:ok, value}
          | {:ok, value, snapshot()}
          | {:ok, value, [snapshot()]}
          | {:error, provider_error()}

  @doc "Finds stations and returns provider-neutral station records."
  @callback search_stations(query :: String.t(), options :: keyword()) ::
              result([station()])

  @doc """
  Finds complete start-to-destination connections when the upstream supports it.

  Providers that only expose station boards return `{:error, :unsupported}`.
  """
  @callback search_connections(query :: connection_query(), options :: keyword()) ::
              result([journey()])

  @doc "Loads departures for the half-open time window `from <= event < until`."
  @callback departures(
              station_id :: external_id(),
              from :: DateTime.t(),
              until :: DateTime.t(),
              options :: keyword()
            ) ::
              result([journey()])

  @doc "Loads one journey using the provider-specific, namespaced identifier."
  @callback journey(journey_id :: external_id(), options :: keyword()) ::
              result(journey())
end
