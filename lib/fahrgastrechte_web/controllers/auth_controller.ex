defmodule FahrgastrechteWeb.AuthController do
  use FahrgastrechteWeb, :controller

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.AuthenticatedSession
  alias FahrgastrechteWeb.UserAuth

  @oidc_flow_key :oidc_flow

  def login(%{assigns: %{current_scope: current_scope}} = conn, _params)
      when not is_nil(current_scope) do
    redirect(conn, to: ~p"/antraege")
  end

  def login(conn, _params) do
    callback_uri = absolute_url(~p"/auth/callback")

    case identity_provider().authorization_request(callback_uri) do
      {:ok, %{uri: uri, session_state: session_state}}
      when is_binary(uri) and is_map(session_state) ->
        conn
        |> put_session(@oidc_flow_key, session_state)
        |> redirect(external: uri)

      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          "Die Anmeldung ist derzeit nicht verfügbar. Bitte versuche es später erneut."
        )
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, params) do
    session_state = get_session(conn, @oidc_flow_key)
    conn = delete_session(conn, @oidc_flow_key)

    result =
      if is_map(session_state) do
        identity_provider().validate_callback(params, session_state)
      else
        {:error, :missing_flow}
      end

    case result do
      {:ok, %AuthenticatedSession{} = authenticated_session} ->
        complete_login(conn, authenticated_session)

      {:error, reason} ->
        conn
        |> put_flash(:error, callback_error_message(reason))
        |> redirect(to: ~p"/")
    end
  end

  def logout(conn, _params) do
    return_to = absolute_url(~p"/auth/abgemeldet")
    id_token_hint = UserAuth.id_token_hint(conn)
    conn = UserAuth.log_out_user(conn)
    logout_result = identity_provider().logout_uri(id_token_hint, return_to)

    case logout_result do
      {:ok, uri} when is_binary(uri) ->
        redirect(conn, external: uri)

      {:error, _reason} ->
        conn
        |> put_flash(:info, "Du bist abgemeldet.")
        |> redirect(to: ~p"/")
    end
  end

  def logged_out(conn, _params) do
    conn
    |> UserAuth.log_out_user()
    |> put_flash(:info, "Du bist abgemeldet.")
    |> redirect(to: ~p"/")
  end

  defp complete_login(conn, authenticated_session) do
    case Accounts.register_identity(authenticated_session.identity) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in_user(user,
          expires_at: authenticated_session.expires_at,
          id_token_hint: authenticated_session.id_token
        )
        |> put_flash(:info, "Du bist sicher angemeldet.")
        |> redirect(to: ~p"/antraege")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Die Anmeldung konnte nicht abgeschlossen werden.")
        |> redirect(to: ~p"/")
    end
  end

  defp callback_error_message(:access_denied), do: "Die Anmeldung wurde abgebrochen."

  defp callback_error_message(reason)
       when reason in [:missing_flow, :expired_flow, :invalid_state],
       do: "Die Anmeldung ist abgelaufen. Bitte starte sie erneut."

  defp callback_error_message(_reason),
    do: "Die Anmeldung konnte nicht sicher bestätigt werden. Bitte versuche es erneut."

  defp identity_provider do
    Application.get_env(
      :fahrgastrechte,
      :identity_provider,
      Fahrgastrechte.Accounts.Authentik
    )
  end

  defp absolute_url(path) do
    FahrgastrechteWeb.Endpoint.url()
    |> URI.merge(path)
    |> URI.to_string()
  end
end
