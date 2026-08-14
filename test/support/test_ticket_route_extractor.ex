defmodule Fahrgastrechte.TestTicketRouteExtractor do
  @behaviour Fahrgastrechte.Tickets.Extractor

  @impl true
  def extract(_path, _options), do: {:ok, %{text: "ticket", pages: 1, metadata: %{}}}

  @impl true
  def propose(_extraction, _options) do
    {:ok,
     [
       suggestion(:origin, "Hannover+City"),
       suggestion(:destination, "Frankfurt(M)Flugh. mit ICE")
     ]}
  end

  defp suggestion(field, text) do
    %{
      field: field,
      value: %{"text" => text},
      confidence: 0.95,
      source: %{page: 1, excerpt: text}
    }
  end
end
