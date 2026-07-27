defmodule Fahrgastrechte.C00BehavioursTest do
  use ExUnit.Case, async: true

  test "rail provider contract remains explicit" do
    assert callbacks(Fahrgastrechte.Rail.Provider) ==
             MapSet.new([
               {:departures, 4},
               {:journey, 2},
               {:search_connections, 2},
               {:search_stations, 2}
             ])
  end

  test "ticket extraction contract separates extraction and proposals" do
    assert callbacks(Fahrgastrechte.Tickets.Extractor) ==
             MapSet.new([{:extract, 2}, {:propose, 2}])
  end

  test "pdf backend contract covers the complete transformation boundary" do
    assert callbacks(Fahrgastrechte.Exports.PDFBackend) ==
             MapSet.new([
               {:extract_text, 2},
               {:fill_form, 4},
               {:merge, 3},
               {:normalize, 3},
               {:validate, 2}
             ])
  end

  defp callbacks(module) do
    module
    |> apply(:behaviour_info, [:callbacks])
    |> MapSet.new()
  end
end
