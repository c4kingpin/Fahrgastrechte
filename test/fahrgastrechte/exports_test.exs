defmodule Fahrgastrechte.ExportsTest do
  use Fahrgastrechte.DataCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.DocumentsFixtures
  import Fahrgastrechte.ExportsFixtures
  import Fahrgastrechte.RailFixtures

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Documents.LocalStorage
  alias Fahrgastrechte.Exports
  alias Fahrgastrechte.Exports.ExportVersion
  alias Fahrgastrechte.Rail
  alias Fahrgastrechte.Repo
  alias Fahrgastrechte.Tickets

  setup do
    previous_backend_config =
      Application.get_env(:fahrgastrechte, Fahrgastrechte.TestPDFBackend, [])

    Application.put_env(:fahrgastrechte, Fahrgastrechte.TestPDFBackend, test_pid: self())

    on_exit(fn ->
      Application.put_env(
        :fahrgastrechte,
        Fahrgastrechte.TestPDFBackend,
        previous_backend_config
      )
    end)

    :ok
  end

  describe "generate_export/3" do
    test "publishes a versioned ready bundle in cover, form, ticket and invoice order" do
      scope = scope_fixture()
      claim = export_ready_fixture(scope)
      {:ok, documents} = Documents.list_documents(scope, claim.id)
      ticket = Enum.find(documents, &(&1.kind == :ticket))
      {:ok, %{suggestions: suggestions}} = Tickets.analyze_document(scope, ticket.id)
      order_number = Enum.find(suggestions, &(&1.field == :order_number))
      {:ok, _accepted} = Tickets.set_suggestion_state(scope, order_number.id, :accepted)

      assert {:ok, %{export: export, claim: ready}} =
               Exports.generate_export(scope, claim.id, claim.lock_version)

      cleanup_export(export)

      assert ready.status == :ready
      assert ready.generated_at
      assert export.version == 1
      assert export.template_version == "synthetic-test-template-v1"
      assert byte_size(export.template_sha256) == 32
      assert byte_size(export.model_sha256) == 32

      assert_receive {:pdf_backend_fields, fields}
      fields = Map.new(fields)
      assert fields["journey"] == "Verspätung am Ziel (mind. 60 Minuten)"
      assert fields["planned_departure_station"] == "Berlin Hbf"
      assert fields["planned_destination_station"] == "Hamburg Hbf"
      assert fields["ticket_digital_number"] == "000000000001"
      assert fields["arrived_hours"] == "11"
      assert fields["compensation"] == "Geldauszahlung/Überweisung"
      assert fields["compensation_iban"] == "DE89370400440532013000"
      refute Map.has_key?(fields, "signature")
      refute Enum.any?(Map.keys(fields), &String.contains?(&1, "market"))

      assert {:ok, %{document: bundle}} = Exports.stream_bundle(scope, export.id)
      assert bundle.id == export.bundle_document_id

      assert :ok =
               Documents.with_document_path(scope, bundle.id, fn path, _document ->
                 {info, 0} = System.cmd("pdfinfo", [path], stderr_to_stdout: true)
                 assert info =~ "Pages:           4"

                 {text, 0} = System.cmd("pdftotext", [path, "-"], stderr_to_stdout: true)

                 assert_order(text, [
                   "Fahrgastrechte-Antrag",
                   "SYNTHETISCHES TESTTICKET",
                   "SYNTHETISCHE RECHNUNG"
                 ])

                 :ok
               end)

      assert {:ok, [listed]} = Exports.list_exports(scope, claim.id)
      assert listed.id == export.id
    end

    test "supports a cancelled first train and a manually confirmed replacement" do
      scope = scope_fixture()
      {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())

      claim =
        claim_fixture(scope, %{
          "journey_outcome" => "delayed_arrival",
          "disruption_cause" => "cancellation"
        })

      {_ticket, claim} = document_fixture(scope, claim)

      {_invoice, claim} =
        document_fixture(scope, claim, :invoice, %{
          path: fixture_path("synthetic-invoice.pdf"),
          original_filename: "invoice.pdf"
        })

      {:ok, _result} =
        Rail.confirm_journey(
          scope,
          claim.id,
          :planned,
          [segment_attributes()],
          claim.lock_version
        )

      cancelled =
        segment_attributes(%{
          destination_name: "Hannover Hbf",
          scheduled_arrival: ~U[2026-07-15 07:30:00Z],
          actual_departure: nil,
          actual_arrival: nil,
          cancelled: true
        })

      replacement =
        segment_attributes(%{
          origin_name: "Hannover Hbf",
          train_number: "200",
          scheduled_departure: ~U[2026-07-15 07:40:00Z],
          actual_departure: ~U[2026-07-15 08:00:00Z],
          actual_arrival: ~U[2026-07-15 09:15:00Z],
          manual: true,
          source: "manual"
        })

      {:ok, _result} =
        Rail.confirm_journey(
          scope,
          claim.id,
          :actual,
          [cancelled, replacement],
          claim.lock_version
        )

      assert {:ok, %{export: export}} =
               Exports.generate_export(scope, claim.id, claim.lock_version)

      cleanup_export(export)
      assert_receive {:pdf_backend_fields, fields}
      fields = Map.new(fields)
      assert fields["journey"] == "Verspätung am Ziel (mind. 60 Minuten)"
      assert fields["arrived_hours"] == "11"
      assert fields["arrived_minutes"] == "15"
    end

    test "reports structured prerequisites and keeps an incomplete claim as draft" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:error, %{type: :incomplete, errors: errors}} =
               Exports.generate_export(scope, claim.id, claim.lock_version)

      assert %{source: :profile, field: :salutation, code: :required} in errors
      assert %{source: :rail, field: :planned_segments, code: :required} in errors
      assert %{source: :documents, field: :ticket, code: :required} in errors
      assert %{source: :documents, field: :invoice, code: :required} in errors
      assert {:ok, unchanged} = Claims.get_claim(scope, claim.id)
      assert unchanged.status == :draft
      assert unchanged.generated_at == nil
      assert Repo.aggregate(ExportVersion, :count) == 0
    end

    test "a tool failure leaves no generated metadata, files or ready transition" do
      scope = scope_fixture()
      claim = export_ready_fixture(scope)

      Application.put_env(:fahrgastrechte, Fahrgastrechte.TestPDFBackend,
        test_pid: self(),
        fail_on: :merge
      )

      assert {:error, {:command_failed, "merge"}} =
               Exports.generate_export(scope, claim.id, claim.lock_version)

      assert {:ok, documents} = Documents.list_documents(scope, claim.id)
      assert Enum.sort(Enum.map(documents, & &1.kind)) == [:invoice, :ticket]
      assert Repo.aggregate(ExportVersion, :count) == 0
      assert {:ok, unchanged} = Claims.get_claim(scope, claim.id)
      assert unchanged.status == :draft
    end

    test "rejects a changed template checksum before rendering" do
      scope = scope_fixture()
      claim = export_ready_fixture(scope)
      exports_config = Application.fetch_env!(:fahrgastrechte, Exports)

      Application.put_env(
        :fahrgastrechte,
        Exports,
        Keyword.put(exports_config, :template_sha256, :crypto.strong_rand_bytes(32))
      )

      on_exit(fn -> Application.put_env(:fahrgastrechte, Exports, exports_config) end)

      assert {:error, :template_changed} =
               Exports.generate_export(scope, claim.id, claim.lock_version)
    end
  end

  describe "template manifest contract" do
    test "uses every official outcome radio value and both directions" do
      scope = scope_fixture()

      cases = [
        {:delayed_arrival, :outbound, "Verspätung am Ziel (mind. 60 Minuten)", true},
        {:not_started, :return,
         "Reise nicht angetreten (Zugausfall oder erwartete Verspätung am Ziel von mind. 60 Minuten)",
         false},
        {:aborted, :outbound, "Reise unterwegs abgebrochen und zurück zum Startbahnhof", false},
        {:continued_with_other_transport, :return,
         "Reise unterbrochen und mit anderem Verkehrsmittel fortgesetzt, für das Zusatzkosten entstanden sind",
         true}
      ]

      for {outcome, direction, expected_radio, arrival_expected?} <- cases do
        claim =
          export_ready_fixture(scope, %{
            "journey_outcome" => Atom.to_string(outcome),
            "journey_direction" => Atom.to_string(direction)
          })

        assert {:ok, _profile} =
                 Accounts.update_profile(
                   scope,
                   valid_profile_attributes(%{
                     "title" => "Dr.",
                     "phone_number" => "+49 30 123456"
                   })
                 )

        assert {:ok, %{export: export}} =
                 Exports.generate_export(scope, claim.id, claim.lock_version)

        cleanup_export(export)
        assert_receive {:pdf_backend_fields, fields}
        fields = Map.new(fields)

        assert fields["journey"] == expected_radio
        assert fields["planned_direction"] == direction_radio(direction)
        assert fields["personal"] == "Neutrale Anrede"
        assert Map.has_key?(fields, "arrived_hours") == arrival_expected?
        refute Map.has_key?(fields, "signature")
        refute Map.has_key?(fields, "personal_title")
        refute Map.has_key?(fields, "personal_phone")
        refute Map.has_key?(fields, "personal_country")
      end
    end
  end

  describe "version history and scope isolation" do
    test "claim deletion cascades version metadata after removing all private files" do
      scope = scope_fixture()
      claim = export_ready_fixture(scope)

      assert {:ok, %{export: export, claim: ready}} =
               Exports.generate_export(scope, claim.id, claim.lock_version)

      output_documents =
        Enum.map(
          [export.cover_document_id, export.form_document_id, export.bundle_document_id],
          &Repo.get!(Fahrgastrechte.Documents.Document, &1)
        )

      assert {:ok, _deleted_claim} =
               Documents.delete_claim(scope, claim.id, ready.lock_version)

      assert Repo.aggregate(ExportVersion, :count) == 0
      assert Enum.all?(output_documents, &(not LocalStorage.exists?(&1.storage_key)))
    end

    test "keeps old output immutable and denies foreign reads and downloads" do
      owner_scope = scope_fixture()
      foreign_scope = scope_fixture()
      claim = export_ready_fixture(owner_scope)

      assert {:ok, %{export: first, claim: ready}} =
               Exports.generate_export(owner_scope, claim.id, claim.lock_version)

      cleanup_export(first)

      assert {:ok, draft} =
               Claims.update_claim(
                 owner_scope,
                 claim.id,
                 %{"destination" => "Bremen Hbf"},
                 ready.lock_version
               )

      assert draft.status == :draft

      assert {:ok, %{export: second}} =
               Exports.generate_export(owner_scope, claim.id, draft.lock_version)

      cleanup_export(second)

      assert second.version == 2
      assert {:ok, [^first, ^second]} = Exports.list_exports(owner_scope, claim.id)

      assert {:ok, historical_bundle} =
               Documents.get_document(owner_scope, first.bundle_document_id)

      refute historical_bundle.current
      assert {:ok, _stream} = Exports.stream_bundle(owner_scope, first.id)

      assert {:error, :not_found} = Exports.get_export(foreign_scope, first.id)
      assert {:error, :not_found} = Exports.stream_bundle(foreign_scope, first.id)
      assert {:error, :not_found} = Exports.list_exports(foreign_scope, claim.id)
    end

    test "requires current_scope" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:error, :not_authenticated} = Exports.generate_export(nil, claim.id, 1)
      assert {:error, :not_authenticated} = Exports.list_exports(nil, claim.id)
      assert {:error, :not_authenticated} = Exports.get_export(nil, Ecto.UUID.generate())
      assert {:error, :not_authenticated} = Exports.stream_bundle(nil, Ecto.UUID.generate())
    end
  end

  defp direction_radio(:outbound), do: "Hinfahrt"
  defp direction_radio(:return), do: "Rückfahrt"

  defp cleanup_export(export) do
    on_exit(fn ->
      for document_id <- [
            export.cover_document_id,
            export.form_document_id,
            export.bundle_document_id
          ],
          document when not is_nil(document) <-
            [Repo.get(Fahrgastrechte.Documents.Document, document_id)] do
        LocalStorage.delete(document.storage_key)
      end
    end)
  end

  defp assert_order(text, expected_values) do
    positions =
      Enum.map(expected_values, fn expected ->
        {position, _length} = :binary.match(text, expected)
        position
      end)

    assert positions == Enum.sort(positions)
  end
end
