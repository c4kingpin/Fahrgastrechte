defmodule Fahrgastrechte.ReferenceDataTest do
  use Fahrgastrechte.DataCase, async: false

  import Fahrgastrechte.AccountsFixtures

  alias Fahrgastrechte.Documents.LocalStorage
  alias Fahrgastrechte.Exports.Template
  alias Fahrgastrechte.Rail.Providers.BahnVorhersageArchive
  alias Fahrgastrechte.ReferenceData

  @fixtures Path.expand("../fixtures/c00", __DIR__)

  test "activates compatible official forms and keeps prior versions immutable" do
    scope = scope_fixture()
    pdf_path = Path.join(@fixtures, "synthetic-ticket-flexpreis.pdf")

    assert {:ok, first} =
             ReferenceData.replace_official_form(scope, pdf_path, %{
               "version" => "Formular Test 1",
               "source_url" => "https://example.invalid/form-1.pdf",
               "original_filename" => "../form-1.pdf"
             })

    assert {:ok, second} =
             ReferenceData.replace_official_form(scope, pdf_path, %{
               "version" => "Formular Test 2",
               "source_url" => "https://example.invalid/form-2.pdf",
               "original_filename" => "form-2.pdf"
             })

    on_exit(fn ->
      LocalStorage.delete(first.storage_key)
      LocalStorage.delete(second.storage_key)
    end)

    assert {:ok, [listed_second, listed_first]} =
             ReferenceData.list_versions(scope, :official_form)

    refute listed_first.current
    assert listed_second.current
    assert first.storage_key != second.storage_key
    assert LocalStorage.exists?(first.storage_key)
    assert LocalStorage.exists?(second.storage_key)

    assert {:ok, template} = Template.current()
    assert template.version == "Formular Test 2"
    assert template.source == "https://example.invalid/form-2.pdf"
    assert template.sha256 == second.sha256

    assert :ok = LocalStorage.delete(second.storage_key)
    assert {:error, :template_unavailable} = Template.current()
  end

  test "rejects invalid form metadata before storing a file" do
    scope = scope_fixture()
    pdf_path = Path.join(@fixtures, "synthetic-ticket-flexpreis.pdf")

    assert {:error, %Ecto.Changeset{}} =
             ReferenceData.replace_official_form(scope, pdf_path, %{
               "version" => "",
               "source_url" => "http://example.invalid/form.pdf",
               "original_filename" => "form.pdf"
             })

    assert {:ok, []} = ReferenceData.list_versions(scope, :official_form)
  end

  test "activates a Bahn-Vorhersage projection for provider calls" do
    scope = scope_fixture()
    csv_path = Path.join(@fixtures, "bahnvorhersage-parsed-delays.csv")

    assert {:ok, version} =
             ReferenceData.replace_bahn_archive(scope, csv_path, %{
               "version" => "parsed-delays-test-2026",
               "source_url" => "https://bahnvorhersage.de/open-data/parsed-train-delays/",
               "original_filename" => "delays-2026.csv"
             })

    on_exit(fn -> LocalStorage.delete(version.storage_key) end)

    assert version.metadata["row_count"] > 0
    assert version.metadata["coverage_from"] == "2026-04-15"
    assert version.metadata["coverage_until"] == "2026-04-15"

    assert {:ok, [journey]} =
             BahnVorhersageArchive.departures(
               %{provider: BahnVorhersageArchive, value: "9999999"},
               ~U[2026-04-15 08:00:00Z],
               ~U[2026-04-15 09:00:00Z],
               station_names: %{
                 "9999999" => "Teststadt Hbf",
                 "9999998" => "Beispielstadt Hbf"
               }
             )

    assert journey.source_metadata["dataset_version"] == "parsed-delays-test-2026"
    assert journey.source_metadata["source_name"] == "delays-2026.csv"

    assert :ok = LocalStorage.delete(version.storage_key)

    assert {:error, :history_unavailable} =
             BahnVorhersageArchive.departures(
               %{provider: BahnVorhersageArchive, value: "9999999"},
               ~U[2026-04-15 08:00:00Z],
               ~U[2026-04-15 09:00:00Z],
               []
             )
  end

  test "rejects malformed archives and unauthenticated mutations" do
    scope = scope_fixture()
    invalid_path = temporary_file("not,a,bahn,archive\n1,2,3\n")

    assert {:error, :invalid_archive} =
             ReferenceData.replace_bahn_archive(scope, invalid_path, %{
               "version" => "invalid",
               "original_filename" => "invalid.csv"
             })

    assert {:error, :not_authenticated} =
             ReferenceData.replace_bahn_archive(nil, invalid_path, %{})

    assert {:error, :not_authenticated} =
             ReferenceData.list_versions(nil, :bahn_vorhersage_archive)
  end

  defp temporary_file(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "reference-data-test-#{System.unique_integer([:positive])}.csv"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
