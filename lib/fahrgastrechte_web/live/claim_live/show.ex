defmodule FahrgastrechteWeb.ClaimLive.Show do
  use FahrgastrechteWeb, :live_view

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Exports
  alias Fahrgastrechte.Rail
  alias Fahrgastrechte.Rail.BerlinTime
  alias Fahrgastrechte.Tickets

  @upload_kinds [:ticket, :invoice]

  @impl true
  def mount(%{"id" => claim_id}, _session, socket) do
    case Claims.get_claim(socket.assigns.current_scope, claim_id) do
      {:ok, claim} ->
        max_file_size = documents_config(:max_file_size_bytes)

        socket =
          socket
          |> assign(:page_title, "Antrag #{claim.claim_number}")
          |> assign(:save_state, :saved)
          |> assign(:connection_search_state, :idle)
          |> assign(:candidate_lookup, %{})
          |> assign(:export_state, :idle)
          |> assign(:upload_forms, upload_forms())
          |> assign(:max_file_size_label, format_bytes(max_file_size))
          |> stream(:connection_candidates, [])
          |> allow_upload(:ticket,
            accept: ~w(.pdf),
            max_entries: 1,
            max_file_size: max_file_size,
            auto_upload: true,
            progress: &handle_progress/3
          )
          |> allow_upload(:invoice,
            accept: ~w(.pdf),
            max_entries: 1,
            max_file_size: max_file_size,
            auto_upload: true,
            progress: &handle_progress/3
          )
          |> load_workspace(claim)

        {:ok, socket}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Dieser Antrag wurde nicht gefunden.")
         |> redirect(to: ~p"/antraege")}
    end
  end

  @impl true
  def handle_event("claim_autosave", %{"claim" => params}, socket) do
    {:noreply, persist_claim(socket, params, false)}
  end

  def handle_event("claim_save", %{"claim" => params}, socket) do
    {:noreply, persist_claim(socket, params, true)}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("search_connections", %{"connection_search" => params}, socket) do
    socket = assign(socket, :connection_search_form, to_form(params, as: :connection_search))

    case find_connections(socket, params) do
      {:ok, candidates} ->
        indexed = Enum.with_index(candidates, 1)

        lookup =
          Map.new(indexed, fn {candidate, index} -> {Integer.to_string(index), candidate} end)

        items = Enum.map(indexed, fn {candidate, index} -> %{id: index, candidate: candidate} end)

        {:noreply,
         socket
         |> assign(:candidate_lookup, lookup)
         |> assign(:connection_search_state, if(candidates == [], do: :empty, else: :results))
         |> stream(:connection_candidates, items, reset: true)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:candidate_lookup, %{})
         |> assign(:connection_search_state, {:error, reason})
         |> stream(:connection_candidates, [], reset: true)}
    end
  end

  def handle_event("choose_connection", %{"index" => index}, socket) do
    with candidate when not is_nil(candidate) <- Map.get(socket.assigns.candidate_lookup, index),
         segments when segments != [] <- candidate_segments(candidate, socket.assigns.claim),
         {:ok, %{claim: claim}} <-
           Rail.confirm_journey(
             socket.assigns.current_scope,
             socket.assigns.claim.id,
             :planned,
             planned_segments(segments),
             socket.assigns.claim.lock_version
           ),
         {:ok, %{claim: claim}} <-
           Rail.confirm_journey(
             socket.assigns.current_scope,
             socket.assigns.claim.id,
             :actual,
             segments,
             claim.lock_version
           ) do
      {:noreply,
       socket
       |> load_workspace(claim)
       |> put_flash(
         :info,
         "Die Verbindung und ihre aktuelle Verspätung wurden als Vorschlag übernommen."
       )}
    else
      {:error, :stale} ->
        {:noreply, handle_stale(socket)}

      _reason ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Die Verbindung konnte nicht übernommen werden. Bitte nutze die manuelle Eingabe."
         )}
    end
  end

  def handle_event("save_planned_journey", %{"planned" => params}, socket) do
    with {:ok, segment} <- build_planned_segment(params),
         {:ok, %{claim: claim}} <-
           Rail.confirm_journey(
             socket.assigns.current_scope,
             socket.assigns.claim.id,
             :planned,
             [segment],
             socket.assigns.claim.lock_version
           ) do
      {:noreply,
       socket
       |> load_workspace(claim)
       |> put_flash(:info, "Die geplante Verbindung wurde bestätigt.")}
    else
      {:error, :stale} ->
        {:noreply, handle_stale(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:planned_form, to_form(params, as: :planned))
         |> put_flash(:error, journey_error_message(reason))}
    end
  end

  def handle_event("set_disruption", %{"type" => type}, socket)
      when type in ["delay", "cancellation"] do
    {:noreply, persist_claim(socket, %{"disruption_cause" => type}, false)}
  end

  def handle_event("save_actual_journey", %{"actual" => params}, socket) do
    with {:ok, segments} <- build_actual_segments(params, socket.assigns),
         {:ok, %{claim: claim}} <-
           Rail.confirm_journey(
             socket.assigns.current_scope,
             socket.assigns.claim.id,
             :actual,
             segments,
             socket.assigns.claim.lock_version
           ) do
      {:noreply,
       socket
       |> load_workspace(claim)
       |> put_flash(:info, "Der tatsächliche Reiseverlauf wurde bestätigt.")}
    else
      {:error, :stale} ->
        {:noreply, handle_stale(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:actual_form, to_form(params, as: :actual))
         |> put_flash(:error, journey_error_message(reason))}
    end
  end

  def handle_event("generate_export", _params, socket) do
    socket = assign(socket, :export_state, :generating)

    case Exports.generate_export(
           socket.assigns.current_scope,
           socket.assigns.claim.id,
           socket.assigns.claim.lock_version
         ) do
      {:ok, %{claim: claim}} ->
        {:noreply,
         socket
         |> assign(:export_state, :idle)
         |> load_workspace(claim)
         |> put_flash(:info, "Das druckfertige Gesamt-PDF wurde erstellt.")}

      {:error, :stale} ->
        {:noreply, handle_stale(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:export_state, :idle)
         |> put_flash(:error, export_error_message(reason))}
    end
  end

  def handle_event("reanalyze_document", %{"id" => document_id}, socket) do
    case Tickets.analyze_document(socket.assigns.current_scope, document_id) do
      {:ok, _analysis} ->
        {:noreply,
         socket
         |> refresh_workspace()
         |> put_flash(:info, "Das Dokument wurde erneut ausgewertet.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Die Auswertung konnte nicht gestartet werden.")}
    end
  end

  def handle_event("delete_document", %{"id" => document_id}, socket) do
    case Documents.delete_document(
           socket.assigns.current_scope,
           document_id,
           socket.assigns.claim.lock_version
         ) do
      {:ok, _claim_or_deleted} ->
        {:noreply,
         socket
         |> refresh_workspace()
         |> put_flash(:info, "Das Dokument wurde sicher gelöscht.")}

      {:error, :stale} ->
        {:noreply, handle_stale(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Das Dokument konnte nicht gelöscht werden.")}
    end
  end

  def handle_event("set_suggestion_state", %{"id" => suggestion_id, "state" => state}, socket) do
    case state do
      "accepted" -> {:noreply, accept_suggestion(socket, suggestion_id)}
      "rejected" -> {:noreply, update_suggestion_state(socket, suggestion_id, :rejected)}
      _other -> {:noreply, put_flash(socket, :error, "Unbekannte Vorschlagsaktion.")}
    end
  end

  def handle_event("transition_claim", %{"status" => status}, socket) do
    with {:ok, target_status} <- transition_status(status),
         {:ok, claim} <-
           Claims.transition_claim(
             socket.assigns.current_scope,
             socket.assigns.claim.id,
             target_status,
             socket.assigns.claim.lock_version
           ) do
      {:noreply,
       socket
       |> load_workspace(claim)
       |> put_flash(:info, transition_message(target_status))}
    else
      {:error, :stale} ->
        {:noreply, handle_stale(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Der Status konnte nicht geändert werden.")}
    end
  end

  def handle_event("delete_claim", _params, socket) do
    case Documents.delete_claim(
           socket.assigns.current_scope,
           socket.assigns.claim.id,
           socket.assigns.claim.lock_version
         ) do
      {:ok, _claim} ->
        {:noreply,
         socket
         |> put_flash(:info, "Der Antrag und seine Dokumente wurden gelöscht.")
         |> push_navigate(to: ~p"/antraege")}

      {:error, :stale} ->
        {:noreply, handle_stale(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Der Antrag konnte nicht gelöscht werden.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_section={:claims}>
      <div id="claim-workspace" class={["space-y-7 pb-14"]}>
        <section class={[
          "overflow-hidden rounded-[2rem] bg-slate-950 px-6 py-7 text-white shadow-[0_30px_80px_-38px_rgba(15,23,42,0.7)] sm:px-9 sm:py-9"
        ]}>
          <div class={["flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between"]}>
            <div class={["min-w-0"]}>
              <.link
                id="claims-back-link"
                navigate={~p"/antraege"}
                class={[
                  "inline-flex items-center gap-2 text-xs font-semibold text-slate-300 transition hover:text-white"
                ]}
              >
                <.icon name="hero-arrow-left" class="size-4" /> Alle Anträge
              </.link>
              <div class={["mt-5 flex flex-wrap items-center gap-3"]}>
                <h1 class={["truncate text-2xl font-semibold tracking-tight sm:text-3xl"]}>
                  {@claim.claim_number}
                </h1>
                <span
                  id="claim-status"
                  class={[
                    "rounded-full px-3 py-1 text-xs font-bold uppercase tracking-wide",
                    status_style(@claim.status)
                  ]}
                >
                  {status_label(@claim.status)}
                </span>
              </div>
              <p class={["mt-2 text-sm text-slate-300"]}>{route_label(@claim)}</p>
            </div>

            <div
              id="workspace-progress"
              class={["w-full max-w-sm rounded-2xl border border-white/10 bg-white/5 p-4"]}
            >
              <div class={["flex items-center justify-between text-xs font-semibold"]}>
                <span class={["text-slate-300"]}>Bearbeitungsbereiche</span>
                <span>{@completed_steps} von 6 bestätigt</span>
              </div>
              <div
                class={["mt-3 h-2 overflow-hidden rounded-full bg-white/10"]}
                role="progressbar"
                aria-label="Fortschritt der verfügbaren Schritte"
                aria-valuemin="0"
                aria-valuemax="6"
                aria-valuenow={@completed_steps}
              >
                <div
                  class={["h-full rounded-full bg-rose-500 transition-all"]}
                  style={"width: #{round(@completed_steps / 6 * 100)}%"}
                >
                </div>
              </div>
            </div>
          </div>
        </section>

        <div class={["grid gap-7 xl:grid-cols-[minmax(0,1.45fr)_minmax(20rem,0.75fr)]"]}>
          <div class={["space-y-7"]}>
            <section
              id="claim-data-section"
              class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
            >
              <div class={["flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"]}>
                <div>
                  <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-rose-700"]}>
                    Schritt 1
                  </p>
                  <h2 class={["mt-2 text-xl font-semibold text-slate-950"]}>Falldaten</h2>
                  <p class={["mt-1 text-sm leading-6 text-slate-500"]}>
                    Änderungen werden automatisch gespeichert. Bestätigte Ticketwerte können direkt übernommen werden.
                  </p>
                </div>
                <span
                  id="claim-save-state"
                  class={[
                    "inline-flex w-fit items-center gap-2 rounded-full px-3 py-1.5 text-xs font-semibold",
                    save_state_style(@save_state)
                  ]}
                >
                  <span class={["size-2 rounded-full bg-current"]}></span>
                  {save_state_label(@save_state)}
                </span>
              </div>

              <.form
                for={@claim_form}
                id="claim-form"
                phx-change="claim_autosave"
                phx-submit="claim_save"
                class={["mt-6 space-y-5"]}
              >
                <div class={["grid gap-5 sm:grid-cols-2"]}>
                  <.input
                    field={@claim_form[:travel_date]}
                    id="claim-travel-date"
                    type="date"
                    label="Reisedatum"
                    disabled={!editable?(@claim.status)}
                    phx-debounce="500"
                  />
                  <.input
                    field={@claim_form[:journey_outcome]}
                    id="claim-journey-outcome"
                    type="select"
                    label="Reiseverlauf"
                    prompt="Bitte auswählen"
                    options={[
                      {"Verspätet am Ziel angekommen", "delayed_arrival"},
                      {"Reise nicht angetreten", "not_started"},
                      {"Reise abgebrochen", "aborted"},
                      {"Mit anderem Verkehrsmittel weitergefahren", "continued_with_other_transport"}
                    ]}
                    disabled={!editable?(@claim.status)}
                  />
                  <.input
                    field={@claim_form[:disruption_cause]}
                    id="claim-disruption-cause"
                    type="select"
                    label="Ursache"
                    prompt="Bitte auswählen"
                    options={[
                      {"Verspätung", "delay"},
                      {"Zugausfall", "cancellation"},
                      {"Anschlussverlust", "missed_connection"}
                    ]}
                    disabled={!editable?(@claim.status)}
                  />
                  <.input
                    field={@claim_form[:journey_direction]}
                    id="claim-journey-direction"
                    type="select"
                    label="Fahrtrichtung"
                    options={[{"Hinfahrt", "outbound"}, {"Rückfahrt", "return"}]}
                    disabled={!editable?(@claim.status)}
                  />
                  <.input
                    field={@claim_form[:origin]}
                    id="claim-origin"
                    label="Startbahnhof"
                    placeholder="z. B. Frankfurt (Main) Hbf"
                    disabled={!editable?(@claim.status)}
                    phx-debounce="500"
                  />
                  <.input
                    field={@claim_form[:destination]}
                    id="claim-destination"
                    label="Zielbahnhof"
                    placeholder="z. B. Berlin Hbf"
                    disabled={!editable?(@claim.status)}
                    phx-debounce="500"
                  />
                </div>
                <div class={["flex justify-end"]}>
                  <button
                    id="claim-save-button"
                    type="submit"
                    disabled={!editable?(@claim.status)}
                    class={[
                      "inline-flex min-h-11 items-center gap-2 rounded-xl bg-slate-950 px-4 py-2.5 text-sm font-semibold text-white transition hover:-translate-y-0.5 hover:bg-slate-800 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-slate-950 disabled:cursor-not-allowed disabled:opacity-40"
                    ]}
                  >
                    <.icon name="hero-check" class="size-4" /> Jetzt speichern
                  </button>
                </div>
              </.form>
            </section>

            <section
              id="claim-documents-section"
              class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
            >
              <div>
                <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-rose-700"]}>
                  Schritt 2
                </p>
                <h2 class={["mt-2 text-xl font-semibold text-slate-950"]}>Ticket & Rechnung</h2>
                <p class={["mt-1 text-sm leading-6 text-slate-500"]}>
                  Nur PDF, maximal {@max_file_size_label}. Dateien werden privat gespeichert und nie öffentlich verlinkt.
                </p>
              </div>

              <div class={["mt-6 grid gap-4 lg:grid-cols-2"]}>
                <%= for kind <- @upload_kinds do %>
                  <% document = Map.get(@documents_by_kind, kind) %>
                  <% upload = Map.fetch!(@uploads, kind) %>
                  <% upload_form = Map.fetch!(@upload_forms, kind) %>
                  <article
                    id={"#{kind}-document-card"}
                    class={["rounded-2xl border border-slate-200 bg-slate-50 p-4 sm:p-5"]}
                  >
                    <div class={["flex items-start justify-between gap-3"]}>
                      <div class={["flex items-start gap-3"]}>
                        <span class={["rounded-xl bg-white p-2.5 text-rose-700 shadow-sm"]}>
                          <.icon
                            name={
                              if(kind == :ticket, do: "hero-ticket", else: "hero-receipt-percent")
                            }
                            class="size-5"
                          />
                        </span>
                        <div>
                          <h3 class={["text-sm font-semibold text-slate-950"]}>
                            {document_kind_label(kind)}
                          </h3>
                          <p class={["mt-0.5 text-xs text-slate-500"]}>
                            {if(document, do: "Sicher gespeichert", else: "Noch nicht vorhanden")}
                          </p>
                        </div>
                      </div>
                      <span class={[
                        "size-2.5 rounded-full",
                        if(document, do: "bg-emerald-500", else: "bg-slate-300")
                      ]}></span>
                    </div>

                    <%= if document do %>
                      <div class={["mt-5 rounded-xl bg-white p-3.5 shadow-sm"]}>
                        <p class={["truncate text-sm font-semibold text-slate-800"]}>
                          {document.original_filename}
                        </p>
                        <p class={["mt-1 text-xs text-slate-500"]}>
                          {format_bytes(document.size_bytes)} · {document.page_count} {if(
                            document.page_count == 1,
                            do: "Seite",
                            else: "Seiten"
                          )}
                        </p>
                        <div class={["mt-3 flex flex-wrap items-center gap-2"]}>
                          <span class={[
                            "rounded-full px-2.5 py-1 text-[0.68rem] font-bold",
                            analysis_style(document.analysis_status)
                          ]}>
                            {analysis_label(document.analysis_status)}
                          </span>
                        </div>
                      </div>
                      <div class={["mt-3 flex flex-wrap gap-2"]}>
                        <a
                          id={"download-#{kind}"}
                          href={~p"/dokumente/#{document.id}/download"}
                          class={[
                            "inline-flex min-h-10 items-center gap-2 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-700 transition hover:border-slate-300 hover:text-slate-950"
                          ]}
                        >
                          <.icon name="hero-arrow-down-tray" class="size-4" /> Öffnen
                        </a>
                        <button
                          id={"reanalyze-#{kind}"}
                          type="button"
                          phx-click="reanalyze_document"
                          phx-value-id={document.id}
                          class={[
                            "inline-flex min-h-10 items-center gap-2 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-700 transition hover:border-slate-300 hover:text-slate-950"
                          ]}
                        >
                          <.icon name="hero-arrow-path" class="size-4" /> Neu auswerten
                        </button>
                        <button
                          id={"delete-document-#{kind}"}
                          type="button"
                          phx-click="delete_document"
                          phx-value-id={document.id}
                          data-confirm="Dieses Dokument wirklich löschen?"
                          class={[
                            "inline-flex min-h-10 items-center gap-2 rounded-lg px-3 py-2 text-xs font-semibold text-rose-700 transition hover:bg-rose-50"
                          ]}
                        >
                          <.icon name="hero-trash" class="size-4" /> Löschen
                        </button>
                      </div>
                    <% else %>
                      <.form
                        for={upload_form}
                        id={"#{kind}-upload-form"}
                        phx-change="validate_upload"
                        class={["mt-5"]}
                      >
                        <.input
                          field={upload_form[:kind]}
                          id={"#{kind}-document-kind"}
                          type="hidden"
                        />
                        <label class={[
                          "group flex min-h-32 cursor-pointer flex-col items-center justify-center rounded-xl border border-dashed border-slate-300 bg-white px-4 py-5 text-center transition hover:border-rose-300 hover:bg-rose-50/40"
                        ]}>
                          <.live_file_input upload={upload} class="sr-only" />
                          <span class={[
                            "rounded-xl bg-rose-50 p-2.5 text-rose-700 transition group-hover:-translate-y-0.5"
                          ]}>
                            <.icon name="hero-arrow-up-tray" class="size-5" />
                          </span>
                          <span class={["mt-3 text-sm font-semibold text-slate-800"]}>PDF auswählen</span>
                          <span class={["mt-1 text-xs text-slate-500"]}>
                            Upload und Auswertung starten automatisch
                          </span>
                        </label>

                        <div
                          :for={entry <- upload.entries}
                          id={"#{kind}-upload-#{entry.ref}"}
                          class={["mt-3 rounded-xl bg-white px-3 py-2.5 text-xs shadow-sm"]}
                        >
                          <p class={["truncate font-semibold text-slate-700"]}>{entry.client_name}</p>
                          <div
                            class={["mt-2 h-1.5 overflow-hidden rounded-full bg-slate-100"]}
                            role="progressbar"
                            aria-label={"Upload-Fortschritt für #{entry.client_name}"}
                            aria-valuemin="0"
                            aria-valuemax="100"
                            aria-valuenow={entry.progress}
                          >
                            <div
                              class={["h-full rounded-full bg-rose-600 transition-all"]}
                              style={"width: #{entry.progress}%"}
                            >
                            </div>
                          </div>
                          <p class={["mt-1 text-slate-500"]}>
                            {entry.progress}% · wird sicher gespeichert und ausgewertet
                          </p>
                          <p
                            :for={error <- upload_errors(upload, entry)}
                            class={["mt-1 text-rose-700"]}
                          >
                            {upload_error_message(error)}
                          </p>
                        </div>
                        <p
                          :for={error <- upload_errors(upload)}
                          class={["mt-2 text-xs text-rose-700"]}
                        >
                          {upload_error_message(error)}
                        </p>
                      </.form>
                    <% end %>
                  </article>
                <% end %>
              </div>
            </section>

            <section
              id="ticket-suggestions-section"
              class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
            >
              <div class={["flex items-start gap-3"]}>
                <span class={["rounded-xl bg-sky-50 p-2.5 text-sky-700"]}><.icon
                  name="hero-sparkles"
                  class="size-5"
                /></span>
                <div>
                  <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-sky-700"]}>
                    Schritt 3
                  </p>
                  <h2 class={["mt-2 text-xl font-semibold text-slate-950"]}>
                    Erkannte Angaben prüfen
                  </h2>
                  <p class={["mt-1 text-sm leading-6 text-slate-500"]}>
                    Ticket und Rechnung werden direkt nach der Auswahl ausgewertet. Die erkannten Werte bleiben nachvollziehbar und werden erst nach deiner Prüfung übernommen.
                  </p>
                </div>
              </div>

              <div id="ticket-suggestions" phx-update="stream" class={["mt-6 grid gap-3"]}>
                <div
                  id="suggestions-empty"
                  class={[
                    "hidden rounded-2xl border border-dashed border-slate-300 bg-slate-50 px-5 py-8 text-center only:block"
                  ]}
                >
                  <.icon name="hero-document-magnifying-glass" class="mx-auto size-7 text-slate-400" />
                  <p class={["mt-3 text-sm font-semibold text-slate-800"]}>Noch keine Vorschläge</p>
                  <p class={["mt-1 text-xs leading-5 text-slate-500"]}>
                    Nach dem Upload wird lesbarer PDF-Text automatisch ausgewertet. Textlose Dokumente bleiben manuell bearbeitbar.
                  </p>
                </div>

                <article
                  :for={{dom_id, suggestion} <- @streams.suggestions}
                  id={dom_id}
                  class={[
                    "rounded-2xl border p-4 transition",
                    suggestion_card_style(suggestion.state)
                  ]}
                >
                  <div class={["flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between"]}>
                    <div class={["min-w-0"]}>
                      <div class={["flex flex-wrap items-center gap-2"]}>
                        <span class={["text-xs font-bold uppercase tracking-[0.14em] text-slate-500"]}>{suggestion_field_label(
                          suggestion.field
                        )}</span>
                        <span class={[
                          "rounded-full bg-white px-2 py-0.5 text-[0.68rem] font-semibold text-slate-500 shadow-sm"
                        ]}>{confidence_label(suggestion.confidence)}</span>
                      </div>
                      <p class={["mt-2 text-sm font-semibold text-slate-950"]}>
                        {suggestion_value(suggestion)}
                      </p>
                      <p class={["mt-2 text-xs leading-5 text-slate-500"]}>
                        {source_document_name(@documents_by_id, suggestion.document_id)} · Seite {suggestion.source_page}: „{suggestion.source_excerpt}“
                      </p>
                    </div>
                    <div class={["flex shrink-0 flex-wrap gap-2"]}>
                      <%= if suggestion.state == :proposed do %>
                        <button
                          id={"accept-suggestion-#{suggestion.id}"}
                          type="button"
                          phx-click="set_suggestion_state"
                          phx-value-id={suggestion.id}
                          phx-value-state="accepted"
                          disabled={!editable?(@claim.status)}
                          class={[
                            "inline-flex min-h-9 items-center gap-1.5 rounded-lg bg-emerald-700 px-3 py-2 text-xs font-semibold text-white transition hover:bg-emerald-800 disabled:cursor-not-allowed disabled:opacity-40"
                          ]}
                        >
                          <.icon name="hero-check" class="size-4" /> {accept_label(suggestion.field)}
                        </button>
                        <button
                          id={"reject-suggestion-#{suggestion.id}"}
                          type="button"
                          phx-click="set_suggestion_state"
                          phx-value-id={suggestion.id}
                          phx-value-state="rejected"
                          disabled={!editable?(@claim.status)}
                          class={[
                            "inline-flex min-h-9 items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 transition hover:border-slate-300 hover:text-slate-950 disabled:cursor-not-allowed disabled:opacity-40"
                          ]}
                        >
                          <.icon name="hero-x-mark" class="size-4" /> Verwerfen
                        </button>
                      <% else %>
                        <span class={[
                          "inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-semibold",
                          suggestion_state_style(suggestion.state)
                        ]}>
                          <.icon
                            name={
                              if(suggestion.state == :accepted, do: "hero-check", else: "hero-x-mark")
                            }
                            class="size-4"
                          />
                          {if(suggestion.state == :accepted, do: "Bestätigt", else: "Verworfen")}
                        </span>
                      <% end %>
                    </div>
                  </div>
                </article>
              </div>
            </section>

            <section
              id="planned-journey-section"
              data-state={@planned_state}
              class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
            >
              <div class={["flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"]}>
                <div>
                  <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-rose-700"]}>
                    Schritt 4
                  </p>
                  <h2 class={["mt-2 text-xl font-semibold text-slate-950"]}>
                    Verbindung und Verspätung auswählen
                  </h2>
                  <p class={["mt-1 max-w-2xl text-sm leading-6 text-slate-500"]}>
                    Die DB-Abfrage zeigt planmäßige Zeit, aktuelle Prognose, Verspätungsminuten und Ausfälle direkt am Treffer. Die Auswahl bleibt bis zu deiner Bestätigung ein Vorschlag.
                  </p>
                </div>
                <.step_badge state={@planned_state} />
              </div>

              <.form
                for={@connection_search_form}
                id="connection-search-form"
                phx-submit="search_connections"
                class={["mt-6 rounded-2xl bg-slate-50 p-4 sm:p-5"]}
              >
                <div class={["grid gap-4 sm:grid-cols-2"]}>
                  <.input
                    field={@connection_search_form[:origin]}
                    id="connection-origin"
                    label="Startbahnhof"
                  />
                  <.input
                    field={@connection_search_form[:destination]}
                    id="connection-destination"
                    label="Zielbahnhof"
                  />
                  <.input
                    field={@connection_search_form[:departure_at]}
                    id="connection-departure-at"
                    type="datetime-local"
                    label="Geplante Abfahrt"
                  />
                  <.input
                    field={@connection_search_form[:train_number]}
                    id="connection-train-number"
                    label="Zugnummer (optional)"
                    placeholder="z. B. 100"
                  />
                </div>
                <button
                  id="search-connections-button"
                  type="submit"
                  phx-disable-with="Verbindungen werden geladen …"
                  class={[
                    "mt-4 inline-flex min-h-11 w-full items-center justify-center gap-2 rounded-xl bg-slate-950 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-slate-800 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-slate-950 sm:w-auto"
                  ]}
                >
                  <.icon name="hero-magnifying-glass" class="size-5" />
                  Verbindungen und Verspätungen abrufen
                </button>
              </.form>

              <div
                :if={@connection_search_state == :empty}
                id="connection-search-empty"
                class={["mt-5 rounded-2xl bg-amber-50 p-4 text-sm text-amber-900"]}
              >
                Keine eindeutige Verbindung gefunden. Nutze direkt die manuelle Eingabe darunter.
              </div>
              <div
                :if={match?({:error, _reason}, @connection_search_state)}
                id="connection-search-error"
                class={["mt-5 rounded-2xl bg-amber-50 p-4 text-sm leading-6 text-amber-900"]}
              >
                Die Bahndaten sind gerade nicht verfügbar. Deine Angaben bleiben erhalten; bestätige die Verbindung manuell.
              </div>

              <div id="connection-results" phx-update="stream" class={["mt-5 grid gap-3"]}>
                <article
                  :for={{dom_id, item} <- @streams.connection_candidates}
                  id={dom_id}
                  class={[
                    "rounded-2xl border border-slate-200 bg-white p-4 shadow-sm transition hover:border-slate-300 hover:shadow-md"
                  ]}
                >
                  <% segment = candidate_primary_segment(item.candidate) %>
                  <div class={["flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between"]}>
                    <div class={["min-w-0"]}>
                      <div class={["flex flex-wrap items-center gap-2"]}>
                        <strong class={["text-base text-slate-950"]}>{train_label(segment)}</strong>
                        <span
                          class={[
                            "rounded-full px-2.5 py-1 text-xs font-bold",
                            candidate_status_style(segment)
                          ]}
                          id={"connection-delay-#{item.id}"}
                          data-delay-minutes={delay_minutes(segment)}
                          data-cancelled={to_string(Map.get(segment, :cancelled, false))}
                        >
                          {candidate_status_label(segment)}
                        </span>
                      </div>
                      <p class={["mt-2 text-sm font-semibold text-slate-700"]}>
                        {format_time(segment.scheduled_departure)} Uhr · {@claim.origin} → {@claim.destination}
                      </p>
                      <p class={["mt-1 text-xs text-slate-500"]}>
                        Aktueller Stand: {candidate_current_time(segment)} · abgerufen {format_datetime(
                          item.candidate.fetched_at
                        )}
                      </p>
                    </div>
                    <button
                      id={"choose-connection-#{item.id}"}
                      type="button"
                      phx-click="choose_connection"
                      phx-value-index={item.id}
                      disabled={!editable?(@claim.status)}
                      class={[
                        "inline-flex min-h-11 shrink-0 items-center justify-center gap-2 rounded-xl bg-rose-700 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-rose-800 disabled:cursor-not-allowed disabled:opacity-40"
                      ]}
                    >
                      Verbindung übernehmen
                    </button>
                  </div>
                </article>
              </div>

              <details
                class={["mt-6 rounded-2xl border border-slate-200 bg-white"]}
                open={!@planned_complete?}
              >
                <summary class={[
                  "cursor-pointer px-4 py-4 text-sm font-semibold text-slate-800 sm:px-5"
                ]}>
                  Verbindung manuell eingeben oder korrigieren
                </summary>
                <.form
                  for={@planned_form}
                  id="planned-journey-form"
                  phx-submit="save_planned_journey"
                  class={["border-t border-slate-200 p-4 sm:p-5"]}
                >
                  <div class={["grid gap-5 sm:grid-cols-2"]}>
                    <.input field={@planned_form[:origin_name]} label="Startbahnhof" />
                    <.input field={@planned_form[:destination_name]} label="Zielbahnhof" />
                    <.input field={@planned_form[:train_category]} label="Zuggattung" />
                    <.input field={@planned_form[:train_number]} label="Zugnummer" />
                    <.input
                      field={@planned_form[:scheduled_departure]}
                      type="datetime-local"
                      label="Planmäßige Abfahrt"
                    />
                    <.input
                      field={@planned_form[:scheduled_arrival]}
                      type="datetime-local"
                      label="Planmäßige Ankunft"
                    />
                  </div>
                  <button
                    id="save-planned-journey"
                    type="submit"
                    disabled={!editable?(@claim.status)}
                    class={[
                      "mt-5 inline-flex min-h-11 items-center gap-2 rounded-xl bg-slate-950 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-slate-800 disabled:cursor-not-allowed disabled:opacity-40"
                    ]}
                  >
                    <.icon name="hero-check" class="size-5" /> Geplante Verbindung bestätigen
                  </button>
                </.form>
              </details>
            </section>

            <section
              id="actual-journey-section"
              data-state={@actual_state}
              class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
            >
              <div class={["flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"]}>
                <div>
                  <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-rose-700"]}>
                    Schritt 5
                  </p>
                  <h2 class={["mt-2 text-xl font-semibold text-slate-950"]}>
                    Tatsächliche Reise bestätigen
                  </h2>
                  <p class={["mt-1 text-sm leading-6 text-slate-500"]}>
                    Wähle die Störung ausdrücklich und prüfe besonders die tatsächliche Ankunft am Ziel.
                  </p>
                </div>
                <.step_badge state={@actual_state} />
              </div>

              <div id="disruption-choice" class={["mt-6 grid grid-cols-2 gap-3"]}>
                <button
                  id="choose-delay"
                  type="button"
                  phx-click="set_disruption"
                  phx-value-type="delay"
                  disabled={!editable?(@claim.status)}
                  class={[
                    "rounded-2xl border p-4 text-left transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700",
                    disruption_choice_style(@claim.disruption_cause == :delay)
                  ]}
                >
                  <.icon name="hero-clock" class="size-6" />
                  <strong class={["mt-3 block text-sm"]}>Verspätung</strong>
                  <span class={["mt-1 block text-xs opacity-75"]}>Zug fuhr, kam aber später an</span>
                </button>
                <button
                  id="choose-cancellation"
                  type="button"
                  phx-click="set_disruption"
                  phx-value-type="cancellation"
                  disabled={!editable?(@claim.status)}
                  class={[
                    "rounded-2xl border p-4 text-left transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700",
                    disruption_choice_style(@claim.disruption_cause == :cancellation)
                  ]}
                >
                  <.icon name="hero-no-symbol" class="size-6" />
                  <strong class={["mt-3 block text-sm"]}>Zugausfall</strong>
                  <span class={["mt-1 block text-xs opacity-75"]}>Mit Ersatzverbindung erfassen</span>
                </button>
              </div>

              <div
                :if={@actual_journey}
                id="api-delay-summary"
                class={["mt-5 rounded-2xl border border-sky-200 bg-sky-50 p-4"]}
              >
                <p class={["text-xs font-bold uppercase tracking-wide text-sky-800"]}>
                  Übernommener Datenstand
                </p>
                <p class={["mt-2 text-sm font-semibold text-slate-950"]}>
                  {journey_delay_summary(@actual_journey)}
                </p>
                <p class={["mt-1 text-xs text-slate-600"]}>
                  API-Werte sind Vorschläge und können unten korrigiert werden.
                </p>
              </div>

              <.form
                for={@actual_form}
                id="actual-journey-form"
                phx-submit="save_actual_journey"
                class={["mt-6 space-y-5"]}
              >
                <div class={["grid gap-5 sm:grid-cols-2"]}>
                  <.input field={@actual_form[:origin_name]} label="Startbahnhof" />
                  <.input field={@actual_form[:destination_name]} label="Zielbahnhof" />
                  <.input field={@actual_form[:train_category]} label="Zuggattung" />
                  <.input field={@actual_form[:train_number]} label="Zugnummer" />
                  <.input
                    field={@actual_form[:scheduled_departure]}
                    type="datetime-local"
                    label="Planmäßige Abfahrt"
                  />
                  <.input
                    field={@actual_form[:scheduled_arrival]}
                    type="datetime-local"
                    label="Planmäßige Ankunft"
                  />
                  <.input
                    field={@actual_form[:actual_departure]}
                    type="datetime-local"
                    label="Tatsächliche/Prognose-Abfahrt"
                  />
                  <.input
                    field={@actual_form[:actual_arrival]}
                    type="datetime-local"
                    label="Tatsächliche Ankunft am Ziel"
                  />
                </div>

                <div
                  :if={@claim.disruption_cause == :cancellation}
                  id="replacement-connection-fields"
                  class={["rounded-2xl border border-amber-200 bg-amber-50 p-4 sm:p-5"]}
                >
                  <h3 class={["text-sm font-semibold text-amber-950"]}>Ersatzverbindung</h3>
                  <div class={["mt-4 grid gap-5 sm:grid-cols-2"]}>
                    <.input field={@actual_form[:replacement_category]} label="Zuggattung Ersatz" />
                    <.input field={@actual_form[:replacement_number]} label="Zugnummer Ersatz" />
                    <.input
                      field={@actual_form[:replacement_departure]}
                      type="datetime-local"
                      label="Abfahrt Ersatz"
                    />
                    <.input
                      field={@actual_form[:replacement_arrival]}
                      type="datetime-local"
                      label="Ankunft Ersatz"
                    />
                  </div>
                </div>
                <button
                  id="save-actual-journey"
                  type="submit"
                  disabled={!editable?(@claim.status)}
                  class={[
                    "inline-flex min-h-11 items-center gap-2 rounded-xl bg-slate-950 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-slate-800 disabled:cursor-not-allowed disabled:opacity-40"
                  ]}
                >
                  <.icon name="hero-check" class="size-5" /> Tatsächliche Reise bestätigen
                </button>
              </.form>
            </section>

            <section
              id="claim-review-export-section"
              data-state={@export_state_label}
              class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
            >
              <div class={["flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"]}>
                <div>
                  <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-rose-700"]}>
                    Schritt 6
                  </p>
                  <h2 class={["mt-2 text-xl font-semibold text-slate-950"]}>
                    Prüfen und Gesamt-PDF erstellen
                  </h2>
                  <p class={["mt-1 text-sm leading-6 text-slate-500"]}>
                    Die Ausgabe enthält Deckblatt, offizielles Formular, Ticket und Rechnung. Das Unterschriftsfeld bleibt frei.
                  </p>
                </div>
                <.step_badge state={@export_state_label} />
              </div>

              <div id="review-checklist" class={["mt-6 grid gap-3 sm:grid-cols-2"]}>
                <.review_check label="Reisendenprofil" done?={@profile_complete?} />
                <.review_check label="Falldaten" done?={@claim_complete?} />
                <.review_check label="Ticket & Rechnung" done?={@documents_complete?} />
                <.review_check label="Geplante Verbindung" done?={@planned_complete?} />
                <.review_check label="Tatsächliche Reise" done?={@actual_complete?} />
              </div>

              <div id="claim-api-sources" phx-update="stream" class={["mt-6 grid gap-2"]}>
                <p
                  id="api-sources-heading"
                  class={["text-xs font-semibold uppercase tracking-wide text-slate-500"]}
                >
                  Quellen und Abrufzeiten
                </p>
                <div
                  id="api-sources-empty"
                  class={["hidden rounded-xl bg-slate-50 p-3 text-xs text-slate-500 only:block"]}
                >
                  Keine API-Quelle gespeichert; manuelle Angaben sind zulässig.
                </div>
                <div
                  :for={{dom_id, source} <- @streams.api_sources}
                  id={dom_id}
                  class={["rounded-xl border border-slate-200 px-3 py-2 text-xs text-slate-600"]}
                >
                  {source_label(source.operation)} · {source.provider} · {format_datetime(
                    source.fetched_at
                  )}
                </div>
              </div>

              <div
                :if={!@review_complete?}
                id="export-blocked"
                class={["mt-6 rounded-2xl bg-amber-50 p-4 text-sm text-amber-900"]}
              >
                Vor der PDF-Erzeugung sind noch Angaben offen. Ergänze die oben markierten Schritte.
              </div>
              <button
                id="generate-export-button"
                type="button"
                phx-click="generate_export"
                phx-disable-with="PDF wird erstellt …"
                disabled={!@review_complete? || @claim.status != :draft}
                class={[
                  "mt-6 inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-xl bg-rose-700 px-5 py-3 text-sm font-semibold text-white shadow-sm transition hover:bg-rose-800 disabled:cursor-not-allowed disabled:opacity-40 sm:w-auto"
                ]}
              >
                <.icon name="hero-document-arrow-down" class="size-5" /> Druckfertiges PDF erstellen
              </button>

              <div id="claim-exports" phx-update="stream" class={["mt-6 grid gap-3"]}>
                <article
                  :for={{dom_id, export} <- @streams.exports}
                  id={dom_id}
                  class={[
                    "flex flex-col gap-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 sm:flex-row sm:items-center sm:justify-between"
                  ]}
                >
                  <div>
                    <p class={["text-sm font-semibold text-emerald-950"]}>
                      Ausgabe {export.version} · druckfertig
                    </p>
                    <p class={["mt-1 text-xs text-emerald-800"]}>
                      Erstellt {format_datetime(export.inserted_at)}
                    </p>
                  </div>
                  <a
                    id={"download-export-#{export.id}"}
                    href={~p"/dokumente/#{export.bundle_document_id}/download"}
                    class={[
                      "inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-emerald-700 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-emerald-800"
                    ]}
                  >
                    <.icon name="hero-arrow-down-tray" class="size-5" /> Gesamt-PDF laden
                  </a>
                </article>
              </div>
            </section>
          </div>

          <aside class={["space-y-5"]}>
            <section
              id="claim-next-steps"
              class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm"]}
            >
              <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-slate-500"]}>
                Ablauf
              </p>
              <h2 class={["mt-2 text-lg font-semibold text-slate-950"]}>Dein Fortschritt</h2>
              <ol class={["mt-5 space-y-3"]}>
                <li
                  :for={
                    {label, done?} <- [
                      {"Reisendenprofil", @profile_complete?},
                      {"Falldaten", @claim_complete?},
                      {"Ticket & Rechnung", @documents_complete?},
                      {"Geplante Verbindung", @planned_complete?},
                      {"Tatsächliche Reise", @actual_complete?},
                      {"Druckfertiges PDF", @exports_available?}
                    ]
                  }
                  class={["flex items-center gap-3 rounded-xl bg-slate-50 px-3.5 py-3"]}
                >
                  <span class={[
                    "flex size-7 items-center justify-center rounded-full",
                    if(done?,
                      do: "bg-emerald-600 text-white",
                      else: "border border-slate-300 bg-white text-slate-400"
                    )
                  ]}>
                    <.icon name={if(done?, do: "hero-check", else: "hero-minus")} class="size-4" />
                  </span>
                  <span class={["text-sm font-semibold text-slate-700"]}>{label}</span>
                </li>
              </ol>
              <.link
                id="claim-profile-link"
                navigate={~p"/profil?antrag=#{@claim.id}"}
                class={[
                  "mt-4 inline-flex min-h-10 w-full items-center justify-center gap-2 rounded-xl border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700 transition hover:border-slate-300 hover:bg-slate-50"
                ]}
              >
                <.icon name="hero-user-circle" class="size-5" /> Profil prüfen
              </.link>
            </section>

            <section
              id="claim-status-actions"
              class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm"]}
            >
              <h2 class={["text-lg font-semibold text-slate-950"]}>Status</h2>
              <p class={["mt-2 text-sm leading-6 text-slate-500"]}>
                {status_explanation(@claim.status)}
              </p>
              <div class={["mt-4 grid gap-2"]}>
                <button
                  :if={@claim.status == :ready}
                  id="mark-claim-sent"
                  type="button"
                  phx-click="transition_claim"
                  phx-value-status="sent"
                  class={[
                    "inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-violet-700 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-violet-800"
                  ]}
                >
                  <.icon name="hero-paper-airplane" class="size-4" /> Als versendet markieren
                </button>
                <button
                  :if={@claim.status == :sent}
                  id="complete-claim"
                  type="button"
                  phx-click="transition_claim"
                  phx-value-status="completed"
                  class={[
                    "inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-emerald-700 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-emerald-800"
                  ]}
                >
                  <.icon name="hero-check-badge" class="size-4" /> Als erledigt markieren
                </button>
                <button
                  :if={@claim.status in [:ready, :sent]}
                  id="reopen-claim"
                  type="button"
                  phx-click="transition_claim"
                  phx-value-status="draft"
                  class={[
                    "inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-semibold text-slate-700 transition hover:bg-slate-50"
                  ]}
                >
                  <.icon name="hero-pencil-square" class="size-4" /> Erneut bearbeiten
                </button>
              </div>
            </section>

            <section class={["rounded-3xl border border-rose-200 bg-rose-50/60 p-6"]}>
              <h2 class={["text-sm font-semibold text-rose-950"]}>Antrag löschen</h2>
              <p class={["mt-2 text-xs leading-5 text-rose-800"]}>
                Dabei werden auch alle privaten PDF-Dateien unwiderruflich entfernt.
              </p>
              <button
                id="delete-claim-button"
                type="button"
                phx-click="delete_claim"
                data-confirm="Antrag und alle zugehörigen Dokumente wirklich löschen?"
                class={[
                  "mt-4 inline-flex min-h-10 items-center gap-2 rounded-lg bg-rose-800 px-3.5 py-2 text-xs font-semibold text-white transition hover:bg-rose-900"
                ]}
              >
                <.icon name="hero-trash" class="size-4" /> Antrag vollständig löschen
              </button>
            </section>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :state, :atom, required: true

  def step_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex w-fit shrink-0 items-center gap-2 rounded-full px-3 py-1.5 text-xs font-semibold",
      step_badge_style(@state)
    ]}>
      <.icon name={step_badge_icon(@state)} class="size-4" /> {step_badge_label(@state)}
    </span>
    """
  end

  attr :label, :string, required: true
  attr :done?, :boolean, required: true

  def review_check(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-3 rounded-xl border px-3.5 py-3",
      if(@done?, do: "border-emerald-200 bg-emerald-50", else: "border-amber-200 bg-amber-50")
    ]}>
      <span class={[
        "flex size-7 shrink-0 items-center justify-center rounded-full",
        if(@done?, do: "bg-emerald-600 text-white", else: "bg-amber-100 text-amber-800")
      ]}>
        <.icon name={if(@done?, do: "hero-check", else: "hero-exclamation-triangle")} class="size-4" />
      </span>
      <span class={["text-sm font-semibold text-slate-800"]}>{@label}</span>
      <span class={[
        "ml-auto text-xs font-semibold",
        if(@done?, do: "text-emerald-700", else: "text-amber-800")
      ]}>
        {if(@done?, do: "Bestätigt", else: "Offen")}
      </span>
    </div>
    """
  end

  defp persist_claim(socket, params, show_flash?) do
    case Claims.update_claim(
           socket.assigns.current_scope,
           socket.assigns.claim.id,
           params,
           socket.assigns.claim.lock_version
         ) do
      {:ok, claim} ->
        socket =
          socket
          |> assign(:save_state, :saved)
          |> load_workspace(claim)

        if show_flash?,
          do: put_flash(socket, :info, "Die Falldaten wurden gespeichert."),
          else: socket

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> assign(:save_state, :invalid)
        |> assign(:claim_form, to_form(%{changeset | action: :validate}))

      {:error, :stale} ->
        handle_stale(socket)

      {:error, :not_editable} ->
        put_flash(socket, :error, "Dieser Antrag muss vor Änderungen erneut geöffnet werden.")

      {:error, _reason} ->
        put_flash(socket, :error, "Die Falldaten konnten nicht gespeichert werden.")
    end
  end

  defp handle_progress(upload_name, entry, socket)
       when upload_name in @upload_kinds and entry.done? do
    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok,
         Documents.put_document(
           socket.assigns.current_scope,
           socket.assigns.claim.id,
           upload_name,
           %{
             path: path,
             original_filename: entry.client_name,
             content_type: entry.client_type
           },
           socket.assigns.claim.lock_version
         )}
      end)

    {:noreply, handle_upload_result(socket, [result])}
  end

  defp handle_progress(upload_name, _entry, socket) when upload_name in @upload_kinds,
    do: {:noreply, socket}

  defp handle_upload_result(socket, [{:ok, %{document: document, claim: claim}}]) do
    analysis = Tickets.analyze_document(socket.assigns.current_scope, document.id)

    socket =
      socket
      |> load_workspace(claim)
      |> put_flash(:info, "Das Dokument wurde sicher gespeichert und automatisch ausgewertet.")

    case analysis do
      {:ok, _result} ->
        refresh_workspace(socket)

      {:error, _reason} ->
        put_flash(
          socket,
          :error,
          "Das Dokument ist gespeichert, konnte aber nicht ausgewertet werden."
        )
    end
  end

  defp handle_upload_result(socket, [{:error, reason}]) do
    put_flash(socket, :error, document_error_message(reason))
  end

  defp handle_upload_result(socket, _results) do
    put_flash(socket, :error, "Bitte wähle zuerst eine vollständige PDF-Datei aus.")
  end

  defp accept_suggestion(socket, suggestion_id) do
    with suggestion when not is_nil(suggestion) <- find_suggestion(socket, suggestion_id),
         {:ok, claim} <- maybe_apply_suggestion(socket, suggestion),
         {:ok, _suggestion} <-
           Tickets.set_suggestion_state(socket.assigns.current_scope, suggestion.id, :accepted) do
      socket
      |> load_workspace(claim)
      |> put_flash(:info, suggestion_accept_message(suggestion.field))
    else
      nil ->
        put_flash(socket, :error, "Der Vorschlag wurde nicht gefunden.")

      {:error, :stale} ->
        handle_stale(socket)

      {:error, _reason} ->
        put_flash(socket, :error, "Der Vorschlag konnte nicht übernommen werden.")
    end
  end

  defp update_suggestion_state(socket, suggestion_id, state) do
    case Tickets.set_suggestion_state(socket.assigns.current_scope, suggestion_id, state) do
      {:ok, _suggestion} ->
        socket
        |> refresh_workspace()
        |> put_flash(:info, "Der Vorschlag wurde verworfen.")

      {:error, _reason} ->
        put_flash(socket, :error, "Der Vorschlag konnte nicht aktualisiert werden.")
    end
  end

  defp maybe_apply_suggestion(socket, suggestion) do
    case claim_attrs_for_suggestion(suggestion) do
      attrs when attrs == %{} ->
        {:ok, socket.assigns.claim}

      attrs ->
        Claims.update_claim(
          socket.assigns.current_scope,
          socket.assigns.claim.id,
          attrs,
          socket.assigns.claim.lock_version
        )
    end
  end

  defp claim_attrs_for_suggestion(%{field: :travel_date, value: value}),
    do: present_attr("travel_date", Map.get(value, "date"))

  defp claim_attrs_for_suggestion(%{field: :origin, value: value}),
    do: present_attr("origin", Map.get(value, "text"))

  defp claim_attrs_for_suggestion(%{field: :destination, value: value}),
    do: present_attr("destination", Map.get(value, "text"))

  defp claim_attrs_for_suggestion(_suggestion), do: %{}

  defp present_attr(_key, value) when value in [nil, ""], do: %{}
  defp present_attr(key, value), do: %{key => value}

  defp find_suggestion(socket, suggestion_id) do
    Enum.find_value(socket.assigns.documents_by_id, fn {_document_id, document} ->
      case Tickets.list_suggestions(socket.assigns.current_scope, document.id) do
        {:ok, suggestions} -> Enum.find(suggestions, &(&1.id == suggestion_id))
        {:error, _reason} -> nil
      end
    end)
  end

  defp load_workspace(socket, claim) do
    scope = socket.assigns.current_scope
    {:ok, documents} = Documents.list_documents(scope, claim.id)
    {:ok, changeset} = Claims.change_claim(scope, claim.id)
    {:ok, exports} = Exports.list_exports(scope, claim.id)
    {:ok, api_sources} = Rail.list_api_snapshots(scope, claim.id)
    planned_journey = optional_journey(scope, claim.id, :planned)
    actual_journey = optional_journey(scope, claim.id, :actual)

    suggestions =
      documents
      |> Enum.filter(&(&1.kind in @upload_kinds))
      |> Enum.flat_map(fn document ->
        case Tickets.list_suggestions(scope, document.id) do
          {:ok, items} -> items
          {:error, _reason} -> []
        end
      end)

    documents_by_kind = Map.new(documents, &{&1.kind, &1})
    documents_by_id = Map.new(documents, &{&1.id, &1})
    claim_complete? = claim_complete?(claim)
    documents_complete? = Enum.all?(@upload_kinds, &Map.has_key?(documents_by_kind, &1))
    profile_complete? = Accounts.profile_complete?(scope)
    planned_complete? = journey_complete?(planned_journey, :planned)
    actual_complete? = actual_journey_complete?(claim, actual_journey)

    review_complete? =
      profile_complete? && claim_complete? && documents_complete? && planned_complete? &&
        actual_complete?

    exports_available? = exports != []

    completed_steps =
      Enum.count(
        [
          profile_complete?,
          claim_complete?,
          documents_complete?,
          planned_complete?,
          actual_complete?,
          exports_available?
        ],
        & &1
      )

    socket
    |> assign(:claim, claim)
    |> assign(:claim_form, to_form(changeset))
    |> assign(:documents_by_kind, documents_by_kind)
    |> assign(:documents_by_id, documents_by_id)
    |> assign(:upload_kinds, @upload_kinds)
    |> assign(:claim_complete?, claim_complete?)
    |> assign(:documents_complete?, documents_complete?)
    |> assign(:profile_complete?, profile_complete?)
    |> assign(:planned_journey, planned_journey)
    |> assign(:actual_journey, actual_journey)
    |> assign(:planned_complete?, planned_complete?)
    |> assign(:actual_complete?, actual_complete?)
    |> assign(:review_complete?, review_complete?)
    |> assign(:exports_available?, exports_available?)
    |> assign(:planned_state, step_state(planned_complete?, !is_nil(planned_journey)))
    |> assign(:actual_state, step_state(actual_complete?, !is_nil(actual_journey)))
    |> assign(:export_state_label, step_state(exports_available?, review_complete?))
    |> assign(:planned_form, to_form(planned_form_data(claim, planned_journey), as: :planned))
    |> assign(
      :actual_form,
      to_form(actual_form_data(claim, planned_journey, actual_journey), as: :actual)
    )
    |> assign(
      :connection_search_form,
      to_form(connection_search_data(claim, planned_journey), as: :connection_search)
    )
    |> assign(:completed_steps, completed_steps)
    |> stream(:suggestions, suggestions, reset: true)
    |> stream(:exports, Enum.reverse(exports), reset: true)
    |> stream(:api_sources, Enum.reverse(api_sources), reset: true)
  end

  defp optional_journey(scope, claim_id, kind) do
    case Rail.get_journey(scope, claim_id, kind) do
      {:ok, journey} -> journey
      {:error, _reason} -> nil
    end
  end

  defp find_connections(socket, params) do
    scope = socket.assigns.current_scope
    claim = socket.assigns.claim

    with {:ok, departure_at} <- parse_datetime(params["departure_at"]),
         {:ok, [origin | _]} <- Rail.search_stations(scope, claim.id, params["origin"] || ""),
         {:ok, [destination | _]} <-
           Rail.search_stations(scope, claim.id, params["destination"] || "") do
      query = %{origin: origin.id, destination: destination.id, departure_at: departure_at}

      case Rail.search_connections(scope, claim.id, query) do
        {:ok, candidates} ->
          {:ok, filter_candidates(candidates, params)}

        {:error, :unsupported} ->
          until = DateTime.add(departure_at, 6, :hour)

          case Rail.departures(scope, claim.id, origin.id, departure_at, until) do
            {:ok, candidates} -> {:ok, filter_candidates(candidates, params)}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, []} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp filter_candidates(candidates, params) do
    train_number = params["train_number"] |> to_string() |> String.trim()

    if train_number == "" do
      candidates
    else
      Enum.filter(candidates, fn candidate ->
        Enum.any?(candidate.segments, &(&1.train_number == train_number))
      end)
    end
  end

  defp candidate_segments(candidate, claim) do
    last_index = length(candidate.segments) - 1

    candidate.segments
    |> Enum.with_index()
    |> Enum.map(fn {segment, index} ->
      segment
      |> Map.new()
      |> Map.put(:origin_name, if(index == 0, do: claim.origin, else: segment.origin_name))
      |> Map.put(
        :destination_name,
        if(index == last_index, do: claim.destination, else: segment.destination_name)
      )
    end)
  end

  defp planned_segments(segments) do
    Enum.map(segments, fn segment ->
      segment
      |> Map.put(:actual_departure, nil)
      |> Map.put(:actual_arrival, nil)
      |> Map.put(:estimated_departure, nil)
      |> Map.put(:estimated_arrival, nil)
      |> Map.put(:cancelled, false)
    end)
  end

  defp build_planned_segment(params) do
    with {:ok, scheduled_departure} <- parse_datetime(params["scheduled_departure"]),
         {:ok, scheduled_arrival} <- parse_datetime(params["scheduled_arrival"]),
         :ok <- validate_order(scheduled_departure, scheduled_arrival) do
      {:ok,
       %{
         origin_name: params["origin_name"],
         destination_name: params["destination_name"],
         train_category: params["train_category"],
         train_number: params["train_number"],
         scheduled_departure: scheduled_departure,
         scheduled_arrival: scheduled_arrival,
         source: "manual",
         manual: true
       }}
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    normalized = if String.length(value) == 16, do: value <> ":00", else: value

    with {:ok, naive} <- NaiveDateTime.from_iso8601(normalized),
         {:ok, utc} <- BerlinTime.from_local(naive) do
      {:ok, utc}
    else
      _error -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_datetime}
  defp parse_optional_datetime(value) when value in [nil, ""], do: {:ok, nil}
  defp parse_optional_datetime(value), do: parse_datetime(value)

  defp validate_order(from, until) do
    if DateTime.compare(until, from) == :lt,
      do: {:error, :invalid_time_order},
      else: :ok
  end

  defp build_actual_segments(params, assigns) do
    case assigns.claim.disruption_cause do
      :delay -> build_delay_segment(params)
      :cancellation -> build_cancellation_segments(params, assigns.planned_journey)
      _other -> {:error, :missing_disruption}
    end
  end

  defp build_delay_segment(params) do
    with {:ok, scheduled_departure} <- parse_datetime(params["scheduled_departure"]),
         {:ok, scheduled_arrival} <- parse_datetime(params["scheduled_arrival"]),
         {:ok, actual_departure} <- parse_optional_datetime(params["actual_departure"]),
         {:ok, actual_arrival} <- parse_datetime(params["actual_arrival"]),
         :ok <- validate_order(scheduled_departure, scheduled_arrival) do
      {:ok,
       [
         %{
           origin_name: params["origin_name"],
           destination_name: params["destination_name"],
           train_category: params["train_category"],
           train_number: params["train_number"],
           scheduled_departure: scheduled_departure,
           scheduled_arrival: scheduled_arrival,
           actual_departure: actual_departure,
           actual_arrival: actual_arrival,
           cancelled: false,
           source: "manual",
           manual: true
         }
       ]}
    end
  end

  defp build_cancellation_segments(_params, nil), do: {:error, :missing_planned}

  defp build_cancellation_segments(params, planned_journey) do
    planned = List.first(planned_journey.segments)

    with {:ok, replacement_departure} <- parse_datetime(params["replacement_departure"]),
         {:ok, replacement_arrival} <- parse_datetime(params["replacement_arrival"]),
         :ok <- validate_order(replacement_departure, replacement_arrival) do
      cancelled =
        planned
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :journey, :journey_id, :inserted_at, :updated_at, :position])
        |> Map.put(:actual_departure, nil)
        |> Map.put(:actual_arrival, nil)
        |> Map.put(:estimated_departure, nil)
        |> Map.put(:estimated_arrival, nil)
        |> Map.put(:cancelled, true)
        |> Map.put(:source, "manual")
        |> Map.put(:manual, true)

      replacement = %{
        origin_name: params["origin_name"],
        destination_name: params["destination_name"],
        train_category: params["replacement_category"],
        train_number: params["replacement_number"],
        scheduled_departure: replacement_departure,
        scheduled_arrival: replacement_arrival,
        actual_departure: replacement_departure,
        actual_arrival: replacement_arrival,
        cancelled: false,
        source: "manual",
        manual: true
      }

      {:ok, [cancelled, replacement]}
    end
  end

  defp journey_complete?(nil, _kind), do: false

  defp journey_complete?(journey, :planned) do
    journey.segments != [] &&
      Enum.all?(journey.segments, &(&1.scheduled_departure && &1.scheduled_arrival))
  end

  defp actual_journey_complete?(%{journey_outcome: :not_started}, _journey), do: true
  defp actual_journey_complete?(_claim, nil), do: false

  defp actual_journey_complete?(_claim, journey) do
    journey.segments != [] &&
      Enum.any?(journey.segments, &(&1.actual_arrival || &1.estimated_arrival))
  end

  defp planned_form_data(claim, nil) do
    %{
      "origin_name" => claim.origin || "",
      "destination_name" => claim.destination || "",
      "train_category" => "",
      "train_number" => "",
      "scheduled_departure" => default_departure(claim),
      "scheduled_arrival" => ""
    }
  end

  defp planned_form_data(_claim, journey) do
    first = List.first(journey.segments)
    last = List.last(journey.segments)

    %{
      "origin_name" => first.origin_name || "",
      "destination_name" => last.destination_name || "",
      "train_category" => first.train_category || "",
      "train_number" => first.train_number || "",
      "scheduled_departure" => datetime_local(first.scheduled_departure),
      "scheduled_arrival" => datetime_local(last.scheduled_arrival)
    }
  end

  defp actual_form_data(claim, planned, nil) do
    planned_data = planned_form_data(claim, planned)

    Map.merge(planned_data, %{
      "actual_departure" => "",
      "actual_arrival" => "",
      "replacement_category" => "",
      "replacement_number" => "",
      "replacement_departure" => "",
      "replacement_arrival" => ""
    })
  end

  defp actual_form_data(claim, planned, journey) do
    first = List.first(journey.segments)
    last = List.last(journey.segments)

    claim
    |> actual_form_data(planned, nil)
    |> Map.put("origin_name", first.origin_name || claim.origin || "")
    |> Map.put("destination_name", last.destination_name || claim.destination || "")
    |> Map.put("train_category", first.train_category || "")
    |> Map.put("train_number", first.train_number || "")
    |> Map.put("scheduled_departure", datetime_local(first.scheduled_departure))
    |> Map.put("scheduled_arrival", datetime_local(first.scheduled_arrival))
    |> Map.put(
      "actual_departure",
      datetime_local(first.actual_departure || first.estimated_departure)
    )
    |> Map.put("actual_arrival", datetime_local(last.actual_arrival || last.estimated_arrival))
    |> maybe_put_replacement(journey)
  end

  defp maybe_put_replacement(data, %{segments: [_first, replacement | _rest]}) do
    data
    |> Map.put("replacement_category", replacement.train_category || "")
    |> Map.put("replacement_number", replacement.train_number || "")
    |> Map.put(
      "replacement_departure",
      datetime_local(replacement.actual_departure || replacement.scheduled_departure)
    )
    |> Map.put(
      "replacement_arrival",
      datetime_local(replacement.actual_arrival || replacement.scheduled_arrival)
    )
  end

  defp maybe_put_replacement(data, _journey), do: data

  defp connection_search_data(claim, planned) do
    planned_data = planned_form_data(claim, planned)

    %{
      "origin" => claim.origin || "",
      "destination" => claim.destination || "",
      "departure_at" => planned_data["scheduled_departure"],
      "train_number" => planned_data["train_number"]
    }
  end

  defp default_departure(%{travel_date: %Date{} = date}), do: "#{Date.to_iso8601(date)}T08:00"
  defp default_departure(_claim), do: ""

  defp datetime_local(nil), do: ""

  defp datetime_local(%DateTime{} = datetime) do
    datetime
    |> BerlinTime.to_local_naive()
    |> Calendar.strftime("%Y-%m-%dT%H:%M")
  end

  defp refresh_workspace(socket) do
    case Claims.get_claim(socket.assigns.current_scope, socket.assigns.claim.id) do
      {:ok, claim} -> load_workspace(socket, claim)
      {:error, _reason} -> socket
    end
  end

  defp handle_stale(socket) do
    socket
    |> refresh_workspace()
    |> assign(:save_state, :conflict)
    |> put_flash(
      :error,
      "Der Antrag wurde zwischenzeitlich geändert. Die aktuelle Version wurde neu geladen."
    )
  end

  defp upload_forms do
    Map.new(@upload_kinds, fn kind ->
      {kind, to_form(%{"kind" => Atom.to_string(kind)}, as: :document)}
    end)
  end

  defp transition_status("draft"), do: {:ok, :draft}
  defp transition_status("sent"), do: {:ok, :sent}
  defp transition_status("completed"), do: {:ok, :completed}
  defp transition_status(_status), do: {:error, :invalid_status}

  defp transition_message(:draft), do: "Der Antrag ist wieder zur Bearbeitung geöffnet."
  defp transition_message(:sent), do: "Der Antrag wurde als versendet markiert."
  defp transition_message(:completed), do: "Der Antrag wurde als erledigt markiert."

  defp claim_complete?(claim) do
    Enum.all?(
      [
        claim.travel_date,
        claim.origin,
        claim.destination,
        claim.journey_outcome,
        claim.disruption_cause,
        claim.journey_direction
      ],
      &(!is_nil(&1))
    )
  end

  defp editable?(status), do: status in [:draft, :ready]

  defp route_label(%{origin: origin, destination: destination})
       when is_binary(origin) and is_binary(destination),
       do: "#{origin} → #{destination}"

  defp route_label(_claim), do: "Strecke noch offen"

  defp status_label(:draft), do: "Entwurf"
  defp status_label(:ready), do: "Druckfertig"
  defp status_label(:sent), do: "Versendet"
  defp status_label(:completed), do: "Erledigt"

  defp status_style(:draft), do: "bg-amber-400/15 text-amber-200"
  defp status_style(:ready), do: "bg-sky-400/15 text-sky-200"
  defp status_style(:sent), do: "bg-violet-400/15 text-violet-200"
  defp status_style(:completed), do: "bg-emerald-400/15 text-emerald-200"

  defp status_explanation(:draft),
    do: "Der Fall kann bearbeitet und mit Dokumenten ergänzt werden."

  defp status_explanation(:ready),
    do: "Die Ausgabe ist druckfertig und kann nach dem Versand fortgeschrieben werden."

  defp status_explanation(:sent),
    do: "Der Antrag ist versendet. Öffne ihn erneut, bevor du Daten änderst."

  defp status_explanation(:completed),
    do: "Dieser Fall ist abgeschlossen und bleibt in deiner Übersicht erhalten."

  defp save_state_label(:saved), do: "Gespeichert"
  defp save_state_label(:invalid), do: "Eingabe prüfen"
  defp save_state_label(:conflict), do: "Neu geladen"

  defp save_state_style(:saved), do: "bg-emerald-50 text-emerald-700"
  defp save_state_style(:invalid), do: "bg-rose-50 text-rose-700"
  defp save_state_style(:conflict), do: "bg-amber-50 text-amber-700"

  defp step_state(true, _started?), do: :confirmed
  defp step_state(false, true), do: :incomplete
  defp step_state(false, false), do: :open

  defp step_badge_label(:confirmed), do: "Bestätigt"
  defp step_badge_label(:incomplete), do: "Unvollständig"
  defp step_badge_label(:open), do: "Offen"
  defp step_badge_style(:confirmed), do: "bg-emerald-50 text-emerald-700"
  defp step_badge_style(:incomplete), do: "bg-amber-50 text-amber-800"
  defp step_badge_style(:open), do: "bg-slate-100 text-slate-600"
  defp step_badge_icon(:confirmed), do: "hero-check-circle"
  defp step_badge_icon(:incomplete), do: "hero-exclamation-circle"
  defp step_badge_icon(:open), do: "hero-minus-circle"

  defp candidate_primary_segment(candidate), do: List.first(candidate.segments) || %{}

  defp candidate_status_label(%{cancelled: true}), do: "Zug fällt aus"

  defp candidate_status_label(segment) do
    case delay_minutes(segment) do
      nil -> "Keine Prognose"
      minutes when minutes <= 0 -> "Pünktlich"
      minutes -> "+#{minutes} Min."
    end
  end

  defp candidate_status_style(%{cancelled: true}), do: "bg-rose-100 text-rose-800"

  defp candidate_status_style(segment) do
    case delay_minutes(segment) do
      nil -> "bg-slate-100 text-slate-700"
      minutes when minutes <= 0 -> "bg-emerald-100 text-emerald-800"
      minutes when minutes < 60 -> "bg-amber-100 text-amber-800"
      _minutes -> "bg-rose-100 text-rose-800"
    end
  end

  defp delay_minutes(segment) do
    scheduled = Map.get(segment, :scheduled_arrival) || Map.get(segment, :scheduled_departure)

    current =
      Map.get(segment, :actual_arrival) || Map.get(segment, :estimated_arrival) ||
        Map.get(segment, :actual_departure) || Map.get(segment, :estimated_departure)

    if scheduled && current, do: div(DateTime.diff(current, scheduled, :second), 60), else: nil
  end

  defp candidate_current_time(segment) do
    current =
      Map.get(segment, :actual_arrival) || Map.get(segment, :estimated_arrival) ||
        Map.get(segment, :actual_departure) || Map.get(segment, :estimated_departure)

    if current, do: "#{format_time(current)} Uhr", else: "noch keine Prognose"
  end

  defp train_label(segment) do
    [Map.get(segment, :train_category), Map.get(segment, :train_number)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> "Verbindung"
      label -> label
    end
  end

  defp disruption_choice_style(true),
    do: "border-rose-700 bg-rose-50 text-rose-900 shadow-sm"

  defp disruption_choice_style(false),
    do: "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"

  defp journey_delay_summary(journey) do
    segment = List.last(journey.segments)

    case delay_minutes(segment) do
      nil -> "#{train_label(segment)} · tatsächliche Ankunft noch ergänzen"
      minutes when minutes <= 0 -> "#{train_label(segment)} · derzeit pünktlich"
      minutes -> "#{train_label(segment)} · derzeit #{minutes} Minuten verspätet"
    end
  end

  defp source_label("search_stations"), do: "Bahnhofssuche"
  defp source_label("search_connections"), do: "Verbindungssuche"
  defp source_label("departures"), do: "Abfahrten und Abweichungen"
  defp source_label(operation), do: operation

  defp format_datetime(nil), do: "–"

  defp format_datetime(%DateTime{} = datetime) do
    datetime
    |> BerlinTime.to_local()
    |> Calendar.strftime("%d.%m.%Y, %H:%M Uhr")
  end

  defp format_time(nil), do: "–"

  defp format_time(%DateTime{} = datetime) do
    datetime
    |> BerlinTime.to_local()
    |> Calendar.strftime("%H:%M")
  end

  defp document_kind_label(:ticket), do: "DB-Ticket"
  defp document_kind_label(:invoice), do: "DB-Rechnung"

  defp analysis_label(:not_started), do: "Noch nicht ausgewertet"
  defp analysis_label(:completed), do: "Auswertung abgeschlossen"
  defp analysis_label(:manual_required), do: "Manuelle Eingabe nötig"
  defp analysis_label(:failed), do: "Auswertung fehlgeschlagen"

  defp analysis_style(:not_started), do: "bg-slate-100 text-slate-700"
  defp analysis_style(:completed), do: "bg-emerald-50 text-emerald-700"
  defp analysis_style(:manual_required), do: "bg-amber-50 text-amber-800"
  defp analysis_style(:failed), do: "bg-rose-50 text-rose-700"

  defp suggestion_card_style(:proposed), do: "border-sky-200 bg-sky-50/50"
  defp suggestion_card_style(:accepted), do: "border-emerald-200 bg-emerald-50/50"
  defp suggestion_card_style(:rejected), do: "border-slate-200 bg-slate-50 opacity-70"

  defp suggestion_state_style(:accepted), do: "bg-emerald-100 text-emerald-800"
  defp suggestion_state_style(:rejected), do: "bg-slate-200 text-slate-700"

  defp suggestion_field_label(:order_number), do: "Auftragsnummer"
  defp suggestion_field_label(:travel_date), do: "Reisedatum"
  defp suggestion_field_label(:valid_until), do: "Gültig bis"
  defp suggestion_field_label(:origin), do: "Start"
  defp suggestion_field_label(:destination), do: "Ziel"
  defp suggestion_field_label(:product), do: "Produkt"
  defp suggestion_field_label(:fare), do: "Fahrpreis"
  defp suggestion_field_label(:scheduled_train), do: "Geplanter Zug"
  defp suggestion_field_label(:scheduled_departure), do: "Planmäßige Abfahrt"
  defp suggestion_field_label(:scheduled_arrival), do: "Planmäßige Ankunft"

  defp suggestion_value(%{field: field, value: value})
       when field in [:order_number, :origin, :destination, :product],
       do: Map.get(value, "text", "–")

  defp suggestion_value(%{field: field, value: value}) when field in [:travel_date, :valid_until],
    do: format_iso_date(Map.get(value, "date"))

  defp suggestion_value(%{field: :fare, value: value}),
    do: "#{Map.get(value, "amount", "–")} #{Map.get(value, "currency", "")}" |> String.trim()

  defp suggestion_value(%{field: :scheduled_train, value: value}),
    do: "#{Map.get(value, "category", "")} #{Map.get(value, "number", "")}" |> String.trim()

  defp suggestion_value(%{field: field, value: value})
       when field in [:scheduled_departure, :scheduled_arrival],
       do: "#{Map.get(value, "station", "–")} · #{Map.get(value, "time", "–")} Uhr"

  defp accept_label(field) when field in [:travel_date, :origin, :destination], do: "Übernehmen"
  defp accept_label(_field), do: "Bestätigen"

  defp suggestion_accept_message(field) when field in [:travel_date, :origin, :destination],
    do: "Der Vorschlag wurde bestätigt und in die Falldaten übernommen."

  defp suggestion_accept_message(_field), do: "Der Vorschlag wurde bestätigt."

  defp confidence_label(confidence), do: "#{round(confidence * 100)} % sicher"

  defp source_document_name(documents_by_id, document_id) do
    case Map.get(documents_by_id, document_id) do
      nil -> "Dokument"
      document -> document.original_filename
    end
  end

  defp format_iso_date(nil), do: "–"

  defp format_iso_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Calendar.strftime(date, "%d.%m.%Y")
      {:error, _reason} -> value
    end
  end

  defp format_bytes(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp journey_error_message(:invalid_datetime), do: "Bitte trage alle benötigten Zeiten ein."

  defp journey_error_message(:invalid_time_order),
    do: "Die Ankunft darf nicht vor der Abfahrt liegen."

  defp journey_error_message(:missing_disruption),
    do: "Bitte wähle Verspätung oder Zugausfall."

  defp journey_error_message(:missing_planned),
    do: "Bestätige zuerst die geplante Verbindung."

  defp journey_error_message(_reason),
    do: "Die Verbindung konnte nicht bestätigt werden. Bitte prüfe die Angaben."

  defp export_error_message(%{type: :incomplete}),
    do: "Der Antrag ist noch unvollständig. Prüfe die markierten Schritte."

  defp export_error_message(:template_unavailable),
    do: "Das offizielle Formular ist derzeit nicht verfügbar."

  defp export_error_message(:timeout), do: "Die PDF-Erzeugung hat zu lange gedauert."
  defp export_error_message(_reason), do: "Das Gesamt-PDF konnte nicht erstellt werden."

  defp upload_error_message(:too_large), do: "Die PDF-Datei ist zu groß."
  defp upload_error_message(:not_accepted), do: "Bitte verwende ausschließlich PDF-Dateien."
  defp upload_error_message(:too_many_files), do: "Bitte wähle nur eine Datei aus."
  defp upload_error_message(_error), do: "Die Datei konnte nicht hochgeladen werden."

  defp document_error_message(:wrong_content_type), do: "Die Datei wurde nicht als PDF erkannt."
  defp document_error_message(:invalid_pdf), do: "Die PDF-Datei ist beschädigt oder ungültig."

  defp document_error_message(:file_too_large),
    do: "Die PDF-Datei überschreitet die Größenbegrenzung."

  defp document_error_message(:too_many_pages), do: "Die PDF-Datei enthält zu viele Seiten."
  defp document_error_message(:timeout), do: "Die PDF-Prüfung hat zu lange gedauert."

  defp document_error_message(:stale),
    do: "Der Antrag wurde geändert. Bitte versuche den Upload erneut."

  defp document_error_message(_reason), do: "Das Dokument konnte nicht sicher gespeichert werden."

  defp documents_config(key) do
    :fahrgastrechte
    |> Application.fetch_env!(Documents)
    |> Keyword.fetch!(key)
  end
end
