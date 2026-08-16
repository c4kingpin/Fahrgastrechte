defmodule FahrgastrechteWeb.UserAuth do
  @moduledoc """
  Authenticated browser-session and LiveView integration for `current_scope`.
  """

  use FahrgastrechteWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias Fahrgastrechte.Accounts

  @session_key :user_id
  @session_expiry_key :session_expires_at
  @id_token_hint_key :id_token_hint
  @default_session_ttl_seconds 8 * 60 * 60
  @max_id_token_hint_bytes 2048
  @development_login Application.compile_env(:fahrgastrechte, :development_login, false)

  def fetch_current_scope(conn, _opts) do
    case scope_from_session(conn) do
      {:ok, scope} ->
        conn
        |> assign(:current_scope, scope)
        |> assign(:authentication_failure, nil)

      {:error, reason} ->
        conn
        |> clear_authentication()
        |> assign(:current_scope, nil)
        |> assign(:authentication_failure, reason)
        |> put_flash(:error, authentication_message(reason))

      :missing ->
        conn
        |> assign(:authentication_failure, nil)
        |> put_development_scope()
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope do
      conn
    else
      message =
        conn.assigns
        |> Map.get(:authentication_failure)
        |> authentication_message()

      conn
      |> put_flash(:error, message)
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  @doc false
  def log_in_user(conn, user, options \\ []) do
    expires_at =
      Keyword.get(options, :expires_at, now() + @default_session_ttl_seconds)

    conn =
      conn
      |> configure_session(renew: true)
      |> put_session(@session_key, user.id)
      |> put_session(@session_expiry_key, expires_at)

    case Keyword.get(options, :id_token_hint) do
      hint when is_binary(hint) and hint != "" and byte_size(hint) <= @max_id_token_hint_bytes ->
        put_session(conn, @id_token_hint_key, hint)

      _other ->
        delete_session(conn, @id_token_hint_key)
    end
  end

  @doc false
  def log_out_user(conn) do
    conn
    |> clear_session()
    |> configure_session(renew: true)
  end

  @doc false
  def id_token_hint(conn), do: get_session(conn, @id_token_hint_key)

  def on_mount(:require_authenticated, _params, session, socket) do
    case scope_from_live_session(session) do
      {:ok, scope} ->
        expires_at = Map.fetch!(session, to_string(@session_expiry_key))

        socket =
          socket
          |> Phoenix.Component.assign(:current_scope, scope)
          |> enforce_live_session_expiry(expires_at)

        {:cont, socket}

      {:error, reason} ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, authentication_message(reason))
          |> Phoenix.LiveView.redirect(to: ~p"/")

        {:halt, socket}
    end
  end

  defp scope_from_session(conn) do
    user_id = get_session(conn, @session_key)
    expires_at = get_session(conn, @session_expiry_key)

    scope_for_credentials(user_id, expires_at)
  end

  defp scope_from_live_session(session) do
    user_id = Map.get(session, to_string(@session_key))
    expires_at = Map.get(session, to_string(@session_expiry_key))

    case scope_for_credentials(user_id, expires_at) do
      :missing -> {:error, :authentication_required}
      result -> result
    end
  end

  defp scope_for_credentials(user_id, expires_at)
       when is_integer(user_id) and is_integer(expires_at) do
    cond do
      expires_at <= now() ->
        {:error, :session_expired}

      scope = Accounts.scope_for_user_id(user_id) ->
        {:ok, scope}

      true ->
        {:error, :invalid_session}
    end
  end

  defp scope_for_credentials(nil, nil), do: :missing
  defp scope_for_credentials(_user_id, _expires_at), do: {:error, :invalid_session}

  # Signing an anonymous visitor in as a local identity must never be reachable
  # in a production release, so the branch is removed at compile time rather
  # than guarded by a runtime value that a stray config line could set.
  if @development_login do
    alias Fahrgastrechte.Accounts.Identity

    defp put_development_scope(conn) do
      case Application.get_env(:fahrgastrechte, :development_identity) do
        nil ->
          assign(conn, :current_scope, nil)

        attrs ->
          with {:ok, identity} <- Identity.development(attrs),
               {:ok, user} <- Accounts.register_identity(identity) do
            conn
            |> log_in_user(user)
            |> assign(:current_scope, Accounts.scope_for_user_id(user.id))
          else
            _error -> assign(conn, :current_scope, nil)
          end
      end
    end
  else
    defp put_development_scope(conn), do: assign(conn, :current_scope, nil)
  end

  defp clear_authentication(conn) do
    conn
    |> delete_session(@session_key)
    |> delete_session(@session_expiry_key)
    |> delete_session(@id_token_hint_key)
  end

  defp authentication_message(:session_expired),
    do: "Deine Sitzung ist abgelaufen. Bitte melde dich erneut an."

  defp authentication_message(:invalid_session),
    do: "Deine Sitzung ist nicht mehr gültig. Bitte melde dich erneut an."

  defp authentication_message(_reason),
    do: "Bitte melde dich an, um diesen Bereich zu öffnen."

  defp enforce_live_session_expiry(socket, expires_at) do
    if Phoenix.LiveView.connected?(socket) do
      timeout_ms = max((expires_at - now()) * 1_000, 0)
      message = {__MODULE__, :session_expired, expires_at}
      Process.send_after(self(), message, timeout_ms)

      Phoenix.LiveView.attach_hook(
        socket,
        :enforce_session_expiry,
        :handle_info,
        fn
          ^message, socket ->
            socket =
              socket
              |> Phoenix.LiveView.put_flash(
                :error,
                authentication_message(:session_expired)
              )
              |> Phoenix.LiveView.redirect(to: ~p"/")

            {:halt, socket}

          _message, socket ->
            {:cont, socket}
        end
      )
    else
      socket
    end
  end

  defp now, do: System.system_time(:second)
end
