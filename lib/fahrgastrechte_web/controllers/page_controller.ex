defmodule FahrgastrechteWeb.PageController do
  use FahrgastrechteWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
