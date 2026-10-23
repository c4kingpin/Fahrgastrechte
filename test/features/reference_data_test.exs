defmodule FahrgastrechteWeb.Features.ReferenceDataTest do
  use FahrgastrechteWeb.FeatureCase

  alias Fahrgastrechte.Documents.LocalStorage
  alias Fahrgastrechte.ReferenceData

  test "shows the bundled form and the missing archive", %{conn: conn} do
    conn
    |> log_in(user_fixture())
    |> visit(~p"/datenquellen")
    |> assert_has("#reference-data-page h1", text: "Verlässliche Quellen")
    |> assert_has("#official-form-source-current[data-state=available]", text: "Mitgeliefert")
    |> assert_has("#bahn-archive-source-current[data-state=missing]",
      text: "Noch keine Quelle verfügbar"
    )
    |> assert_has("#official-form-versions-empty", text: "Noch keine Version")
    |> assert_has("#activate-official-form[disabled]")
    |> assert_has("#activate-bahn-archive[disabled]")
  end

  test "uploads, checks and activates a new official form", %{conn: conn} do
    scope = scope_fixture()

    conn
    |> log_in(scope)
    |> visit(~p"/datenquellen")
    |> assert_connected()
    |> within("#official-form-source", fn conn ->
      conn
      |> fill_in("Formularversion", with: "Formular 2027 (ME/01/27)")
      |> fill_in("Offizielle Quelladresse", with: "https://example.invalid/formular-2027.pdf")
      |> upload("Datei wählen", fixture_path())
      |> assert_has("#official-form-upload", text: "synthetic-ticket-flexpreis.pdf")
      |> click_button("#activate-official-form", "Formular prüfen und aktivieren")
    end)
    |> assert_has("#flash-info",
      text: "Das offizielle Formular Formular 2027 (ME/01/27) ist jetzt aktiv."
    )
    |> assert_has("#official-form-source-current", text: "Formular 2027 (ME/01/27)")
    |> assert_has("#official-form-source-current", text: "Interface")
    |> assert_has("#official-form-versions article", text: "Aktiv")

    cleanup_versions(scope, :official_form)
  end

  test "uploads, checks and activates a Bahn-Vorhersage archive", %{conn: conn} do
    scope = scope_fixture()

    conn
    |> log_in(scope)
    |> visit(~p"/datenquellen")
    |> assert_connected()
    |> within("#bahn-archive-source", fn conn ->
      conn
      |> fill_in("Datensatzversion", with: "parsed-delays-2026")
      |> upload("Datei wählen", fixture_path("bahnvorhersage-parsed-delays.csv"))
      |> click_button("#activate-bahn-archive", "Datensatz prüfen und aktivieren")
    end)
    |> assert_has("#flash-info",
      text: "Der Bahn-Vorhersage-Datensatz parsed-delays-2026 ist jetzt aktiv."
    )
    |> assert_has("#bahn-archive-source-current[data-state=available]", text: "Abdeckung")
    |> assert_has("#bahn-archive-versions article", text: "parsed-delays-2026")

    cleanup_versions(scope, :bahn_vorhersage_archive)
  end

  test "rejects a wrong file type and lets the person remove it", %{conn: conn} do
    conn
    |> log_in(user_fixture())
    |> visit(~p"/datenquellen")
    |> assert_connected()
    |> within("#official-form-source", fn conn ->
      conn
      |> upload("Datei wählen", fixture_path("bahnvorhersage-parsed-delays.csv"))
      |> assert_has("#official-form-upload", text: "Dieses Dateiformat wird nicht akzeptiert.")
      |> assert_has("#activate-official-form[disabled]")
      |> click_button("Upload entfernen")
      |> refute_has("#official-form-upload", text: "bahnvorhersage-parsed-delays.csv")
    end)
  end

  test "rejects an archive that is not a Bahn-Vorhersage projection", %{conn: conn} do
    invalid_csv =
      Path.join(
        System.tmp_dir!(),
        "fahrgastrechte-invalid-#{System.unique_integer([:positive])}.csv"
      )

    File.write!(invalid_csv, "foo,bar\n1,2\n")
    on_exit(fn -> File.rm(invalid_csv) end)

    conn
    |> log_in(user_fixture())
    |> visit(~p"/datenquellen")
    |> assert_connected()
    |> within("#bahn-archive-source", fn conn ->
      conn
      |> fill_in("Datensatzversion", with: "kaputt")
      |> upload("Datei wählen", invalid_csv)
      |> click_button("#activate-bahn-archive", "Datensatz prüfen und aktivieren")
    end)
    |> assert_has("#flash-error",
      text: "Die CSV-Datei entspricht nicht der erwarteten Bahn-Vorhersage-Projektion."
    )
    |> assert_has("#bahn-archive-source-current[data-state=missing]")
  end

  test "requires a valid HTTPS source for a new form", %{conn: conn} do
    conn
    |> log_in(user_fixture())
    |> visit(~p"/datenquellen")
    |> assert_connected()
    |> within("#official-form-source", fn conn ->
      conn
      |> fill_in("Formularversion", with: "Formular unsicher")
      |> fill_in("Offizielle Quelladresse", with: "http://example.invalid/formular.pdf")
      |> upload("Datei wählen", fixture_path())
      |> click_button("#activate-official-form", "Formular prüfen und aktivieren")
    end)
    |> assert_has("#flash-error",
      text: "Version und offizielle HTTPS-Quelladresse müssen gültig sein."
    )
    |> assert_has("#official-form-versions-empty")
  end

  defp cleanup_versions(scope, kind) do
    {:ok, versions} = ReferenceData.list_versions(scope, kind)
    Enum.each(versions, &LocalStorage.delete(&1.storage_key))
  end
end
