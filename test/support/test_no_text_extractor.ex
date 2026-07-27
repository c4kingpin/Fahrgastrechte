defmodule Fahrgastrechte.TestNoTextExtractor do
  @behaviour Fahrgastrechte.Tickets.Extractor

  @impl true
  def extract(_path, _options), do: {:error, :no_text}

  @impl true
  def propose(_extraction, _options), do: {:ok, []}
end
