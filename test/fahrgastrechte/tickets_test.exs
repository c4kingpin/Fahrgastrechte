defmodule Fahrgastrechte.TicketsTest do
  use Fahrgastrechte.DataCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.DocumentsFixtures

  alias Fahrgastrechte.Repo
  alias Fahrgastrechte.TestFailingExtractor
  alias Fahrgastrechte.TestNoTextExtractor
  alias Fahrgastrechte.Tickets
  alias Fahrgastrechte.Tickets.PopplerExtractor

  setup do
    previous_config = Application.fetch_env!(:fahrgastrechte, Tickets)

    on_exit(fn ->
      Application.put_env(:fahrgastrechte, Tickets, previous_config)
    end)

    :ok
  end

  describe "Poppler extraction" do
    test "extracts traceable ticket proposals without confirming them" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, _claim} = document_fixture(scope, claim)

      assert {:ok, %{document: analyzed, suggestions: suggestions}} =
               Tickets.analyze_document(scope, document.id)

      assert analyzed.analysis_status == :completed
      assert analyzed.analysis_error == nil
      assert analyzed.analyzed_at

      by_field = Map.new(suggestions, &{&1.field, &1})
      assert by_field.order_number.value == %{"text" => "000000000001"}
      assert by_field.order_number.confidence == 0.98
      assert by_field.travel_date.value == %{"date" => "2026-04-15"}
      assert by_field.origin.value == %{"text" => "Teststadt Hbf"}
      assert by_field.destination.value == %{"text" => "Beispielstadt Hbf"}
      assert by_field.product.value == %{"text" => "Flexpreis"}
      assert by_field.fare.value == %{"amount" => "129.90", "currency" => "EUR"}

      assert by_field.scheduled_train.value == %{
               "category" => "ICE",
               "number" => "100"
             }

      assert by_field.scheduled_departure.value == %{
               "station" => "Teststadt Hbf",
               "time" => "08:04"
             }

      assert by_field.scheduled_arrival.value == %{
               "station" => "Beispielstadt Hbf",
               "time" => "12:10"
             }

      assert Enum.all?(suggestions, &(&1.state == :proposed))
      assert Enum.all?(suggestions, &(&1.source_page == 1))
      assert Enum.all?(suggestions, &(is_binary(&1.source_excerpt) and &1.source_excerpt != ""))
    end

    test "recognizes a validity period but invents no train from a tariff via" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      {document, _claim} =
        document_fixture(scope, claim, :ticket, %{
          path: fixture_path("synthetic-ticket-flexpreis-business.pdf")
        })

      assert {:ok, %{suggestions: suggestions}} = Tickets.analyze_document(scope, document.id)
      by_field = Map.new(suggestions, &{&1.field, &1})

      assert by_field.travel_date.value == %{"date" => "2026-04-14"}
      assert by_field.valid_until.value == %{"date" => "2026-04-18"}
      assert by_field.product.value == %{"text" => "Flexpreis Business"}
      refute Map.has_key?(by_field, :scheduled_train)
      refute Map.has_key?(by_field, :scheduled_departure)
      refute Map.has_key?(by_field, :scheduled_arrival)
    end

    test "extracts only explicitly assigned invoice values" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      {document, _claim} =
        document_fixture(scope, claim, :invoice, %{
          path: fixture_path("synthetic-invoice.pdf"),
          original_filename: "invoice.pdf"
        })

      assert {:ok, %{suggestions: suggestions}} = Tickets.analyze_document(scope, document.id)
      by_field = Map.new(suggestions, &{&1.field, &1})

      assert by_field.order_number.value == %{"text" => "000000000001"}
      assert by_field.fare.value == %{"amount" => "129.90", "currency" => "EUR"}
      refute Map.has_key?(by_field, :origin)
      refute Map.has_key?(by_field, :destination)
      refute Map.has_key?(by_field, :travel_date)
    end

    test "recognizes current DB ticket labels and layout" do
      extraction = %{
        text: """
        ICE Fahrkarte
        Flexpreis Aktion (Hinfahrt)
        Hinfahrt      Musterstadt+City     Beispielhausen(Sieg).
        Gesamtpreis 84,70 €. Gebucht am 27.07.2026 um 08:15 Uhr.
        DB Vertrieb ONLINE TICKET Auftragsnummer: 000000000001
        Ihre Reiseverbindung und Reservierung - Hinfahrt am 27.07.2026
        Musterstadt Hbf  Mo, 27.07. 08:04  7  ICE 100
        """,
        pages: 1,
        metadata: %{}
      }

      assert {:ok, suggestions} =
               PopplerExtractor.propose(extraction, document_kind: :ticket)

      by_field = Map.new(suggestions, &{&1.field, &1})
      assert by_field.order_number.value == %{"text" => "000000000001"}
      assert by_field.travel_date.value == %{"date" => "2026-07-27"}
      assert by_field.origin.value == %{"text" => "Musterstadt+City"}
      assert by_field.destination.value == %{"text" => "Beispielhausen(Sieg)"}
      assert by_field.product.value == %{"text" => "Flexpreis"}
      assert by_field.fare.value == %{"amount" => "84.70", "currency" => "EUR"}
      assert by_field.scheduled_train.value == %{"category" => "ICE", "number" => "100"}
    end

    test "recognizes current DB invoice header and gross total" do
      extraction = %{
        text: """
        12345 Berlin                                      Auftragsnummer: 000000000001
                                                          Rechnungsnummer: 2026-000000000001
                                                          Rechnungsdatum: 27.07.2026
        Rechnung
        zur Auftragsnummer 000000000001, Version 1
        Summe (netto)                                                   71,18 €
        zzgl. 19 % MwSt                                                 13,52 €
        Summe (brutto)                                                  84,70 €
        """,
        pages: 1,
        metadata: %{}
      }

      assert {:ok, suggestions} =
               PopplerExtractor.propose(extraction, document_kind: :invoice)

      by_field = Map.new(suggestions, &{&1.field, &1})
      assert by_field.order_number.value == %{"text" => "000000000001"}
      assert by_field.fare.value == %{"amount" => "84.70", "currency" => "EUR"}
      refute Map.has_key?(by_field, :scheduled_train)
      refute Map.has_key?(by_field, :travel_date)
    end

    test "reanalysis replaces prior suggestions as unconfirmed proposals" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, _claim} = document_fixture(scope, claim)

      {:ok, %{suggestions: first_suggestions}} = Tickets.analyze_document(scope, document.id)
      order_number = Enum.find(first_suggestions, &(&1.field == :order_number))
      assert {:ok, accepted} = Tickets.set_suggestion_state(scope, order_number.id, :accepted)
      assert accepted.state == :accepted

      assert {:ok, %{suggestions: second_suggestions}} =
               Tickets.analyze_document(scope, document.id)

      second_order_number = Enum.find(second_suggestions, &(&1.field == :order_number))
      assert second_order_number.id != order_number.id
      assert second_order_number.state == :proposed
    end
  end

  describe "manual fallback and failures" do
    test "textless extraction records the manual fallback without OCR" do
      set_extractor(TestNoTextExtractor)
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, _claim} = document_fixture(scope, claim)

      assert {:ok, %{document: analyzed, suggestions: []}} =
               Tickets.analyze_document(scope, document.id)

      assert analyzed.analysis_status == :manual_required
      assert analyzed.analysis_error == "no_text"
      assert {:ok, []} = Tickets.list_suggestions(scope, document.id)
    end

    test "encrypted PDFs go directly to manual fallback" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, _claim} = document_fixture(scope, claim)

      document
      |> Ecto.Changeset.change(encrypted: true)
      |> Repo.update!()

      assert {:ok, %{document: analyzed, suggestions: []}} =
               Tickets.analyze_document(scope, document.id)

      assert analyzed.analysis_status == :manual_required
      assert analyzed.analysis_error == "encrypted"
    end

    test "backend timeout is persisted as a retryable failed analysis" do
      set_extractor(TestFailingExtractor)
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, _claim} = document_fixture(scope, claim)

      assert {:ok, %{document: analyzed, suggestions: []}} =
               Tickets.analyze_document(scope, document.id)

      assert analyzed.analysis_status == :failed
      assert analyzed.analysis_error == "timeout"
    end

    test "generated documents are never treated as ticket inputs" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, _claim} = document_fixture(scope, claim, :generated_bundle)

      assert {:error, :invalid_document_kind} = Tickets.analyze_document(scope, document.id)
    end
  end

  describe "suggestion scoping" do
    test "user A cannot read, analyze or confirm user B's suggestions" do
      first_scope = scope_fixture()
      second_scope = scope_fixture()
      claim = claim_fixture(second_scope)
      {document, _claim} = document_fixture(second_scope, claim)
      {:ok, %{suggestions: suggestions}} = Tickets.analyze_document(second_scope, document.id)
      suggestion = hd(suggestions)

      assert {:error, :not_found} = Tickets.analyze_document(first_scope, document.id)
      assert {:error, :not_found} = Tickets.list_suggestions(first_scope, document.id)

      assert {:error, :not_found} =
               Tickets.set_suggestion_state(first_scope, suggestion.id, :accepted)

      assert {:error, :not_found} =
               Tickets.set_suggestion_states(
                 first_scope,
                 Enum.map(suggestions, & &1.id),
                 :accepted
               )

      assert {:ok, accepted} =
               Tickets.set_suggestion_state(second_scope, suggestion.id, "accepted")

      assert accepted.state == :accepted

      assert {:error, :invalid_state} =
               Tickets.set_suggestion_state(second_scope, suggestion.id, "invented")

      assert {:ok, rejected} =
               Tickets.set_suggestion_states(
                 second_scope,
                 Enum.map(suggestions, & &1.id),
                 :rejected
               )

      assert Enum.all?(rejected, &(&1.state == :rejected))
    end

    test "requires current_scope" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, _claim} = document_fixture(scope, claim)

      assert {:error, :not_authenticated} = Tickets.analyze_document(nil, document.id)
      assert {:error, :not_authenticated} = Tickets.list_suggestions(nil, document.id)
      assert {:error, :not_authenticated} = Tickets.set_suggestion_state(nil, "id", :accepted)

      assert {:error, :not_authenticated} =
               Tickets.set_suggestion_states(nil, ["id"], :accepted)
    end
  end

  defp set_extractor(module) do
    config = Application.fetch_env!(:fahrgastrechte, Tickets)
    Application.put_env(:fahrgastrechte, Tickets, Keyword.put(config, :extractor, module))
  end
end
