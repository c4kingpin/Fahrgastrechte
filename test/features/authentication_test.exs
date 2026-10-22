defmodule FahrgastrechteWeb.Features.AuthenticationTest do
  use FahrgastrechteWeb.FeatureCase

  alias Fahrgastrechte.E2EIdentityProvider

  test "an anonymous visitor sees the public start page and can jump to the workflow", %{
    conn: conn
  } do
    conn
    |> visit(~p"/")
    |> assert_has("#preview-hero")
    |> assert_has("#login-link", text: "Anmelden")
    |> assert_has("#login-cta")
    |> refute_has("#logout-link")
    |> refute_has("#claims-nav-link")
    |> click_link("Ablauf")
    |> assert_has("#workflow-heading")
  end

  test "signs in through the identity provider and signs out again", %{conn: conn} do
    conn
    |> visit(~p"/")
    |> click_link("#login-link", "Anmelden")
    |> assert_path(~p"/antraege")
    |> assert_has("#flash-info", text: "Du bist sicher angemeldet.")
    |> assert_has("#logout-link", text: "B")
    # The toast sits on top of the header; dismissing it is part of the flow.
    |> click("#flash-info")
    |> refute_has("#flash-info")
    |> click_link("#logout-link", "Abmelden")
    |> assert_path(~p"/")
    |> assert_has("#flash-info", text: "Du bist abgemeldet.")
    |> assert_has("#login-link")
    |> visit(~p"/antraege")
    |> assert_path(~p"/")
    |> assert_has("#flash-error", text: "Bitte melde dich an")

    assert Fahrgastrechte.Repo.get_by(Fahrgastrechte.Accounts.User,
             subject: E2EIdentityProvider.identity().subject
           )
  end

  test "the call-to-action on the start page also starts the login", %{conn: conn} do
    conn
    |> visit(~p"/")
    |> click_link("#login-cta", "Anmelden")
    |> assert_path(~p"/antraege")
    |> assert_has("#claims-dashboard")
  end

  test "an already signed-in person is sent straight to the claims", %{conn: conn} do
    conn
    |> log_in(user_fixture())
    |> visit(~p"/anmelden")
    |> assert_path(~p"/antraege")
  end

  @tag capture_log: true
  test "a callback without a started login is rejected", %{conn: conn} do
    conn
    |> visit(~p"/auth/callback?code=e2e-code&state=e2e-state")
    |> assert_path(~p"/")
    |> assert_has("#flash-error", text: "Die Anmeldung ist abgelaufen")
    |> refute_has("#logout-link")
  end

  test "an aborted login at the provider is reported", %{conn: conn} do
    put_env_for_test(:identity_provider, __MODULE__.DenyingProvider)

    conn
    |> visit(~p"/")
    |> click_link("#login-link", "Anmelden")
    |> assert_path(~p"/")
    |> assert_has("#flash-error", text: "Die Anmeldung wurde abgebrochen.")
  end

  for path <- [
        "/antraege",
        "/profil",
        "/datenquellen",
        "/antraege/00000000-0000-0000-0000-000000000000"
      ] do
    test "protects #{path} from anonymous visitors", %{conn: conn} do
      conn
      |> visit(unquote(path))
      |> assert_path(~p"/")
      |> assert_has("#flash-error", text: "Bitte melde dich an, um diesen Bereich zu öffnen.")
    end
  end

  test "an expired session is ended with a notice", %{conn: conn} do
    user = user_fixture()

    conn
    |> PhoenixTest.Playwright.add_session_cookie(
      [value: %{user_id: user.id, session_expires_at: System.system_time(:second) - 1}],
      FahrgastrechteWeb.Endpoint.session_options()
    )
    |> visit(~p"/antraege")
    |> assert_path(~p"/")
    |> assert_has("#flash-error", text: "Deine Sitzung ist abgelaufen.")
  end

  test "an open page signs the person out when the session runs out", %{conn: conn} do
    user = user_fixture()

    conn
    |> PhoenixTest.Playwright.add_session_cookie(
      [value: %{user_id: user.id, session_expires_at: System.system_time(:second) + 2}],
      FahrgastrechteWeb.Endpoint.session_options()
    )
    |> visit(~p"/profil")
    |> assert_connected()
    |> assert_path(~p"/", timeout: 5_000)
    |> assert_has("#flash-error", text: "Deine Sitzung ist abgelaufen.")
  end

  test "a session for a deleted user is no longer valid", %{conn: conn} do
    conn
    |> PhoenixTest.Playwright.add_session_cookie(
      [value: %{user_id: -1, session_expires_at: System.system_time(:second) + 3_600}],
      FahrgastrechteWeb.Endpoint.session_options()
    )
    |> visit(~p"/antraege")
    |> assert_path(~p"/")
    |> assert_has("#flash-error", text: "Deine Sitzung ist nicht mehr gültig.")
  end

  defmodule DenyingProvider do
    @moduledoc false
    @behaviour Fahrgastrechte.Accounts.IdentityProvider

    @impl true
    def authorization_request(callback_uri) do
      {:ok,
       %{
         uri: callback_uri <> "?error=access_denied&state=e2e-state",
         session_state: %{"state" => "e2e-state"}
       }}
    end

    @impl true
    def validate_callback(_params, _session_state), do: {:error, :access_denied}

    @impl true
    def logout_uri(_id_token_hint, return_to), do: {:ok, return_to}
  end
end
