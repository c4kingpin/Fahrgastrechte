defmodule Fahrgastrechte.SystemPDFBackendTest do
  use ExUnit.Case, async: false

  alias Fahrgastrechte.Exports.CoverRenderer
  alias Fahrgastrechte.Exports.SystemPDFBackend

  setup do
    work_dir =
      Path.join(System.tmp_dir!(), "c05-system-backend-#{System.unique_integer([:positive])}")

    File.mkdir_p!(work_dir)
    File.chmod!(work_dir, 0o700)
    on_exit(fn -> File.rm_rf(work_dir) end)

    {:ok, work_dir: work_dir}
  end

  test "validates, sanitizes and merges printable A4 documents", %{work_dir: work_dir} do
    fixture = Path.expand("../fixtures/c00/synthetic-ticket-flexpreis.pdf", __DIR__)
    cover_path = Path.join(work_dir, "cover.pdf")
    normalized_path = Path.join(work_dir, "normalized.pdf")
    bundle_path = Path.join(work_dir, "bundle.pdf")
    options = backend_options()

    assert {:ok, %{pages: 1, encrypted: false}} =
             SystemPDFBackend.validate(fixture, options)

    assert :ok = CoverRenderer.render(cover_model(), cover_path)
    assert {:ok, %{pages: 1}} = SystemPDFBackend.validate(cover_path, options)
    assert :ok = SystemPDFBackend.normalize(fixture, normalized_path, options)

    assert {:ok, %{pages: 1}} =
             SystemPDFBackend.validate(normalized_path, Keyword.put(options, :inactive, true))

    assert :ok =
             SystemPDFBackend.merge([cover_path, normalized_path], bundle_path, options)

    assert {:ok, %{pages: 2, page_sizes: page_sizes}} =
             SystemPDFBackend.validate(bundle_path, Keyword.put(options, :inactive, true))

    assert length(page_sizes) == 2
  end

  test "rejects a template without the pinned form fields", %{work_dir: work_dir} do
    fixture = Path.expand("../fixtures/c00/synthetic-ticket-flexpreis.pdf", __DIR__)
    output_path = Path.join(work_dir, "filled.pdf")
    options = Keyword.put(backend_options(), :required_fields, ["signature"])

    assert {:error, :missing_field} =
             SystemPDFBackend.fill_form(fixture, [], output_path, options)

    refute File.exists?(output_path <> ".xfdf")
    refute File.exists?(output_path <> ".template.pdf")
  end

  defp backend_options do
    config = Application.fetch_env!(:fahrgastrechte, Fahrgastrechte.Exports)

    [
      timeout_ms: 30_000,
      max_bytes: 15 * 1024 * 1024,
      max_pages: 20,
      qpdf: Keyword.fetch!(config, :qpdf_executable),
      pdfinfo: Keyword.fetch!(config, :pdfinfo_executable),
      pdftk: Keyword.fetch!(config, :pdftk_executable),
      pdftocairo: Keyword.fetch!(config, :pdftocairo_executable),
      pdftotext: Keyword.fetch!(config, :pdftotext_executable),
      font_path: Keyword.fetch!(config, :font_path),
      required_fields: []
    ]
  end

  defp cover_model do
    %{
      claim: %{
        claim_number: "FGR-TEST",
        origin: "Berlin Hbf",
        destination: "Hamburg Hbf",
        travel_date: ~D[2026-07-15]
      },
      profile: %{
        title: nil,
        first_name: "Erika",
        last_name: "Beispiel",
        street: "Testweg",
        house_number: "1",
        postal_code: "10115",
        city: "Berlin",
        country: "Deutschland"
      },
      rail: %{
        first_disrupted_train: %{train_category: "ICE", train_number: "100"}
      }
    }
  end
end
