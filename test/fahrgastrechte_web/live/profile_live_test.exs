defmodule FahrgastrechteWeb.ProfileLiveTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.Scope
  alias FahrgastrechteWeb.UserAuth

  test "controller pipeline assigns current_scope from the signed session", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> UserAuth.log_in_user(user)
      |> get(~p"/")

    assert conn.assigns.current_scope.user.id == user.id
  end

  test "profile route redirects without a current identity", %{conn: conn} do
    conn = get(conn, ~p"/profil")

    assert redirected_to(conn) == ~p"/"
  end

  test "authenticated LiveView receives current_scope and renders stable form ids", %{conn: conn} do
    user = user_fixture()
    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user)

    assert {:ok, view, _html} = live(conn, ~p"/profil")
    assert has_element?(view, "#profile-page")
    assert has_element?(view, "#profile-form")
    assert has_element?(view, "#profile-save")
    assert has_element?(view, "#profile-completeness")
    assert has_element?(view, "#profile-nav-link[aria-current=page]")
    assert has_element?(view, "#mobile-navigation")
    assert has_element?(view, "#logout-link")
  end

  test "validates and saves the current user's profile", %{conn: conn} do
    user = user_fixture()
    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user)
    {:ok, view, _html} = live(conn, ~p"/profil")

    view
    |> form("#profile-form", profile: valid_profile_attributes(%{"iban" => "DE00123"}))
    |> render_change()

    assert has_element?(view, "#profile-iban[aria-invalid=\"true\"]")

    view
    |> form("#profile-form", profile: valid_profile_attributes())
    |> render_submit()

    assert has_element?(view, "#profile-completeness")
    assert {:ok, profile} = Accounts.get_profile(Scope.for_user(user))
    assert profile.first_name == "Erika"
    assert Accounts.profile_complete?(Scope.for_user(user))
  end

  test "development identity fallback is explicit and repeatable", %{conn: conn} do
    previous_identity = Application.get_env(:fahrgastrechte, :development_identity)

    on_exit(fn ->
      Application.put_env(:fahrgastrechte, :development_identity, previous_identity)
    end)

    Application.put_env(:fahrgastrechte, :development_identity, %{
      issuer: "https://development.invalid/test",
      subject: "test-developer",
      email: "test@example.invalid",
      display_name: "Testentwicklung"
    })

    first_conn = get(conn, ~p"/")
    second_conn = get(Phoenix.ConnTest.build_conn(), ~p"/")

    assert first_conn.assigns.current_scope.user.id == second_conn.assigns.current_scope.user.id
  end
end
