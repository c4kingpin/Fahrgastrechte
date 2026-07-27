defmodule FahrgastrechteWeb.Layouts do
  @moduledoc """
  Shared application layouts and feedback components.
  """
  use FahrgastrechteWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current authenticated scope"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#f7f7f5] text-slate-900">
      <header class="sticky top-0 z-40 border-b border-slate-200/80 bg-[#f7f7f5]/90 backdrop-blur-xl">
        <div class="mx-auto flex h-16 max-w-7xl items-center justify-between gap-6 px-4 sm:h-[4.5rem] sm:px-6 lg:px-8">
          <.link
            id="brand-link"
            href={~p"/"}
            class="group flex w-fit items-center gap-3 rounded-lg focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-rose-700"
          >
            <span class="flex size-9 items-center justify-center rounded-xl bg-slate-950 text-white shadow-sm transition group-hover:bg-rose-700">
              <img src={~p"/images/logo.svg"} width="23" height="23" alt="" />
            </span>
            <span>
              <span class="block text-[0.95rem] font-bold leading-none tracking-[-0.02em] text-slate-950">Fahrgastrechte</span>
              <span class="mt-1 hidden text-[0.62rem] font-semibold uppercase leading-none tracking-[0.16em] text-slate-400 sm:block">Antragshilfe</span>
            </span>
          </.link>

          <nav aria-label="Hauptnavigation" class="flex items-center gap-1 sm:gap-2">
            <%= if @current_scope do %>
              <.link
                id="claims-nav-link"
                navigate={~p"/antraege"}
                class="inline-flex min-h-10 items-center gap-2 rounded-lg px-2.5 py-2 text-sm font-semibold text-slate-600 transition hover:bg-white hover:text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700 sm:px-3"
              >
                <.icon name="hero-document-text" class="size-4" />
                <span class="hidden sm:inline">Anträge</span>
              </.link>
              <.link
                id="profile-nav-link"
                navigate={~p"/profil"}
                class="inline-flex min-h-10 items-center gap-2 rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm font-semibold text-slate-700 shadow-sm transition hover:-translate-y-px hover:border-slate-300 hover:text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700 sm:px-4"
              >
                <span class="flex size-6 items-center justify-center rounded-full bg-rose-100 text-[0.65rem] font-bold uppercase text-rose-800">
                  {user_initial(@current_scope)}
                </span>
                <span class="hidden sm:inline">Profil</span>
              </.link>
            <% else %>
              <.link
                href={~p"/"}
                class="hidden rounded-lg px-3 py-2 text-sm font-semibold text-slate-600 transition hover:bg-white hover:text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700 sm:inline-flex"
              >
                Übersicht
              </.link>
              <a
                href="/#ablauf"
                class="hidden rounded-lg px-3 py-2 text-sm font-semibold text-slate-600 transition hover:bg-white hover:text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700 md:inline-flex"
              >
                Ablauf
              </a>
              <span
                id="auth-status"
                class="inline-flex min-h-10 items-center gap-2 rounded-xl border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-500 shadow-sm sm:px-4"
              >
                <span class="size-2 rounded-full bg-amber-400"></span>
                <span class="hidden sm:inline">Anmeldung folgt</span>
              </span>
            <% end %>
          </nav>
        </div>
      </header>

      <main class="mx-auto max-w-7xl px-4 pt-6 sm:px-6 sm:pt-8 lg:px-8 lg:pt-10">
        {render_slot(@inner_block)}
      </main>

      <footer class="border-t border-slate-200 bg-white/60">
        <div class="mx-auto flex max-w-7xl flex-col gap-3 px-4 py-7 text-xs text-slate-500 sm:flex-row sm:items-center sm:justify-between sm:px-6 lg:px-8">
          <p>Private Anwendung zur Vorbereitung von Fahrgastrechte-Anträgen.</p>
          <p class="inline-flex items-center gap-1.5">
            <.icon name="hero-lock-closed" class="size-3.5" /> Sensible Angaben bleiben geschützt.
          </p>
        </div>
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  defp user_initial(%{user: %{display_name: display_name}})
       when is_binary(display_name) and display_name != "" do
    display_name
    |> String.first()
    |> String.upcase()
  end

  defp user_initial(_current_scope), do: "P"
end
