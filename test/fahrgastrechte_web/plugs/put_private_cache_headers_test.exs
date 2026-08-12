defmodule FahrgastrechteWeb.Plugs.PutPrivateCacheHeadersTest do
  use FahrgastrechteWeb.ConnCase, async: true

  alias FahrgastrechteWeb.Plugs.PutPrivateCacheHeaders

  test "marks authenticated page responses as private and non-cacheable", %{conn: conn} do
    conn = PutPrivateCacheHeaders.call(conn, [])

    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end
end
