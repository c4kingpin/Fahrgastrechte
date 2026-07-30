defmodule FahrgastrechteWeb.Plugs.RequireCanonicalHost do
  @moduledoc false

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    case Application.get_env(:fahrgastrechte, :canonical_host) do
      expected_host when is_binary(expected_host) ->
        if String.downcase(conn.host) == String.downcase(expected_host) do
          conn
        else
          conn
          |> send_resp(:misdirected_request, "Misdirected Request")
          |> halt()
        end

      _other ->
        conn
    end
  end
end
