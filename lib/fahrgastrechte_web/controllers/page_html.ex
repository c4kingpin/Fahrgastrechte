defmodule FahrgastrechteWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use FahrgastrechteWeb, :html

  import FahrgastrechteWeb.ClaimLive.Presentation,
    only: [route_label: 1, status_label: 1, status_style: 2, format_datetime: 1]

  embed_templates "page_html/*"

  defp continue_cta_label(status) when status in [:draft, :ready], do: "Antrag fortsetzen"
  defp continue_cta_label(_status), do: "Antrag ansehen"
end
