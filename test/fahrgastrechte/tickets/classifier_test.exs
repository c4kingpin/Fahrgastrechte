defmodule Fahrgastrechte.Tickets.ClassifierTest do
  use ExUnit.Case, async: true

  alias Fahrgastrechte.Tickets.Classifier

  test "classifies ticket text from its fare and route markers" do
    text = """
    SYNTHETISCHES TESTTICKET - NICHT GUELTIG
    Produkt: Flexpreis
    Auftragsnummer: 000000000001
    Geltungstag: 15.04.2026
    Von: Teststadt Hbf
    Nach: Beispielstadt Hbf
    Reiseplan (nicht zuggebunden): ICE 100
    Teststadt Hbf ab 08:04
    Beispielstadt Hbf an 12:10
    Fahrpreis: 129,90 EUR
    """

    assert {:ok, :ticket, confidence} = Classifier.classify(text)
    assert confidence > 0.5
  end

  test "classifies invoice text from its billing markers" do
    text = """
    SYNTHETISCHE RECHNUNG - KEIN ECHTER BELEG
    Rechnungsnummer: TEST-2026-0001
    Auftragsnummer: 000000000001
    Leistung: Flexpreis Teststadt - Beispielstadt
    Leistungsdatum: 15.04.2026
    Gesamtbetrag: 129,90 EUR
    Zahlstatus: TESTDATEN
    """

    assert {:ok, :invoice, confidence} = Classifier.classify(text)
    assert confidence > 0.5
  end

  test "returns ambiguous for text without discriminating markers" do
    assert {:error, :ambiguous} = Classifier.classify("Nur ein belangloser Textabschnitt.")
  end

  test "returns ambiguous when both kinds score equally" do
    text = "Fahrpreis: 1,00 EUR\nGesamtbetrag: 1,00 EUR"

    assert {:error, :ambiguous} = Classifier.classify(text)
  end
end
