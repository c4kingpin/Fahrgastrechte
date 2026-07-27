defmodule Fahrgastrechte.TestFailingExtractor do
  @behaviour Fahrgastrechte.Tickets.Extractor

  @impl true
  def extract(_path, _options), do: {:error, :timeout}

  @impl true
  def propose(_extraction, _options), do: {:ok, []}
end
