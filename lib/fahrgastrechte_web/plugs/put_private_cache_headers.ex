defmodule FahrgastrechteWeb.Plugs.PutPrivateCacheHeaders do
  @moduledoc """
  Verhindert, dass Browser oder gemeinsam genutzte Proxys authentifizierte
  Seiten zwischenspeichern.

  Anträge und Profile enthalten persönliche und finanzielle Daten. Deshalb
  werden alle Antworten der authentifizierten Browser-Pipeline ausdrücklich
  als nicht cachebar markiert.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    put_resp_header(conn, "cache-control", "private, no-store")
  end
end
