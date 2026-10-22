defmodule FahrgastrechteWeb.LiveSandbox do
  @moduledoc """
  Lets a LiveView process join the SQL sandbox of the browser test that opened it.

  `Phoenix.Ecto.SQL.Sandbox` covers plain HTTP requests; LiveView processes
  are spawned by the socket and need the same allowance, which the test
  browser passes along in its user agent. The router mounts this hook only
  when `:sql_sandbox` is set at compile time, i.e. in the test environment.
  """

  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    socket =
      Phoenix.Component.assign_new(socket, :phoenix_ecto_sandbox, fn ->
        if connected?(socket), do: get_connect_info(socket, :user_agent)
      end)

    Phoenix.Ecto.SQL.Sandbox.allow(socket.assigns.phoenix_ecto_sandbox, Ecto.Adapters.SQL.Sandbox)
    {:cont, socket}
  end
end
