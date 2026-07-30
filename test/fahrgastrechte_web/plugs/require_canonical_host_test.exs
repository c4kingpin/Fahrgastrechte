defmodule FahrgastrechteWeb.Plugs.RequireCanonicalHostTest do
  use FahrgastrechteWeb.ConnCase, async: false

  alias FahrgastrechteWeb.Plugs.RequireCanonicalHost

  setup do
    original_value = Application.get_env(:fahrgastrechte, :canonical_host)

    on_exit(fn ->
      if original_value do
        Application.put_env(:fahrgastrechte, :canonical_host, original_value)
      else
        Application.delete_env(:fahrgastrechte, :canonical_host)
      end
    end)

    :ok
  end

  test "allows the configured canonical host", %{conn: conn} do
    Application.put_env(:fahrgastrechte, :canonical_host, "fahrgastrechte.example.org")
    conn = %{conn | host: "Fahrgastrechte.Example.Org"}

    refute RequireCanonicalHost.call(conn, []).halted
  end

  test "rejects a different forwarded host", %{conn: conn} do
    Application.put_env(:fahrgastrechte, :canonical_host, "fahrgastrechte.example.org")
    conn = %{conn | host: "attacker.example.org"}

    conn = RequireCanonicalHost.call(conn, [])

    assert conn.halted
    assert conn.status == 421
    assert conn.resp_body == "Misdirected Request"
  end

  test "is disabled outside configured production runtime", %{conn: conn} do
    Application.delete_env(:fahrgastrechte, :canonical_host)
    conn = %{conn | host: "development.local"}

    refute RequireCanonicalHost.call(conn, []).halted
  end
end
