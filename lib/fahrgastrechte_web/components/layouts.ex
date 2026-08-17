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

  attr :current_section, :atom,
    default: nil,
    values: [nil, :home, :claims, :profile, :sources],
    doc: "the active top-level navigation section"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class={[
      "min-h-screen bg-[#f7f7f5] pb-20 text-slate-900 md:pb-0"
    ]}>
      <header class="sticky top-0 z-40 border-b border-slate-200/80 bg-[#f7f7f5]/90 backdrop-blur-xl">
        <div class={[
          "mx-auto flex h-16 max-w-7xl items-center justify-between gap-4 px-4 sm:h-[4.5rem] sm:px-6 lg:px-8"
        ]}>
          <.link
            id="brand-link"
            href={~p"/"}
            aria-current={if(@current_section == :home, do: "page", else: nil)}
            class={[
              "group flex w-fit items-center gap-3 rounded-lg focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-rose-700"
            ]}
          >
            <span class={[
              "flex size-9 items-center justify-center rounded-xl bg-slate-950 text-white shadow-sm transition group-hover:bg-rose-700"
            ]}>
              <img src={~p"/images/logo.svg"} width="23" height="23" alt="" />
            </span>
            <span>
              <span class={[
                "block text-[0.95rem] font-bold leading-none tracking-[-0.02em] text-slate-950"
              ]}>Fahrgastrechte</span>
              <span class={[
                "mt-1 hidden text-[0.62rem] font-semibold uppercase leading-none tracking-[0.16em] text-slate-400 sm:block"
              ]}>Antragshilfe</span>
            </span>
          </.link>

          <nav
            aria-label="Hauptnavigation"
            class={[
              "flex items-center gap-1.5 sm:gap-2"
            ]}
          >
            <%= if @current_scope do %>
              <div class={[
                "hidden items-center gap-1 md:flex"
              ]}>
                <.link
                  id="home-nav-link"
                  href={~p"/"}
                  aria-current={if(@current_section == :home, do: "page", else: nil)}
                  class={nav_link_class(@current_section == :home)}
                >
                  <.icon name="hero-home" class="size-4" /> Übersicht
                </.link>
                <.link
                  id="claims-nav-link"
                  navigate={~p"/antraege"}
                  aria-current={if(@current_section == :claims, do: "page", else: nil)}
                  class={nav_link_class(@current_section == :claims)}
                >
                  <.icon name="hero-document-text" class="size-4" /> Anträge
                </.link>
                <.link
                  id="profile-nav-link"
                  navigate={~p"/profil"}
                  aria-current={if(@current_section == :profile, do: "page", else: nil)}
                  class={nav_link_class(@current_section == :profile)}
                >
                  <.icon name="hero-user-circle" class="size-4" /> Profil
                </.link>
                <.link
                  id="sources-nav-link"
                  navigate={~p"/datenquellen"}
                  aria-current={if(@current_section == :sources, do: "page", else: nil)}
                  class={nav_link_class(@current_section == :sources)}
                >
                  <.icon name="hero-circle-stack" class="size-4" /> Datenquellen
                </.link>
              </div>

              <.link
                id="logout-link"
                href={~p"/abmelden"}
                method="delete"
                title="Abmelden"
                class={[
                  "inline-flex min-h-10 items-center gap-2 rounded-xl border border-slate-200 bg-white px-2.5 py-2 text-sm font-semibold text-slate-700 shadow-sm transition hover:-translate-y-px hover:border-slate-300 hover:text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700 sm:px-3"
                ]}
              >
                <span class={[
                  "flex size-6 items-center justify-center rounded-full bg-rose-100 text-[0.65rem] font-bold uppercase text-rose-800"
                ]}>
                  {user_initial(@current_scope)}
                </span>
                <span class={[
                  "hidden lg:inline"
                ]}>Abmelden</span>
                <.icon name="hero-arrow-right-start-on-rectangle" class="hidden size-4 sm:block" />
              </.link>
            <% else %>
              <.link
                href={~p"/"}
                aria-current={if(@current_section == :home, do: "page", else: nil)}
                class={[
                  "hidden rounded-lg px-3 py-2 text-sm font-semibold text-slate-600 transition hover:bg-white hover:text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700 sm:inline-flex"
                ]}
              >
                Übersicht
              </.link>
              <a
                href="/#ablauf"
                class={[
                  "hidden rounded-lg px-3 py-2 text-sm font-semibold text-slate-600 transition hover:bg-white hover:text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700 md:inline-flex"
                ]}
              >
                Ablauf
              </a>
              <.link
                id="login-link"
                href={~p"/anmelden"}
                class={[
                  "inline-flex min-h-10 items-center gap-2 rounded-xl bg-slate-950 px-3.5 py-2 text-sm font-semibold text-white shadow-sm transition hover:-translate-y-px hover:bg-rose-700 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700 sm:px-4"
                ]}
              >
                <.icon name="hero-lock-closed" class="size-4" /> Anmelden
              </.link>
            <% end %>
          </nav>
        </div>
      </header>

      <main
        id="main-content"
        class={[
          "mx-auto max-w-7xl px-4 pt-6 sm:px-6 sm:pt-8 lg:px-8 lg:pt-10"
        ]}
      >
        {render_slot(@inner_block)}
      </main>

      <footer class={[
        "border-t border-slate-200 bg-white/60"
      ]}>
        <div class={[
          "mx-auto flex max-w-7xl flex-col gap-3 px-4 py-7 text-xs text-slate-500 sm:flex-row sm:items-center sm:justify-between sm:px-6 lg:px-8"
        ]}>
          <p>Private Anwendung zur Vorbereitung von Fahrgastrechte-Anträgen.</p>
          <p class={[
            "inline-flex items-center gap-1.5"
          ]}>
            <.icon name="hero-lock-closed" class="size-3.5" /> Sensible Angaben bleiben geschützt.
          </p>
        </div>
      </footer>

      <nav
        :if={@current_scope}
        id="mobile-navigation"
        aria-label="Mobile Hauptnavigation"
        class={[
          "fixed inset-x-3 bottom-3 z-50 grid grid-cols-4 rounded-2xl border border-slate-200/80 bg-white/95 p-1.5 shadow-[0_18px_50px_-20px_rgba(15,23,42,0.55)] backdrop-blur-xl md:hidden"
        ]}
      >
        <.link
          id="mobile-home-nav-link"
          href={~p"/"}
          aria-current={if(@current_section == :home, do: "page", else: nil)}
          class={mobile_nav_link_class(@current_section == :home)}
        >
          <.icon name="hero-home" class="size-5" />
          <span>Übersicht</span>
        </.link>
        <.link
          id="mobile-claims-nav-link"
          navigate={~p"/antraege"}
          aria-current={if(@current_section == :claims, do: "page", else: nil)}
          class={mobile_nav_link_class(@current_section == :claims)}
        >
          <.icon name="hero-document-text" class="size-5" />
          <span>Anträge</span>
        </.link>
        <.link
          id="mobile-profile-nav-link"
          navigate={~p"/profil"}
          aria-current={if(@current_section == :profile, do: "page", else: nil)}
          class={mobile_nav_link_class(@current_section == :profile)}
        >
          <.icon name="hero-user-circle" class="size-5" />
          <span>Profil</span>
        </.link>
        <.link
          id="mobile-sources-nav-link"
          navigate={~p"/datenquellen"}
          aria-current={if(@current_section == :sources, do: "page", else: nil)}
          class={mobile_nav_link_class(@current_section == :sources)}
        >
          <.icon name="hero-circle-stack" class="size-5" />
          <span>Daten</span>
        </.link>
      </nav>
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

  defp nav_link_class(active?) do
    [
      "inline-flex min-h-10 items-center gap-2 rounded-lg px-3 py-2 text-sm font-semibold transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700",
      if(active?,
        do: "bg-slate-950 text-white shadow-sm",
        else: "text-slate-600 hover:bg-white hover:text-slate-950"
      )
    ]
  end

  defp mobile_nav_link_class(active?) do
    [
      "flex min-h-14 flex-col items-center justify-center gap-1 rounded-xl text-[0.68rem] font-semibold transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-rose-700",
      if(active?,
        do: "bg-slate-950 text-white shadow-sm",
        else: "text-slate-500 hover:bg-slate-100 hover:text-slate-950"
      )
    ]
  end

  defp user_initial(%{user: %{display_name: display_name}})
       when is_binary(display_name) and display_name != "" do
    display_name
    |> String.first()
    |> String.upcase()
  end

  defp user_initial(_current_scope), do: "P"
end
