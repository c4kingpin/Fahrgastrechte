defmodule Fahrgastrechte.Tickets.PopplerExtractorTest do
  use ExUnit.Case, async: true

  alias Fahrgastrechte.Tickets.PopplerExtractor

  describe "normalize_text/1" do
    test "folds fullwidth digits to their canonical ASCII form" do
      assert PopplerExtractor.normalize_text("１２３４５６７８９０１２") == "123456789012"
    end

    test "leaves plain ASCII text unchanged" do
      assert PopplerExtractor.normalize_text("Auftragsnummer: 123456789012") ==
               "Auftragsnummer: 123456789012"
    end
  end

  describe "propose/2" do
    test "extracts the same order number whether a document used ASCII or fullwidth digit glyphs" do
      ascii_extraction = %{text: "Auftragsnummer: 123456789012", pages: 1, metadata: %{}}

      fullwidth_extraction = %{
        text: PopplerExtractor.normalize_text("Auftragsnummer: １２３４５６７８９０１２"),
        pages: 1,
        metadata: %{}
      }

      assert {:ok, [ascii_suggestion]} =
               PopplerExtractor.propose(ascii_extraction, document_kind: :ticket)

      assert {:ok, [fullwidth_suggestion]} =
               PopplerExtractor.propose(fullwidth_extraction, document_kind: :invoice)

      assert ascii_suggestion.field == :order_number
      assert ascii_suggestion.value == fullwidth_suggestion.value
      assert ascii_suggestion.value == %{"text" => "123456789012"}
    end
  end
end
