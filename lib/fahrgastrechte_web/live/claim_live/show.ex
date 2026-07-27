defmodule FahrgastrechteWeb.ClaimLive.Show do
  use FahrgastrechteWeb, :live_view

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents
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
          |> assign(:upload_forms, upload_forms())
          |> assign(:max_file_size_label, format_bytes(max_file_size))
          |> allow_upload(:ticket,
            accept: ~w(.pdf),
            max_entries: 1,
            max_file_size: max_file_size
          )
          |> allow_upload(:invoice,
            accept: ~w(.pdf),
            max_entries: 1,
            max_file_size: max_file_size
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

  def handle_event("upload_document", %{"document" => %{"kind" => kind}}, socket) do
    with {:ok, upload_name} <- upload_name(kind) do
      results =
        consume_uploaded_entries(socket, upload_name, fn %{path: path}, entry ->
          result =
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
            )

          {:ok, result}
        end)

      {:noreply, handle_upload_result(socket, results)}
    else
      {:error, :invalid_kind} ->
        {:noreply, put_flash(socket, :error, "Diese Dokumentart ist nicht zulässig.")}
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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
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
                <span class={["text-slate-300"]}>Verfügbare MVP-Bausteine</span>
                <span>{@completed_steps} von 3 erledigt</span>
              </div>
              <div
                class={["mt-3 h-2 overflow-hidden rounded-full bg-white/10"]}
                role="progressbar"
                aria-label="Fortschritt der verfügbaren Schritte"
                aria-valuemin="0"
                aria-valuemax="3"
                aria-valuenow={@completed_steps}
              >
                <div class={[
                  "h-full rounded-full bg-rose-500 transition-all",
                  progress_width(@completed_steps)
                ]}>
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
                    field={@claim_form[:disruption_type]}
                    id="claim-disruption-type"
                    type="select"
                    label="Störung"
                    prompt="Bitte auswählen"
                    options={[{"Verspätung", "delay"}, {"Zugausfall", "cancellation"}]}
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
                        phx-submit="upload_document"
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
                          <span class={["mt-1 text-xs text-slate-500"]}>oder hier ablegen</span>
                        </label>

                        <div
                          :for={entry <- upload.entries}
                          id={"#{kind}-upload-#{entry.ref}"}
                          class={["mt-3 rounded-xl bg-white px-3 py-2.5 text-xs shadow-sm"]}
                        >
                          <p class={["truncate font-semibold text-slate-700"]}>{entry.client_name}</p>
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

                        <button
                          id={"#{kind}-upload-button"}
                          type="submit"
                          disabled={upload.entries == []}
                          phx-disable-with="Wird sicher gespeichert …"
                          class={[
                            "mt-3 inline-flex min-h-10 w-full items-center justify-center gap-2 rounded-lg bg-rose-700 px-3 py-2 text-xs font-semibold text-white transition hover:bg-rose-800 disabled:cursor-not-allowed disabled:bg-slate-300"
                          ]}
                        >
                          <.icon name="hero-lock-closed" class="size-4" /> Sicher speichern
                        </button>
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
                    Vorschläge werden nie automatisch bestätigt. Start, Ziel und Reisedatum kannst du bewusst in die Falldaten übernehmen.
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
          </div>

          <aside class={["space-y-5"]}>
            <section
              id="claim-next-steps"
              class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm"]}
            >
              <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-slate-500"]}>
                Ablauf
              </p>
              <h2 class={["mt-2 text-lg font-semibold text-slate-950"]}>Nächste Bausteine</h2>
              <ol class={["mt-5 space-y-3"]}>
                <li
                  :for={
                    {label, done?} <- [
                      {"Reisendenprofil", @profile_complete?},
                      {"Falldaten", @claim_complete?},
                      {"Ticket & Rechnung", @documents_complete?}
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
                <li class={[
                  "flex items-center gap-3 rounded-xl border border-dashed border-slate-200 px-3.5 py-3 text-slate-400"
                ]}>
                  <span class={[
                    "flex size-7 items-center justify-center rounded-full border border-slate-200"
                  ]}>4</span>
                  <span class={["text-sm font-semibold"]}>Reiseverlauf & PDF-Ausgabe</span>
                </li>
              </ol>
              <p class={["mt-4 rounded-xl bg-amber-50 px-3.5 py-3 text-xs leading-5 text-amber-900"]}>
                Reiseabgleich und druckfertiges Gesamt-PDF folgen mit C04/C05. Deine jetzigen Angaben und Dokumente bleiben erhalten.
              </p>
              <.link
                id="claim-profile-link"
                navigate={~p"/profil"}
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

  defp handle_upload_result(socket, [{:ok, %{document: document, claim: claim}}]) do
    analysis = Tickets.analyze_document(socket.assigns.current_scope, document.id)

    socket =
      socket
      |> load_workspace(claim)
      |> put_flash(:info, "Das Dokument wurde sicher gespeichert.")

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

    suggestions =
      Enum.flat_map(documents, fn document ->
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

    completed_steps =
      Enum.count([profile_complete?, claim_complete?, documents_complete?], & &1)

    socket
    |> assign(:claim, claim)
    |> assign(:claim_form, to_form(changeset))
    |> assign(:documents_by_kind, documents_by_kind)
    |> assign(:documents_by_id, documents_by_id)
    |> assign(:upload_kinds, @upload_kinds)
    |> assign(:claim_complete?, claim_complete?)
    |> assign(:documents_complete?, documents_complete?)
    |> assign(:profile_complete?, profile_complete?)
    |> assign(:completed_steps, completed_steps)
    |> stream(:suggestions, suggestions, reset: true)
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

  defp upload_name("ticket"), do: {:ok, :ticket}
  defp upload_name("invoice"), do: {:ok, :invoice}
  defp upload_name(_kind), do: {:error, :invalid_kind}

  defp transition_status("draft"), do: {:ok, :draft}
  defp transition_status("sent"), do: {:ok, :sent}
  defp transition_status("completed"), do: {:ok, :completed}
  defp transition_status(_status), do: {:error, :invalid_status}

  defp transition_message(:draft), do: "Der Antrag ist wieder zur Bearbeitung geöffnet."
  defp transition_message(:sent), do: "Der Antrag wurde als versendet markiert."
  defp transition_message(:completed), do: "Der Antrag wurde als erledigt markiert."

  defp claim_complete?(claim) do
    Enum.all?(
      [claim.travel_date, claim.origin, claim.destination, claim.disruption_type],
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

  defp progress_width(0), do: "w-0"
  defp progress_width(1), do: "w-1/3"
  defp progress_width(2), do: "w-2/3"
  defp progress_width(3), do: "w-full"

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
