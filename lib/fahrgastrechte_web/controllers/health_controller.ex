defmodule FahrgastrechteWeb.HealthController do
  use FahrgastrechteWeb, :controller

  alias Fahrgastrechte.Health

  def health(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def readiness(conn, _params) do
    case Health.ready() do
      :ok ->
        json(conn, %{status: "ready"})

      {:error, failed_checks} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "unavailable",
          failed_checks: Enum.map(failed_checks, &Atom.to_string/1)
        })
    end
  end
end
