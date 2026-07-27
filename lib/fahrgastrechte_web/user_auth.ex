defmodule FahrgastrechteWeb.UserAuth do
  @moduledoc """
  Session and LiveView integration for `current_scope`.

  During C01 development only, a configured synthetic identity is registered
  automatically. Production has no such fallback and remains closed until the
  Authentik adapter implements the identity-provider boundary.
  """

  use FahrgastrechteWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.Identity

  @session_key :user_id

  def fetch_current_scope(conn, _opts) do
    case get_session(conn, @session_key) do
      user_id when is_integer(user_id) ->
        case Accounts.scope_for_user_id(user_id) do
          nil -> put_development_scope(delete_session(conn, @session_key))
          scope -> assign(conn, :current_scope, scope)
        end

      _other ->
        put_development_scope(conn)
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope do
      conn
    else
      conn
      |> put_flash(:error, "Diese Seite ist nur mit einer gültigen Identität verfügbar.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  @doc false
  def log_in_user(conn, user) do
    conn
    |> configure_session(renew: true)
    |> put_session(@session_key, user.id)
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    scope =
      session
      |> Map.get(to_string(@session_key))
      |> Accounts.scope_for_user_id()

    if scope do
      {:cont, Phoenix.Component.assign(socket, :current_scope, scope)}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(
          :error,
          "Diese Seite ist nur mit einer gültigen Identität verfügbar."
        )
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end

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
end
