defmodule FahrgastrechteWeb.PageController do
  use FahrgastrechteWeb, :controller

  alias Fahrgastrechte.Claims

  def home(conn, _params) do
    render(conn, :home,
      page_title: "Übersicht",
      dashboard_counts: dashboard_counts(conn.assigns.current_scope)
    )
  end

  defp dashboard_counts(nil), do: %{total: 0, open: 0, completed: 0}

  defp dashboard_counts(current_scope) do
    case Claims.dashboard_counts(current_scope) do
      {:ok, counts} ->
        counts

      {:error, _reason} ->
        %{total: 0, open: 0, completed: 0}
    end
  end
end
