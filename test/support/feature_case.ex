defmodule FahrgastrechteWeb.FeatureCase do
  @moduledoc """
  Case for browser feature tests in `test/features`, driven by Playwright.

  Each test gets its own browser context (`conn`, a Playwright session rather
  than a `Plug.Conn`) that shares the test's SQL sandbox with every request
  and LiveView process. Rail lookups use `Fahrgastrechte.TestRailProvider`
  and logins use `Fahrgastrechte.E2EIdentityProvider`, so no test reaches an
  external service.

  Tests run synchronously because they swap application-wide providers.
  """

  use ExUnit.CaseTemplate

  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Rail

  using do
    quote do
      use PhoenixTest.Playwright.Case, async: false
      use FahrgastrechteWeb, :verified_routes

      import FahrgastrechteWeb.FeatureCase
      import Fahrgastrechte.AccountsFixtures
      import Fahrgastrechte.ClaimsFixtures
      import Fahrgastrechte.DocumentsFixtures
      import Fahrgastrechte.ExportsFixtures
      import Fahrgastrechte.RailFixtures

      @moduletag :feature
    end
  end

  setup do
    put_env_for_test(:identity_provider, Fahrgastrechte.E2EIdentityProvider)

    rail_config = Application.fetch_env!(:fahrgastrechte, Rail)
    put_env_for_test(Rail, Keyword.put(rail_config, :provider, Fahrgastrechte.TestRailProvider))
    :ok
  end

  @doc "Sets an application env value for the current test only."
  def put_env_for_test(key, value) do
    previous = Application.fetch_env(:fahrgastrechte, key)
    Application.put_env(:fahrgastrechte, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fahrgastrechte, key, value)
        :error -> Application.delete_env(:fahrgastrechte, key)
      end
    end)
  end

  @doc """
  Signs the browser in as the given user without walking the OIDC flow.

  The flow itself is covered in `FahrgastrechteWeb.Features.AuthenticationTest`.
  """
  def log_in(conn, %Scope{user: user}), do: log_in(conn, user)

  def log_in(conn, user) do
    PhoenixTest.Playwright.add_session_cookie(
      conn,
      [
        value: %{
          user_id: user.id,
          session_expires_at: System.system_time(:second) + 3_600
        }
      ],
      FahrgastrechteWeb.Endpoint.session_options()
    )
  end

  @doc """
  Selects several files at once in the file input labelled `label`, like
  choosing them together in the file dialog.
  """
  def upload_files(conn, label, paths) do
    PhoenixTest.Playwright.upload(conn, nil, label, paths, exact: false)
  end

  @doc "Fills an unlabelled input, such as a search box, found by CSS selector."
  def fill_selector(conn, selector, value) do
    PhoenixTest.Playwright.unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, _} =
        PlaywrightEx.Frame.fill(frame_id,
          selector: selector,
          value: value,
          timeout: PhoenixTest.Playwright.Config.global(:timeout)
        )
    end)
  end

  @doc """
  Retries `fun` until it returns true, for checking data the browser saves
  asynchronously (debounced autosave, background jobs).
  """
  def assert_eventually(fun, timeout \\ PhoenixTest.Playwright.Config.global(:timeout)) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("Condition was not met in time")

      true ->
        Process.sleep(50)
        do_assert_eventually(fun, deadline)
    end
  end

  @doc "Waits until the LiveView on the current page has connected."
  def assert_connected(conn), do: PhoenixTest.assert_has(conn, "[data-phx-session].phx-connected")
end
