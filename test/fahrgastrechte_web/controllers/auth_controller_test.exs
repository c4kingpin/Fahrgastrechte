defmodule FahrgastrechteWeb.AuthControllerTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Fahrgastrechte.AccountsFixtures

  alias FahrgastrechteWeb.UserAuth

  setup do
    previous_provider = Application.get_env(:fahrgastrechte, :identity_provider)
    Application.put_env(:fahrgastrechte, :identity_provider, Fahrgastrechte.TestIdentityProvider)

    on_exit(fn ->
      Application.put_env(:fahrgastrechte, :identity_provider, previous_provider)
    end)

    :ok
  end

  test "starts login with an OIDC flow bound to the session", %{conn: conn} do
    conn = get(conn, ~p"/anmelden")

    redirect_uri = redirected_to(conn, 302)
    assert String.starts_with?(redirect_uri, "https://identity.example.invalid/authorize?")

    query = redirect_uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["state"] == "test-state"
    assert query["redirect_uri"] == "http://localhost:4000/auth/callback"

    assert %{
             "state" => "test-state",
             "nonce" => "test-nonce",
             "code_verifier" => "test-code-verifier"
           } = get_session(conn, :oidc_flow)
  end

  test "renews the session after a valid callback and rejects replay", %{conn: conn} do
    login_conn = get(conn, ~p"/anmelden")

    callback_conn =
      login_conn
      |> recycle()
      |> get(~p"/auth/callback?code=valid-code&state=test-state")

    assert redirected_to(callback_conn) == ~p"/antraege"
    assert is_integer(get_session(callback_conn, :user_id))
    assert get_session(callback_conn, :session_expires_at) > System.system_time(:second)
    assert get_session(callback_conn, :id_token_hint) == "test-id-token"
    assert get_session(callback_conn, :oidc_flow) == nil

    replay_conn =
      callback_conn
      |> recycle()
      |> get(~p"/auth/callback?code=valid-code&state=test-state")

    assert redirected_to(replay_conn) == ~p"/"

    assert Phoenix.Flash.get(replay_conn.assigns.flash, :error) ==
             "Die Anmeldung ist abgelaufen. Bitte starte sie erneut."
  end

  test "rejects a callback whose state does not match", %{conn: conn} do
    conn =
      conn
      |> get(~p"/anmelden")
      |> recycle()
      |> get(~p"/auth/callback?code=valid-code&state=wrong-state")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_id) == nil

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Die Anmeldung ist abgelaufen. Bitte starte sie erneut."
  end

  test "logs a sanitized provider callback failure", %{conn: conn} do
    log =
      capture_log(fn ->
        conn =
          conn
          |> get(~p"/anmelden")
          |> recycle()
          |> get(~p"/auth/callback?code=provider-error&state=test-state")

        assert redirected_to(conn) == ~p"/"

        assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
                 "Die Anmeldung konnte nicht sicher bestätigt werden. Bitte versuche es erneut."
      end)

    assert log =~ "OIDC callback rejected: provider_http_error"
  end

  test "clears the local session before provider logout", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> UserAuth.log_in_user(user, id_token_hint: "logout-token")
      |> delete(~p"/abmelden")

    redirect_uri = redirected_to(conn, 302)
    query = redirect_uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert String.starts_with?(redirect_uri, "https://identity.example.invalid/end-session?")
    assert query["id_token_hint"] == "logout-token"
    assert query["return_to"] == "http://localhost:4000/auth/abgemeldet"
    assert get_session(conn, :user_id) == nil
  end

  test "explains an expired session and requires a new login", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{})
      |> UserAuth.log_in_user(user, expires_at: System.system_time(:second) - 1)
      |> get(~p"/profil")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_id) == nil

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Deine Sitzung ist abgelaufen. Bitte melde dich erneut an."
  end

  # ADR 0006 keeps sessions in the cookie without server-side revocation and
  # leans on the expiry being absolute: activity must never extend it.
  test "activity does not extend the session expiry", %{conn: conn} do
    user = user_fixture()

    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user)
    granted_at = get_session(conn, :session_expires_at)

    assert is_integer(granted_at)

    conn = get(conn, ~p"/antraege")
    assert get_session(conn, :session_expires_at) == granted_at

    conn = get(conn, ~p"/profil")
    assert get_session(conn, :session_expires_at) == granted_at
    assert get_session(conn, :user_id) == user.id
  end

  test "an already authenticated user goes straight to their claims", %{conn: conn} do
    user = user_fixture()
    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user) |> get(~p"/anmelden")

    assert redirected_to(conn) == ~p"/antraege"
  end
end
