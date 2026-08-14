defmodule FahrgastrechteWeb.ReferenceDataLiveTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Documents.LocalStorage
  alias Fahrgastrechte.ReferenceData
  alias FahrgastrechteWeb.UserAuth

  @fixtures Path.expand("../../fixtures/c00", __DIR__)

  test "redirects unauthenticated visitors", %{conn: conn} do
    assert conn |> get(~p"/datenquellen") |> redirected_to() == ~p"/"
  end

  test "renders active fallback sources and stable upload controls", %{conn: conn} do
    {conn, _scope} = authenticated_conn(conn)

    assert {:ok, view, _html} = live(conn, ~p"/datenquellen")
    assert has_element?(view, "#reference-data-page")
    assert has_element?(view, "#official-form-upload-form")
    assert has_element?(view, "#bahn-archive-upload-form")
    assert has_element?(view, "#official-form-source-current[data-state=available]")
    assert has_element?(view, "#bahn-archive-source-current[data-state=missing]")
    assert has_element?(view, "#sources-nav-link[aria-current=page]")
    assert has_element?(view, "#mobile-sources-nav-link[aria-current=page]")
  end

  test "uploads and activates an official form", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/datenquellen")
    content = File.read!(Path.join(@fixtures, "synthetic-ticket-flexpreis.pdf"))

    upload =
      file_input(view, "#official-form-upload-form", :official_form, [
        %{
          last_modified: 1_700_000_000_000,
          name: "formular-neu.pdf",
          content: content,
          size: byte_size(content),
          type: "application/pdf"
        }
      ])

    render_upload(upload, "formular-neu.pdf")

    view
    |> form("#official-form-upload-form",
      official_form: %{
        "version" => "Formular Neu",
        "source_url" => "https://example.invalid/formular-neu.pdf"
      }
    )
    |> render_submit()

    assert has_element?(view, "#official-form-source-current[data-state=available]")
    assert has_element?(view, "#official-form-versions article")

    assert {:ok, [version]} = ReferenceData.list_versions(scope, :official_form)
    assert version.version == "Formular Neu"
    assert version.current
    on_exit(fn -> LocalStorage.delete(version.storage_key) end)
  end

  test "uploads and activates a Bahn-Vorhersage CSV projection", %{conn: conn} do
    {conn, scope} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/datenquellen")
    content = File.read!(Path.join(@fixtures, "bahnvorhersage-parsed-delays.csv"))

    upload =
      file_input(view, "#bahn-archive-upload-form", :bahn_archive, [
        %{
          last_modified: 1_700_000_000_000,
          name: "parsed-delays-2026.csv",
          content: content,
          size: byte_size(content),
          type: "text/csv"
        }
      ])

    render_upload(upload, "parsed-delays-2026.csv")

    view
    |> form("#bahn-archive-upload-form",
      archive: %{
        "version" => "parsed-delays-2026",
        "source_url" => "https://bahnvorhersage.de/open-data/parsed-train-delays/"
      }
    )
    |> render_submit()

    assert has_element?(view, "#bahn-archive-source-current[data-state=available]")
    assert has_element?(view, "#bahn-archive-versions article")

    assert {:ok, [version]} =
             ReferenceData.list_versions(scope, :bahn_vorhersage_archive)

    assert version.version == "parsed-delays-2026"
    assert version.metadata["row_count"] > 0
    on_exit(fn -> LocalStorage.delete(version.storage_key) end)
  end

  defp authenticated_conn(conn) do
    user = user_fixture()
    {conn |> init_test_session(%{}) |> UserAuth.log_in_user(user), Scope.for_user(user)}
  end
end
