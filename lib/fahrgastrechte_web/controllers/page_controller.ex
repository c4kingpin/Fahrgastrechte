defmodule FahrgastrechteWeb.PageController do
  use FahrgastrechteWeb, :controller

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Claims

  def home(conn, _params) do
    current_scope = conn.assigns.current_scope

    render(conn, :home,
      page_title: "Übersicht",
      dashboard_counts: dashboard_counts(current_scope),
      most_recent_claim: most_recent_claim(current_scope),
      profile_completeness: profile_completeness(current_scope)
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

  defp most_recent_claim(nil), do: nil

  defp most_recent_claim(current_scope) do
    case Claims.most_recent_claim(current_scope) do
      {:ok, claim} -> claim
      {:error, _reason} -> nil
    end
  end

  defp profile_completeness(nil), do: nil

  defp profile_completeness(current_scope) do
    case Accounts.profile_completeness(current_scope) do
      {:ok, completeness} -> completeness
      {:error, _reason} -> nil
    end
  end
end
