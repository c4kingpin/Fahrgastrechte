defmodule FahrgastrechteWeb.ClaimLive.Index do
  use FahrgastrechteWeb, :live_view

  alias Fahrgastrechte.Claims

  @impl true
  def mount(_params, _session, socket) do
    filters = %{"route" => "", "claim_number" => "", "status" => "all"}

    {:ok,
     socket
     |> assign(:page_title, "Meine Anträge")
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> load_claims(filters)}
  end

  @impl true
  def handle_event("new_claim", _params, socket) do
    case Claims.create_claim(socket.assigns.current_scope) do
      {:ok, claim} ->
        {:noreply, push_navigate(socket, to: ~p"/antraege/#{claim.id}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Der Antrag konnte nicht angelegt werden.")}
    end
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply,
     socket
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> load_claims(filters)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="claims-dashboard" class={["space-y-8 pb-14"]}>
        <section class={[
          "relative overflow-hidden rounded-[2rem] bg-slate-950 px-6 py-8 text-white shadow-[0_30px_80px_-36px_rgba(15,23,42,0.65)] sm:px-9 sm:py-10"
        ]}>
          <div class={[
            "pointer-events-none absolute -right-24 -top-28 size-72 rounded-full bg-rose-600/25 blur-3xl"
          ]}>
          </div>
          <div class={["relative flex flex-col gap-7 lg:flex-row lg:items-end lg:justify-between"]}>
            <div class={["max-w-2xl"]}>
              <p class={["text-xs font-semibold uppercase tracking-[0.24em] text-rose-300"]}>
                Dein Arbeitsbereich
              </p>
              <h1 class={["mt-3 text-3xl font-semibold tracking-tight sm:text-4xl"]}>
                Fahrgastrechte-Anträge
              </h1>
              <p class={["mt-3 max-w-xl text-sm leading-6 text-slate-300 sm:text-base"]}>
                Lege einen Fall an, sichere Ticket und Rechnung und führe erkannte Angaben kontrolliert zusammen.
              </p>
            </div>
            <button
              id="new-claim-button"
              type="button"
              phx-click="new_claim"
              class={[
                "group inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-xl bg-rose-600 px-5 py-3 text-sm font-semibold text-white shadow-lg shadow-rose-950/30 transition hover:-translate-y-0.5 hover:bg-rose-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-300 sm:w-auto"
              ]}
            >
              <.icon name="hero-plus" class="size-5" /> Neuen Antrag beginnen
            </button>
          </div>
        </section>

        <section id="claim-stats" class={["grid gap-3 sm:grid-cols-3"]}>
          <article
            :for={
              {id, icon, value, label, style} <- [
                {"total", "hero-document-text", @counts.total, "Anträge gesamt",
                 "bg-rose-50 text-rose-700"},
                {"open", "hero-clock", @counts.open, "In Bearbeitung", "bg-amber-50 text-amber-700"},
                {"completed", "hero-check-badge", @counts.completed, "Erledigt",
                 "bg-emerald-50 text-emerald-700"}
              ]
            }
            id={"claim-stat-#{id}"}
            class={["rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"]}
          >
            <div class={["flex items-center justify-between"]}>
              <span class={["rounded-xl p-2.5", style]}><.icon name={icon} class="size-5" /></span>
              <strong class={["text-2xl font-semibold tracking-tight text-slate-950"]}>{value}</strong>
            </div>
            <p class={["mt-4 text-sm font-semibold text-slate-700"]}>{label}</p>
          </article>
        </section>

        <section class={["rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-7"]}>
          <div class={["flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between"]}>
            <div>
              <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-rose-700"]}>
                Übersicht
              </p>
              <h2 class={["mt-2 text-xl font-semibold tracking-tight text-slate-950"]}>
                Deine Fälle
              </h2>
            </div>

            <.form
              for={@filter_form}
              id="claim-filter-form"
              phx-change="filter"
              class={["grid w-full gap-3 sm:grid-cols-3 lg:max-w-3xl"]}
            >
              <.input
                field={@filter_form[:route]}
                id="claim-route-filter"
                label="Strecke"
                placeholder="z. B. Berlin"
                phx-debounce="300"
              />
              <.input
                field={@filter_form[:claim_number]}
                id="claim-number-filter"
                label="Antragsnummer"
                placeholder="FR-2026-…"
                phx-debounce="300"
              />
              <.input
                field={@filter_form[:status]}
                id="claim-status-filter"
                type="select"
                label="Status"
                options={[
                  {"Alle Status", "all"},
                  {"Entwurf", "draft"},
                  {"Druckfertig", "ready"},
                  {"Versendet", "sent"},
                  {"Erledigt", "completed"}
                ]}
              />
            </.form>
          </div>

          <div id="claims" phx-update="stream" class={["mt-6 grid gap-3"]}>
            <div
              id="claims-empty"
              class={[
                "hidden rounded-2xl border border-dashed border-slate-300 bg-slate-50 px-6 py-12 text-center only:block"
              ]}
            >
              <span class={[
                "mx-auto flex size-12 items-center justify-center rounded-2xl bg-white text-slate-400 shadow-sm"
              ]}>
                <.icon name="hero-inbox" class="size-6" />
              </span>
              <h3 class={["mt-4 text-sm font-semibold text-slate-900"]}>Keine passenden Anträge</h3>
              <p class={["mt-1 text-sm text-slate-500"]}>
                Passe die Filter an oder beginne einen neuen Fall.
              </p>
            </div>

            <.link
              :for={{dom_id, claim} <- @streams.claims}
              id={dom_id}
              navigate={~p"/antraege/#{claim.id}"}
              class={[
                "group grid gap-4 rounded-2xl border border-slate-200 px-4 py-4 transition hover:-translate-y-0.5 hover:border-slate-300 hover:bg-slate-50 hover:shadow-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center sm:px-5"
              ]}
            >
              <div class={["min-w-0"]}>
                <div class={["flex flex-wrap items-center gap-2"]}>
                  <span class={["truncate text-sm font-semibold text-slate-950"]}>{claim.claim_number}</span>
                  <span class={[
                    "rounded-full px-2.5 py-1 text-[0.68rem] font-bold uppercase tracking-wide",
                    status_style(claim.status)
                  ]}>
                    {status_label(claim.status)}
                  </span>
                </div>
                <p class={["mt-2 truncate text-sm font-medium text-slate-700"]}>
                  {route_label(claim)}
                </p>
                <p class={["mt-1 text-xs text-slate-500"]}>{date_label(claim.travel_date)}</p>
              </div>
              <span class={["inline-flex items-center gap-2 text-sm font-semibold text-rose-700"]}>
                Öffnen
                <.icon
                  name="hero-arrow-right"
                  class="size-4 transition-transform group-hover:translate-x-0.5"
                />
              </span>
            </.link>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp load_claims(socket, filters) do
    scope = socket.assigns.current_scope
    {:ok, all_claims} = Claims.list_claims(scope)
    {:ok, filtered_claims} = Claims.list_claims(scope, normalize_filters(filters))

    counts = %{
      total: length(all_claims),
      open: Enum.count(all_claims, &(&1.status != :completed)),
      completed: Enum.count(all_claims, &(&1.status == :completed))
    }

    socket
    |> assign(:counts, counts)
    |> assign(:claims_empty?, filtered_claims == [])
    |> stream(:claims, filtered_claims, reset: true)
  end

  defp normalize_filters(filters) do
    %{}
    |> maybe_filter(:route, Map.get(filters, "route"))
    |> maybe_filter(:claim_number, Map.get(filters, "claim_number"))
    |> maybe_status(Map.get(filters, "status"))
  end

  defp maybe_filter(filters, _key, value) when value in [nil, ""], do: filters
  defp maybe_filter(filters, key, value), do: Map.put(filters, key, value)

  defp maybe_status(filters, status) when status in ["draft", "ready", "sent", "completed"],
    do: Map.put(filters, :status, status)

  defp maybe_status(filters, _status), do: filters

  defp route_label(%{origin: origin, destination: destination})
       when is_binary(origin) and is_binary(destination),
       do: "#{origin} → #{destination}"

  defp route_label(_claim), do: "Strecke noch offen"

  defp date_label(%Date{} = date), do: Calendar.strftime(date, "%d.%m.%Y")
  defp date_label(_date), do: "Reisedatum noch offen"

  defp status_label(:draft), do: "Entwurf"
  defp status_label(:ready), do: "Druckfertig"
  defp status_label(:sent), do: "Versendet"
  defp status_label(:completed), do: "Erledigt"

  defp status_style(:draft), do: "bg-amber-50 text-amber-800"
  defp status_style(:ready), do: "bg-sky-50 text-sky-800"
  defp status_style(:sent), do: "bg-violet-50 text-violet-800"
  defp status_style(:completed), do: "bg-emerald-50 text-emerald-800"
end
