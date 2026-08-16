defmodule FahrgastrechteWeb.HealthControllerTest do
  use FahrgastrechteWeb.ConnCase, async: false

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.BankDataCipher
  alias Fahrgastrechte.Documents.LocalStorage

  import Fahrgastrechte.AccountsFixtures

  test "GET /healthz reports process liveness", %{conn: conn} do
    assert %{"status" => "ok"} =
             conn
             |> get(~p"/healthz")
             |> json_response(200)
  end

  test "GET /readyz reports database and document storage readiness", %{conn: conn} do
    assert %{"status" => "ready"} =
             conn
             |> get(~p"/readyz")
             |> json_response(200)
  end

  test "GET /readyz fails closed when document storage is unavailable", %{conn: conn} do
    original_config = Application.fetch_env!(:fahrgastrechte, LocalStorage)
    blocking_path = Path.join(System.tmp_dir!(), "health-block-#{System.unique_integer()}")
    unavailable_path = Path.join(blocking_path, "documents")

    File.write!(blocking_path, "not a directory")

    on_exit(fn ->
      Application.put_env(:fahrgastrechte, LocalStorage, original_config)
      File.rm(blocking_path)
    end)

    Application.put_env(
      :fahrgastrechte,
      LocalStorage,
      Keyword.put(original_config, :path, unavailable_path)
    )

    assert %{
             "status" => "unavailable",
             "failed_checks" => ["document_storage"]
           } =
             conn
             |> get(~p"/readyz")
             |> json_response(503)
  end

  test "GET /readyz fails closed when a stored profile's key version has no matching key", %{
    conn: conn
  } do
    original_configuration = Application.fetch_env!(:fahrgastrechte, BankDataCipher)

    on_exit(fn ->
      Application.put_env(:fahrgastrechte, BankDataCipher, original_configuration)
    end)

    scope = scope_fixture()
    assert {:ok, _profile} = Accounts.update_profile(scope, valid_profile_attributes())

    # An installer that reverted a key rotation would leave the DB referencing a
    # version the configured keyring no longer has a key for.
    Application.put_env(:fahrgastrechte, BankDataCipher,
      active_key_version: 1,
      keys: %{}
    )

    assert %{
             "status" => "unavailable",
             "failed_checks" => ["crypto"]
           } =
             conn
             |> get(~p"/readyz")
             |> json_response(503)
  end
end
