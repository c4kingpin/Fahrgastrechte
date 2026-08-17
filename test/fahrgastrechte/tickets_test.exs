defmodule Fahrgastrechte.TicketsTest do
  use Fahrgastrechte.DataCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.DocumentsFixtures

  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Documents.PDFJobLimiter
  alias Fahrgastrechte.Repo
  alias Fahrgastrechte.TestFailingExtractor
  alias Fahrgastrechte.TestNoTextExtractor
  alias Fahrgastrechte.TestStationProvider
  alias Fahrgastrechte.TestTicketRouteExtractor
  alias Fahrgastrechte.Tickets
  alias Fahrgastrechte.Tickets.PopplerExtractor

  setup do
    previous_config = Application.fetch_env!(:fahrgastrechte, Tickets)
    previous_rail_config = Application.fetch_env!(:fahrgastrechte, Fahrgastrechte.Rail)

    on_exit(fn ->
      Application.put_env(:fahrgastrechte, Tickets, previous_config)
      Application.put_env(:fahrgastrechte, Fahrgastrechte.Rail, previous_rail_config)
    end)

    :ok
  end

  describe "Poppler extraction" do
    test "extracts traceable ticket proposals without confirming them" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      assert {:ok, %{document: analyzed, suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      assert analyzed.analysis_status == :completed
      assert analyzed.analysis_error == nil
      assert analyzed.analyzed_at

      by_field = Map.new(suggestions, &{&1.field, &1})
      assert by_field.order_number.value == %{"text" => "000000000001"}
      assert by_field.order_number.confidence == 0.98
      assert by_field.travel_date.value == %{"date" => "2026-04-15"}
      # Neither test station resolves against TestStationProvider, so the
      # normalizer keeps the raw text but flags it unresolved.
      assert by_field.origin.value == %{"text" => "Teststadt Hbf", "unresolved" => true}

      assert by_field.destination.value == %{
               "text" => "Beispielstadt Hbf",
               "unresolved" => true
             }

      assert by_field.product.value == %{"text" => "Flexpreis"}
      assert by_field.fare.value == %{"amount" => "129.90", "currency" => "EUR"}

      assert by_field.scheduled_train.value == %{
               "category" => "ICE",
               "number" => "100"
             }

      assert by_field.scheduled_departure.value == %{
               "station" => "Teststadt Hbf",
               "time" => "08:04",
               "unresolved" => true
             }

      assert by_field.scheduled_arrival.value == %{
               "station" => "Beispielstadt Hbf",
               "time" => "12:10",
               "unresolved" => true
             }

      assert Enum.all?(suggestions, &(&1.state == :proposed))
      assert Enum.all?(suggestions, &(&1.source_page == 1))
      assert Enum.all?(suggestions, &(is_binary(&1.source_excerpt) and &1.source_excerpt != ""))
    end

    test "recognizes a validity period but invents no train from a tariff via" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      {document, claim} =
        document_fixture(scope, claim, :ticket, %{
          path: fixture_path("synthetic-ticket-flexpreis-business.pdf")
        })

      assert {:ok, %{suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

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

      {document, claim} =
        document_fixture(scope, claim, :invoice, %{
          path: fixture_path("synthetic-invoice.pdf"),
          original_filename: "invoice.pdf"
        })

      assert {:ok, %{suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

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

    test "replaces ticket route labels with canonical station names from the rail provider" do
      set_extractor(TestTicketRouteExtractor)
      set_rail_provider(TestStationProvider)
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      assert {:ok, %{suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      by_field = Map.new(suggestions, &{&1.field, &1})

      assert by_field.origin.value == %{
               "text" => "Hannover Hbf",
               "station_id" => %{provider: TestStationProvider, value: "8000152"}
             }

      assert by_field.destination.value == %{
               "text" => "Frankfurt(M) Flughafen Fernbf",
               "station_id" => %{provider: TestStationProvider, value: "8070004"}
             }
    end

    test "reanalysis replaces prior suggestions as unconfirmed proposals" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      {:ok, %{suggestions: first_suggestions}} =
        Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      order_number = Enum.find(first_suggestions, &(&1.field == :order_number))

      assert {:ok, accepted} =
               Tickets.set_suggestion_state(
                 scope,
                 claim.id,
                 order_number.id,
                 :accepted,
                 claim.lock_version
               )

      assert accepted.state == :accepted

      assert {:ok, %{suggestions: second_suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      second_order_number = Enum.find(second_suggestions, &(&1.field == :order_number))
      assert second_order_number.id != order_number.id
      assert second_order_number.state == :proposed
    end

    test "reclassifying a misfiled document then reanalyzing yields kind-appropriate suggestions" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      {document, claim} =
        document_fixture(scope, claim, :ticket, %{
          path: fixture_path("synthetic-invoice.pdf"),
          original_filename: "invoice.pdf"
        })

      assert {:ok, %{document: %{kind: :invoice}, claim: claim}} =
               Documents.change_document_kind(
                 scope,
                 claim.id,
                 document.id,
                 :invoice,
                 claim.lock_version
               )

      assert {:ok, %{suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      by_field = Map.new(suggestions, &{&1.field, &1})
      assert by_field.order_number.value == %{"text" => "000000000001"}
      assert by_field.fare.value == %{"amount" => "129.90", "currency" => "EUR"}
      refute Map.has_key?(by_field, :origin)
      refute Map.has_key?(by_field, :destination)
      refute Map.has_key?(by_field, :travel_date)
    end
  end

  describe "manual fallback and failures" do
    test "textless extraction records the manual fallback without OCR" do
      set_extractor(TestNoTextExtractor)
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      assert {:ok, %{document: analyzed, suggestions: []}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      assert analyzed.analysis_status == :manual_required
      assert analyzed.analysis_error == "no_text"
      assert {:ok, []} = Tickets.list_suggestions(scope, document.id)
    end

    test "encrypted PDFs go directly to manual fallback" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      document
      |> Ecto.Changeset.change(encrypted: true)
      |> Repo.update!()

      assert {:ok, %{document: analyzed, suggestions: []}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      assert analyzed.analysis_status == :manual_required
      assert analyzed.analysis_error == "encrypted"
    end

    test "backend timeout is persisted as a retryable failed analysis" do
      set_extractor(TestFailingExtractor)
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      assert {:ok, %{document: analyzed, suggestions: []}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      assert analyzed.analysis_status == :failed
      assert analyzed.analysis_error == "timeout"
    end

    test "confirming the manual fallback after a failed analysis unblocks the claim" do
      set_extractor(TestFailingExtractor)
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      assert {:ok, %{document: failed}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      assert failed.analysis_status == :failed
      assert is_nil(failed.manual_fallback_confirmed_at)

      assert {:ok, confirmed} =
               Tickets.confirm_manual_fallback(scope, claim.id, document.id, claim.lock_version)

      assert confirmed.analysis_status == :failed
      assert %DateTime{} = confirmed.manual_fallback_confirmed_at
    end

    test "confirming the manual fallback is rejected outside a failed analysis" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      assert {:ok, %{document: completed}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      assert completed.analysis_status == :completed

      assert {:error, :invalid_state} =
               Tickets.confirm_manual_fallback(scope, claim.id, document.id, claim.lock_version)
    end

    test "re-analyzing after a confirmed manual fallback requires a fresh confirmation" do
      set_extractor(TestFailingExtractor)
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      assert {:ok, %{document: _failed}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      assert {:ok, _confirmed} =
               Tickets.confirm_manual_fallback(scope, claim.id, document.id, claim.lock_version)

      assert {:ok, %{document: reanalyzed}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      assert reanalyzed.analysis_status == :failed
      assert is_nil(reanalyzed.manual_fallback_confirmed_at)
    end

    test "generated documents are never treated as ticket inputs" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim, :generated_bundle)

      assert {:error, :invalid_document_kind} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)
    end
  end

  describe "suggestion scoping" do
    test "loads all current claim suggestions through one scoped read" do
      scope = scope_fixture()
      foreign_scope = scope_fixture()
      claim = claim_fixture(scope)
      {ticket, claim} = document_fixture(scope, claim, :ticket)
      {invoice, claim} = document_fixture(scope, claim, :invoice)

      assert {:ok, %{suggestions: ticket_suggestions}} =
               Tickets.analyze_document(scope, claim.id, ticket.id, claim.lock_version)

      assert {:ok, %{suggestions: invoice_suggestions}} =
               Tickets.analyze_document(scope, claim.id, invoice.id, claim.lock_version)

      assert {:ok, suggestions} = Tickets.list_claim_suggestions(scope, claim.id)

      assert Enum.sort(Enum.map(suggestions, & &1.id)) ==
               Enum.sort(Enum.map(ticket_suggestions ++ invoice_suggestions, & &1.id))

      assert {:error, :not_found} = Tickets.list_claim_suggestions(foreign_scope, claim.id)
      assert {:error, :not_authenticated} = Tickets.list_claim_suggestions(nil, claim.id)
    end

    test "user A cannot read, analyze or confirm user B's suggestions" do
      first_scope = scope_fixture()
      second_scope = scope_fixture()
      claim = claim_fixture(second_scope)
      {document, claim} = document_fixture(second_scope, claim)

      {:ok, %{suggestions: suggestions}} =
        Tickets.analyze_document(second_scope, claim.id, document.id, claim.lock_version)

      suggestion = hd(suggestions)

      assert {:error, :not_found} =
               Tickets.analyze_document(first_scope, claim.id, document.id, claim.lock_version)

      assert {:error, :not_found} = Tickets.list_suggestions(first_scope, document.id)

      assert {:error, :not_found} =
               Tickets.set_suggestion_state(
                 first_scope,
                 claim.id,
                 suggestion.id,
                 :accepted,
                 claim.lock_version
               )

      assert {:error, :not_found} =
               Tickets.set_suggestion_states(
                 first_scope,
                 claim.id,
                 Enum.map(suggestions, & &1.id),
                 :accepted,
                 claim.lock_version
               )

      assert {:ok, accepted} =
               Tickets.set_suggestion_state(
                 second_scope,
                 claim.id,
                 suggestion.id,
                 "accepted",
                 claim.lock_version
               )

      assert accepted.state == :accepted

      assert {:error, :invalid_state} =
               Tickets.set_suggestion_state(
                 second_scope,
                 claim.id,
                 suggestion.id,
                 "invented",
                 claim.lock_version
               )

      assert {:ok, rejected} =
               Tickets.set_suggestion_states(
                 second_scope,
                 claim.id,
                 Enum.map(suggestions, & &1.id),
                 :rejected,
                 claim.lock_version
               )

      assert Enum.all?(rejected, &(&1.state == :rejected))
    end

    test "rejects mutations bound to another claim owned by the same user" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      other_claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      {:ok, %{suggestions: suggestions}} =
        Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      suggestion = hd(suggestions)

      assert {:error, :not_found} =
               Tickets.analyze_document(
                 scope,
                 other_claim.id,
                 document.id,
                 other_claim.lock_version
               )

      assert {:error, :not_found} =
               Tickets.set_suggestion_state(
                 scope,
                 other_claim.id,
                 suggestion.id,
                 :rejected,
                 other_claim.lock_version
               )

      assert {:error, :not_found} =
               Tickets.set_suggestion_states(
                 scope,
                 other_claim.id,
                 [suggestion.id],
                 :rejected,
                 other_claim.lock_version
               )

      assert {:ok, [unchanged | _suggestions]} = Tickets.list_suggestions(scope, document.id)
      assert unchanged.state == :proposed
    end

    test "requires current_scope" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      assert {:error, :not_authenticated} =
               Tickets.analyze_document(nil, claim.id, document.id, claim.lock_version)

      assert {:error, :not_authenticated} = Tickets.list_suggestions(nil, document.id)

      assert {:error, :not_authenticated} =
               Tickets.set_suggestion_state(nil, claim.id, "id", :accepted, claim.lock_version)

      assert {:error, :not_authenticated} =
               Tickets.set_suggestion_states(nil, claim.id, ["id"], :accepted, claim.lock_version)
    end
  end

  describe "claim state invariants" do
    test "set_suggestion_states/5 rejects a stale lock_version" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      {:ok, %{suggestions: suggestions}} =
        Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      assert {:error, :stale} =
               Tickets.set_suggestion_states(
                 scope,
                 claim.id,
                 Enum.map(suggestions, & &1.id),
                 :accepted,
                 claim.lock_version + 1
               )
    end

    test "set_suggestion_states/5 rejects mutating a sent or completed claim" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      {:ok, %{suggestions: suggestions}} =
        Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      suggestion_ids = Enum.map(suggestions, & &1.id)

      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
      {:ok, sent} = Claims.transition_claim(scope, claim.id, :sent, ready.lock_version)

      assert {:error, :not_editable} =
               Tickets.set_suggestion_states(
                 scope,
                 claim.id,
                 suggestion_ids,
                 :accepted,
                 sent.lock_version
               )

      {:ok, completed} = Claims.transition_claim(scope, claim.id, :completed, sent.lock_version)

      assert {:error, :not_editable} =
               Tickets.set_suggestion_states(
                 scope,
                 claim.id,
                 suggestion_ids,
                 :accepted,
                 completed.lock_version
               )
    end

    test "set_suggestion_states/5 on a ready claim invalidates its output atomically" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      {:ok, %{suggestions: suggestions}} =
        Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)

      assert {:ok, updated} =
               Tickets.set_suggestion_states(
                 scope,
                 claim.id,
                 Enum.map(suggestions, & &1.id),
                 :accepted,
                 ready.lock_version
               )

      assert Enum.all?(updated, &(&1.state == :accepted))

      assert {:ok, reloaded} = Claims.get_claim(scope, claim.id)
      assert reloaded.status == :draft
      assert reloaded.generated_at == nil
    end

    test "analyze_document/4 rejects reanalysis of a sent claim" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, claim)

      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
      {:ok, sent} = Claims.transition_claim(scope, claim.id, :sent, ready.lock_version)

      assert {:error, :not_editable} =
               Tickets.analyze_document(scope, claim.id, document.id, sent.lock_version)
    end
  end

  describe "PDFJobLimiter integration" do
    test "classify_upload/1 reports :ambiguous instead of crashing when the shared limiter is busy" do
      test_pid = self()

      holders =
        for _ <- 1..2 do
          spawn(fn ->
            PDFJobLimiter.with_permit(fn ->
              send(test_pid, :holding)

              receive do
                :release -> :ok
              end
            end)
          end)
        end

      assert_receive :holding
      assert_receive :holding

      assert {:error, :ambiguous} = Tickets.classify_upload(fixture_path())

      Enum.each(holders, &send(&1, :release))
    end
  end

  defp set_extractor(module) do
    config = Application.fetch_env!(:fahrgastrechte, Tickets)
    Application.put_env(:fahrgastrechte, Tickets, Keyword.put(config, :extractor, module))
  end

  defp set_rail_provider(module) do
    config = Application.fetch_env!(:fahrgastrechte, Fahrgastrechte.Rail)

    Application.put_env(
      :fahrgastrechte,
      Fahrgastrechte.Rail,
      Keyword.put(config, :provider, module)
    )
  end
end
