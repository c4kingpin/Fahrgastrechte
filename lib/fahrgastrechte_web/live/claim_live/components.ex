defmodule FahrgastrechteWeb.ClaimLive.Components do
  @moduledoc """
  Pure presentation components for the claim workspace sections.
  """

  use FahrgastrechteWeb, :html

  import FahrgastrechteWeb.ClaimLive.Presentation

  attr :active_step, :atom, required: true
  attr :claim, :any, required: true
  attr :claim_form, :any, required: true
  attr :save_state, :atom, required: true
  attr :step_number, :integer, required: true
  attr :step_states, :map, required: true

  def claim_data(assigns) do
    ~H"""
    <section
      id="claim-data-section"
      hidden={@active_step != :claim}
      aria-labelledby="claim-data-heading"
      data-state={@step_states.claim}
      class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
    >
      <div class={["flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"]}>
        <div>
          <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-rose-700"]}>
            Schritt {@step_number}
          </p>
          <h2
            id="claim-data-heading"
            tabindex="-1"
            class={[
              "mt-2 scroll-mt-28 rounded-lg text-xl font-semibold text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-rose-700"
            ]}
          >
            Reiseverlauf
          </h2>
          <p class={["mt-1 text-sm leading-6 text-slate-500"]}>
            Bestätigte Werte aus Ticket und Rechnung sind bereits übernommen. Ergänze nur noch die Angaben zum Störungsfall; Änderungen werden automatisch gespeichert.
          </p>
        </div>
        <span
          id="claim-save-state"
          data-state={@save_state}
          role="status"
          aria-live="polite"
          class={[
            "inline-flex w-fit items-center gap-2 rounded-full px-3 py-1.5 text-xs font-semibold phx-change-loading:bg-sky-50 phx-change-loading:text-sky-700",
            save_state_style(@save_state)
          ]}
        >
          <.icon
            name="hero-arrow-path"
            class="hidden size-4 motion-safe:animate-spin phx-change-loading:block"
          />
          <span class="size-2 rounded-full bg-current phx-change-loading:hidden"></span>
          <span data-save-label="result" class="phx-change-loading:hidden">
            {save_state_label(@save_state)}
          </span>
          <span data-save-label="saving" class="hidden phx-change-loading:inline">
            Speichert …
          </span>
        </span>
      </div>

      <.form
        for={@claim_form}
        id="claim-form"
        phx-change={JS.push("claim_autosave", loading: "#claim-save-state")}
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
      </.form>
    </section>
    """
  end

  attr :active_step, :atom, required: true
  attr :analysis_tokens, :map, required: true
  attr :documents_by_kind, :map, required: true
  attr :max_file_size_label, :string, required: true
  attr :step_number, :integer, required: true
  attr :step_states, :map, required: true
  attr :upload_form, Phoenix.HTML.Form, required: true
  attr :upload_kinds, :list, required: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true

  def documents(assigns) do
    ~H"""
    <section
      id="claim-documents-section"
      hidden={@active_step != :documents}
      aria-labelledby="claim-documents-heading"
      data-state={@step_states.documents}
      class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
    >
      <div>
        <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-rose-700"]}>
          Schritt {@step_number}
        </p>
        <h2
          id="claim-documents-heading"
          tabindex="-1"
          class={[
            "mt-2 scroll-mt-28 rounded-lg text-xl font-semibold text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-rose-700"
          ]}
        >
          Ticket & Rechnung
        </h2>
        <p class={["mt-1 text-sm leading-6 text-slate-500"]}>
          Ziehe Ticket und Rechnung gemeinsam in die Fläche oder wähle beide Dateien auf einmal aus. Wir erkennen automatisch, welches PDF welches Dokument ist, werten es aus und speichern es privat. Maximal {@max_file_size_label} je Datei.
        </p>
      </div>

      <.form
        for={@upload_form}
        id="document-upload-form"
        phx-change="validate_upload"
        phx-drop-target={@upload.ref}
        class={["mt-6"]}
      >
        <label class={[
          "group flex min-h-32 cursor-pointer flex-col items-center justify-center rounded-xl border border-dashed border-slate-300 bg-white px-4 py-5 text-center transition hover:border-rose-300 hover:bg-rose-50/40"
        ]}>
          <.live_file_input upload={@upload} class="sr-only" />
          <span class={[
            "rounded-xl bg-rose-50 p-2.5 text-rose-700 transition group-hover:-translate-y-0.5"
          ]}>
            <.icon name="hero-arrow-up-tray" class="size-5" />
          </span>
          <span class={["mt-3 text-sm font-semibold text-slate-800"]}>
            PDFs hierher ziehen oder auswählen
          </span>
          <span class={["mt-1 text-xs text-slate-500"]}>
            Ticket und Rechnung zusammen hochladen · Upload und Auswertung starten automatisch
          </span>
        </label>

        <div
          :for={entry <- @upload.entries}
          id={"document-upload-#{entry.ref}"}
          class={["mt-3 rounded-xl bg-slate-50 px-3 py-2.5 text-xs shadow-sm"]}
        >
          <div class={["flex items-start justify-between gap-3"]}>
            <p class={["min-w-0 truncate font-semibold text-slate-700"]}>
              {entry.client_name}
            </p>
            <button
              id={"cancel-document-upload-#{entry.ref}"}
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              aria-label={"Upload von #{entry.client_name} abbrechen"}
              class="shrink-0 rounded-md p-1 text-slate-500 transition hover:bg-slate-100 hover:text-slate-950"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <div
            class={["mt-2 h-1.5 overflow-hidden rounded-full bg-white"]}
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
            {entry.progress}% · wird sicher gespeichert, erkannt und ausgewertet
          </p>
          <p :for={error <- upload_errors(@upload, entry)} class={["mt-1 text-rose-700"]}>
            {upload_error_message(error)}
          </p>
        </div>
        <p :for={error <- upload_errors(@upload)} class={["mt-2 text-xs text-rose-700"]}>
          {upload_error_message(error)}
        </p>
      </.form>

      <div class={["mt-6 grid gap-4 lg:grid-cols-2"]}>
        <%= for kind <- @upload_kinds do %>
          <% document = Map.get(@documents_by_kind, kind) %>
          <article
            id={"#{kind}-document-card"}
            class={["rounded-2xl border border-slate-200 bg-slate-50 p-4 sm:p-5"]}
          >
            <div class={["flex items-start justify-between gap-3"]}>
              <div class={["flex items-start gap-3"]}>
                <span class={["rounded-xl bg-white p-2.5 text-rose-700 shadow-sm"]}>
                  <.icon
                    name={if(kind == :ticket, do: "hero-ticket", else: "hero-receipt-percent")}
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
                  <span
                    id={"analysis-status-#{kind}"}
                    role="status"
                    aria-live="polite"
                    class={[
                      "rounded-full px-2.5 py-1 text-[0.68rem] font-bold",
                      analysis_style(document.analysis_status)
                    ]}
                  >
                    {analysis_status_text(document, @analysis_tokens)}
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
              <p class={["mt-3 text-xs text-slate-500"]}>
                Zum Ersetzen einfach eine neue Datei oben in die Fläche ziehen.
              </p>
            <% else %>
              <p class={["mt-5 text-xs text-slate-500"]}>
                Noch kein passendes Dokument erkannt.
              </p>
            <% end %>
          </article>
        <% end %>
      </div>
    </section>
    """
  end

  attr :active_step, :atom, required: true
  attr :claim, :any, required: true
  attr :planned_journey, :any, required: true
  attr :actual_journey, :any, required: true
  attr :proposed_suggestions?, :boolean, required: true
  attr :suggestions_by_id, :map, required: true
  attr :step_paths, :map, required: true
  attr :order_number_mismatch, :any, default: nil

  def trip_summary(assigns) do
    ~H"""
    <section
      id="trip-summary-section"
      hidden={@active_step not in [:suggestions, :claim, :planned, :actual]}
      aria-labelledby="trip-summary-heading"
      class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
    >
      <div class={["flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"]}>
        <div>
          <h2
            id="trip-summary-heading"
            tabindex="-1"
            class={[
              "scroll-mt-28 rounded-lg text-xl font-semibold text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-rose-700"
            ]}
          >
            Deine Reise im Überblick
          </h2>
          <p class={["mt-1 text-sm leading-6 text-slate-500"]}>
            Stimmt das? Dann bestätige alles auf einmal statt jede Angabe einzeln zu prüfen.
          </p>
        </div>
        <button
          :if={@proposed_suggestions?}
          id="confirm-all-facts"
          type="button"
          phx-click="set_all_suggestions_state"
          phx-value-state="accepted"
          class={[
            "inline-flex min-h-11 shrink-0 items-center gap-2 rounded-xl bg-rose-700 px-4 py-2.5 text-sm font-semibold text-white shadow-sm transition hover:bg-rose-800"
          ]}
        >
          <.icon name="hero-check" class="size-4" /> Ja, diese Angaben stimmen
        </button>
      </div>

      <dl class={["mt-6 grid gap-5 sm:grid-cols-2"]}>
        <div>
          <dt class={["text-xs font-semibold uppercase tracking-wide text-slate-500"]}>Strecke</dt>
          <dd
            id="trip-summary-route"
            class={["mt-1 flex items-center justify-between gap-2 text-sm text-slate-950"]}
          >
            {trip_summary_route(@claim, @suggestions_by_id)}
            <.link
              patch={@step_paths.claim}
              class={["shrink-0 text-xs font-semibold text-rose-700 hover:text-rose-800"]}
            >
              Ändern
            </.link>
          </dd>
        </div>
        <div>
          <dt class={["text-xs font-semibold uppercase tracking-wide text-slate-500"]}>Reisedatum</dt>
          <dd
            id="trip-summary-date"
            class={["mt-1 flex items-center justify-between gap-2 text-sm text-slate-950"]}
          >
            {trip_summary_date(@claim, @suggestions_by_id)}
            <.link
              patch={@step_paths.claim}
              class={["shrink-0 text-xs font-semibold text-rose-700 hover:text-rose-800"]}
            >
              Ändern
            </.link>
          </dd>
        </div>
        <div>
          <dt class={["text-xs font-semibold uppercase tracking-wide text-slate-500"]}>Zug</dt>
          <dd
            id="trip-summary-train"
            class={["mt-1 flex items-center justify-between gap-2 text-sm text-slate-950"]}
          >
            {trip_summary_train(@planned_journey, @suggestions_by_id)}
            <.link
              patch={@step_paths.planned}
              class={["shrink-0 text-xs font-semibold text-rose-700 hover:text-rose-800"]}
            >
              Ändern
            </.link>
          </dd>
        </div>
        <div>
          <dt class={["text-xs font-semibold uppercase tracking-wide text-slate-500"]}>
            Planmäßige Zeiten
          </dt>
          <dd
            id="trip-summary-scheduled"
            class={["mt-1 flex items-center justify-between gap-2 text-sm text-slate-950"]}
          >
            {trip_summary_scheduled(@planned_journey)}
            <.link
              patch={@step_paths.planned}
              class={["shrink-0 text-xs font-semibold text-rose-700 hover:text-rose-800"]}
            >
              Ändern
            </.link>
          </dd>
        </div>
        <div>
          <dt class={["text-xs font-semibold uppercase tracking-wide text-slate-500"]}>
            Verspätung / Ausfall
          </dt>
          <dd
            id="trip-summary-disruption"
            class={["mt-1 flex items-center justify-between gap-2 text-sm text-slate-950"]}
          >
            {trip_summary_disruption(@claim, @actual_journey)}
            <.link
              patch={@step_paths.actual}
              class={["shrink-0 text-xs font-semibold text-rose-700 hover:text-rose-800"]}
            >
              Ändern
            </.link>
          </dd>
        </div>
        <div>
          <dt class={["text-xs font-semibold uppercase tracking-wide text-slate-500"]}>
            Tatsächliche Ankunft
          </dt>
          <dd
            id="trip-summary-actual-arrival"
            class={["mt-1 flex items-center justify-between gap-2 text-sm text-slate-950"]}
          >
            {trip_summary_actual_arrival(@actual_journey)}
            <.link
              patch={@step_paths.actual}
              class={["shrink-0 text-xs font-semibold text-rose-700 hover:text-rose-800"]}
            >
              Ändern
            </.link>
          </dd>
        </div>
        <div>
          <dt class={["text-xs font-semibold uppercase tracking-wide text-slate-500"]}>
            Auftragsnummer
          </dt>
          <dd id="trip-summary-order-number" class={["mt-1 text-sm text-slate-950"]}>
            {trip_summary_order_number(@suggestions_by_id)}
          </dd>
          <p
            :if={@order_number_mismatch}
            id="order-number-mismatch-warning"
            class={["mt-1 text-xs font-semibold text-amber-700"]}
          >
            Ticket ({@order_number_mismatch.ticket}) und Rechnung ({@order_number_mismatch.invoice}) haben unterschiedliche Auftragsnummern. Bitte prüfe, ob beide Dokumente wirklich zusammengehören.
          </p>
        </div>
      </dl>
    </section>
    """
  end

  attr :active_step, :atom, required: true
  attr :claim, :any, required: true
  attr :documents_by_id, :map, required: true
  attr :proposed_suggestions?, :boolean, required: true
  attr :step_number, :integer, required: true
  attr :step_states, :map, required: true
  attr :streams, :any, required: true
  attr :suggestion_correction_form, :any, required: true
  attr :suggestions_empty?, :boolean, required: true

  def suggestions(assigns) do
    ~H"""
    <section
      id="ticket-suggestions-section"
      hidden={@active_step != :suggestions}
      aria-labelledby="ticket-suggestions-heading"
      data-state={@step_states.suggestions}
      class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
    >
      <div class={["flex items-start gap-3"]}>
        <span class={["rounded-xl bg-sky-50 p-2.5 text-sky-700"]}><.icon
          name="hero-sparkles"
          class="size-5"
        /></span>
        <div>
          <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-sky-700"]}>
            Schritt {@step_number}
          </p>
          <h2
            id="ticket-suggestions-heading"
            tabindex="-1"
            class={[
              "mt-2 scroll-mt-28 rounded-lg text-xl font-semibold text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-sky-700"
            ]}
          >
            Erkannte Angaben prüfen
          </h2>
          <p class={["mt-1 text-sm leading-6 text-slate-500"]}>
            Ticket und Rechnung werden direkt nach der Auswahl ausgewertet. Die erkannten Werte bleiben nachvollziehbar und werden erst nach deiner Prüfung übernommen.
          </p>
        </div>
      </div>

      <div id="ticket-suggestions" class={["mt-6 space-y-5"]}>
        <div
          :if={!@suggestions_empty?}
          id="suggestion-bulk-actions"
          class={[
            "flex flex-col gap-3 rounded-2xl bg-slate-50 p-4 sm:flex-row sm:items-center sm:justify-between"
          ]}
        >
          <p class={["text-sm font-semibold text-slate-800"]}>
            Alle noch offenen Werte gemeinsam prüfen
          </p>
          <div class={["flex flex-wrap gap-2"]}>
            <button
              id="accept-all-suggestions"
              type="button"
              phx-click="set_all_suggestions_state"
              phx-value-state="accepted"
              disabled={!@proposed_suggestions? || !editable?(@claim.status)}
              class="inline-flex min-h-10 items-center gap-2 rounded-lg bg-emerald-700 px-3 py-2 text-xs font-semibold text-white transition hover:bg-emerald-800 disabled:opacity-40"
            >
              <.icon name="hero-check" class="size-4" /> Alle übernehmen
            </button>
            <button
              id="reject-all-suggestions"
              type="button"
              phx-click="set_all_suggestions_state"
              phx-value-state="rejected"
              disabled={!@proposed_suggestions? || !editable?(@claim.status)}
              class="inline-flex min-h-10 items-center gap-2 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-700 transition hover:border-slate-300 disabled:opacity-40"
            >
              <.icon name="hero-x-mark" class="size-4" /> Alle verwerfen
            </button>
          </div>
        </div>

        <div
          :if={@suggestions_empty?}
          id="suggestions-empty"
          class={[
            "rounded-2xl border border-dashed border-slate-300 bg-slate-50 px-5 py-8 text-center"
          ]}
        >
          <.icon name="hero-document-magnifying-glass" class="mx-auto size-7 text-slate-400" />
          <p class={["mt-3 text-sm font-semibold text-slate-800"]}>Noch keine Vorschläge</p>
          <p class={["mt-1 text-xs leading-5 text-slate-500"]}>
            Das PDF enthält möglicherweise keinen lesbaren Text. Trage die Angaben direkt unten ein – der manuelle Weg bleibt immer verfügbar.
          </p>
        </div>

        <.suggestion_group
          id="route-suggestions"
          topic="route"
          label="Reise und Strecke"
          items={@streams.route_suggestions}
          documents_by_id={@documents_by_id}
          editable?={editable?(@claim.status)}
        />
        <.suggestion_group
          id="booking-suggestions"
          topic="booking"
          label="Buchung und Preis"
          items={@streams.booking_suggestions}
          documents_by_id={@documents_by_id}
          editable?={editable?(@claim.status)}
        />
        <.suggestion_group
          id="other-suggestions"
          topic="other"
          label="Weitere Angaben"
          items={@streams.other_suggestions}
          documents_by_id={@documents_by_id}
          editable?={editable?(@claim.status)}
        />

        <.form
          for={@suggestion_correction_form}
          id="suggestion-correction-form"
          phx-submit="save_suggestion_corrections"
          class="rounded-2xl border border-slate-200 bg-slate-50 p-4 sm:p-5"
        >
          <h3 class="text-sm font-semibold text-slate-950">Angaben manuell korrigieren</h3>
          <p class="mt-1 text-xs leading-5 text-slate-500">
            Diese Werte überschreiben erkannte Angaben und können jederzeit erneut geändert werden.
          </p>
          <div class="mt-4 grid gap-4 sm:grid-cols-3">
            <.input
              field={@suggestion_correction_form[:travel_date]}
              type="date"
              label="Reisedatum"
            />
            <.input field={@suggestion_correction_form[:origin]} label="Startbahnhof" />
            <.input field={@suggestion_correction_form[:destination]} label="Zielbahnhof" />
          </div>
          <button
            id="save-suggestion-corrections"
            type="submit"
            disabled={!editable?(@claim.status)}
            class="mt-4 inline-flex min-h-10 items-center gap-2 rounded-lg bg-slate-950 px-4 py-2 text-xs font-semibold text-white transition hover:bg-slate-800 disabled:opacity-40"
          >
            <.icon name="hero-pencil-square" class="size-4" /> Manuelle Angaben speichern
          </button>
        </.form>
      </div>
    </section>
    """
  end

  attr :active_step, :atom, required: true
  attr :claim, :any, required: true
  attr :connection_search_form, :any, required: true
  attr :connection_search_state, :atom, required: true
  attr :destination_station_options, :list, required: true
  attr :origin_station_options, :list, required: true
  attr :planned_complete?, :boolean, required: true
  attr :planned_form, :any, required: true
  attr :planned_state, :atom, required: true
  attr :step_number, :integer, required: true
  attr :streams, :any, required: true

  def planned_journey(assigns) do
    ~H"""
    <section
      id="planned-journey-section"
      hidden={@active_step != :planned}
      aria-labelledby="planned-journey-heading"
      data-state={@planned_state}
      class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
    >
      <div class={["flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"]}>
        <div>
          <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-rose-700"]}>
            Schritt {@step_number}
          </p>
          <h2
            id="planned-journey-heading"
            tabindex="-1"
            class={[
              "mt-2 scroll-mt-28 rounded-lg text-xl font-semibold text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-rose-700"
            ]}
          >
            Verbindung und Verspätung auswählen
          </h2>
          <p class={["mt-1 max-w-2xl text-sm leading-6 text-slate-500"]}>
            Die DB-Abfrage zeigt planmäßige Zeit, aktuelle Prognose, Verspätungsminuten und Ausfälle direkt am Treffer. Die Auswahl bleibt bis zu deiner Bestätigung ein Vorschlag.
          </p>
        </div>
        <.step_badge state={@planned_state} />
      </div>

      <details
        id="connection-search-drawer"
        class={["mt-6 rounded-2xl border border-slate-200 bg-white"]}
        open={!@planned_complete?}
      >
        <summary class={[
          "cursor-pointer px-4 py-4 text-sm font-semibold text-slate-800 sm:px-5"
        ]}>
          Verbindung selbst suchen
        </summary>
        <.form
          for={@connection_search_form}
          id="connection-search-form"
          phx-submit="search_connections"
          phx-change="suggest_stations"
          class={["border-t border-slate-200 bg-slate-50 p-4 sm:p-5"]}
        >
          <div class={["grid gap-4 sm:grid-cols-2"]}>
            <.input
              field={@connection_search_form[:origin]}
              id="connection-origin"
              label="Startbahnhof"
              list="origin-stations"
              autocomplete="off"
              phx-debounce="350"
            />
            <datalist id="origin-stations">
              <option :for={station <- @origin_station_options} value={station}></option>
            </datalist>
            <.input
              field={@connection_search_form[:destination]}
              id="connection-destination"
              label="Zielbahnhof"
              list="destination-stations"
              autocomplete="off"
              phx-debounce="350"
            />
            <datalist id="destination-stations">
              <option :for={station <- @destination_station_options} value={station}></option>
            </datalist>
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
      </details>

      <p id="connection-search-status" role="status" aria-live="polite" class="sr-only">
        {connection_search_status_message(@connection_search_state)}
      </p>

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
        {connection_search_error_message(@connection_search_state)}
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
              <p class="mt-1 text-xs text-slate-500">
                {candidate_transfer_label(item.candidate)} · Quelle {candidate_source(item.candidate)}
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
          <details
            id="manual-transfer-editor"
            class="mt-5 rounded-xl border border-slate-200 bg-slate-50"
          >
            <summary class="cursor-pointer px-4 py-3 text-sm font-semibold text-slate-800">
              Umstieg oder weiteren Zug ergänzen
            </summary>
            <div class="grid gap-5 border-t border-slate-200 p-4 sm:grid-cols-2">
              <.input
                field={@planned_form[:via_name]}
                label="Umstiegsbahnhof"
                placeholder="Leer lassen für Direktfahrt"
              />
              <div class="hidden sm:block"></div>
              <.input
                field={@planned_form[:transfer_arrival]}
                type="datetime-local"
                label="Ankunft am Umstieg"
              />
              <.input
                field={@planned_form[:transfer_departure]}
                type="datetime-local"
                label="Weiterfahrt ab Umstieg"
              />
              <.input field={@planned_form[:second_category]} label="Zuggattung Weiterfahrt" />
              <.input field={@planned_form[:second_number]} label="Zugnummer Weiterfahrt" />
            </div>
            <p class="border-t border-slate-200 px-4 py-3 text-xs leading-5 text-slate-500">
              Für weitere Umstiege kann die gespeicherte Timeline abschnittsweise korrigiert werden. Ohne API-Daten bleibt die manuelle Verbindung vollständig nutzbar.
            </p>
          </details>
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
    """
  end

  defp connection_search_error_message({:error, :invalid_datetime}),
    do: "Bitte gib eine gültige geplante Abfahrtszeit an."

  defp connection_search_error_message({:error, {:upstream, :invalid_query}}),
    do: "Bitte gib Start- und Zielbahnhof an."

  defp connection_search_error_message({:error, {:upstream, :invalid_time_window}}),
    do: "Der gewählte Zeitraum ist ungültig. Bitte prüfe die Abfahrtszeit."

  defp connection_search_error_message({:error, _reason}),
    do:
      "Die Bahndaten sind gerade nicht verfügbar. Deine Angaben bleiben erhalten; bestätige die Verbindung manuell."

  defp connection_search_status_message(:idle), do: ""
  defp connection_search_status_message(:loading), do: "Verbindungen werden geladen …"

  defp connection_search_status_message(:empty),
    do: "Keine eindeutige Verbindung gefunden."

  defp connection_search_status_message(:results), do: "Verbindungen gefunden."

  defp connection_search_status_message({:error, _reason} = state),
    do: connection_search_error_message(state)

  attr :active_step, :atom, required: true
  attr :actual_form, :any, required: true
  attr :actual_journey, :any, required: true
  attr :actual_state, :atom, required: true
  attr :claim, :any, required: true
  attr :step_number, :integer, required: true
  attr :streams, :any, required: true

  def actual_journey(assigns) do
    ~H"""
    <section
      id="actual-journey-section"
      hidden={@active_step != :actual}
      aria-labelledby="actual-journey-heading"
      data-state={@actual_state}
      class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
    >
      <div class={["flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"]}>
        <div>
          <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-rose-700"]}>
            Schritt {@step_number}
          </p>
          <h2
            id="actual-journey-heading"
            tabindex="-1"
            class={[
              "mt-2 scroll-mt-28 rounded-lg text-xl font-semibold text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-rose-700"
            ]}
          >
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
          aria-pressed={if(@claim.disruption_cause == :delay, do: "true", else: "false")}
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
          aria-pressed={if(@claim.disruption_cause == :cancellation, do: "true", else: "false")}
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

      <div
        id="actual-journey-timeline"
        phx-update="stream"
        class="mt-5 grid gap-3"
        aria-label="Timeline der tatsächlichen Reise"
      >
        <p
          id="actual-journey-timeline-empty"
          class="hidden rounded-xl bg-slate-50 p-4 text-sm text-slate-500 only:block"
        >
          Noch kein Reiseabschnitt bestätigt. Trage den Verlauf unten manuell ein.
        </p>
        <article
          :for={{dom_id, segment} <- @streams.actual_segments}
          id={dom_id}
          class={[
            "relative rounded-2xl border p-4 pl-12",
            if(segment.cancelled,
              do: "border-rose-200 bg-rose-50",
              else: "border-slate-200 bg-white"
            )
          ]}
        >
          <span class={[
            "absolute left-4 top-4 flex size-6 items-center justify-center rounded-full text-white",
            if(segment.cancelled, do: "bg-rose-700", else: "bg-slate-950")
          ]}>
            <.icon
              name={if(segment.cancelled, do: "hero-x-mark", else: "hero-arrow-right")}
              class="size-4"
            />
          </span>
          <div class="flex flex-wrap items-center gap-2">
            <strong class="text-sm text-slate-950">{train_label(segment)}</strong>
            <span
              :if={segment.cancelled}
              class="rounded-full bg-rose-100 px-2 py-0.5 text-xs font-bold text-rose-800"
            >Ausgefallen</span>
          </div>
          <p class="mt-1 text-sm text-slate-700">
            {segment.origin_name} → {segment.destination_name}
          </p>
          <p class="mt-1 text-xs text-slate-500">
            Plan {format_datetime(segment.scheduled_departure)} – {format_datetime(
              segment.scheduled_arrival
            )} · tatsächlich {format_optional_datetime(
              segment.actual_arrival || segment.estimated_arrival
            )}
          </p>
        </article>
      </div>

      <details
        id="actual-journey-manual"
        class={["mt-6 rounded-2xl border border-slate-200 bg-white"]}
        open={@actual_state != :confirmed}
      >
        <summary class={[
          "cursor-pointer px-4 py-4 text-sm font-semibold text-slate-800 sm:px-5"
        ]}>
          Tatsächlichen Verlauf manuell eingeben oder korrigieren
        </summary>
        <.form
          for={@actual_form}
          id="actual-journey-form"
          phx-submit="save_actual_journey"
          class={["space-y-5 border-t border-slate-200 p-4 sm:p-5"]}
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
      </details>
    </section>
    """
  end

  attr :active_step, :atom, required: true
  attr :actual_complete?, :boolean, required: true
  attr :claim, :any, required: true
  attr :claim_complete?, :boolean, required: true
  attr :documents_complete?, :boolean, required: true
  attr :export_state, :atom, required: true
  attr :export_state_label, :any, required: true
  attr :exports_available?, :boolean, required: true
  attr :planned_complete?, :boolean, required: true
  attr :payout_form, :any, required: true
  attr :profile_complete?, :boolean, required: true
  attr :profile_error, :any, required: true
  attr :review_complete?, :boolean, required: true
  attr :step_number, :integer, required: true
  attr :step_paths, :map, required: true
  attr :streams, :any, required: true
  attr :suggestions_complete?, :boolean, required: true

  def review(assigns) do
    ~H"""
    <section
      id="claim-review-export-section"
      hidden={@active_step != :review}
      aria-labelledby="claim-review-heading"
      data-state={@export_state_label}
      class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
    >
      <div class={["flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"]}>
        <div>
          <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-rose-700"]}>
            Schritt {@step_number}
          </p>
          <h2
            id="claim-review-heading"
            tabindex="-1"
            class={[
              "mt-2 scroll-mt-28 rounded-lg text-xl font-semibold text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-rose-700"
            ]}
          >
            Prüfen und Gesamt-PDF erstellen
          </h2>
          <p class={["mt-1 text-sm leading-6 text-slate-500"]}>
            Die Ausgabe enthält Deckblatt, offizielles Formular, Ticket und Rechnung. Das Unterschriftsfeld bleibt frei.
          </p>
        </div>
        <.step_badge state={@export_state_label} />
      </div>

      <div
        :if={@profile_error}
        id="profile-read-error"
        class={["mt-6 rounded-2xl bg-rose-50 p-4 text-sm text-rose-900"]}
      >
        Das Reisendenprofil konnte nicht entschlüsselt werden. Bitte öffne das Profil erneut
        oder wende dich an den Betrieb.
      </div>

      <div id="review-checklist" class={["mt-6 grid gap-3 sm:grid-cols-2"]}>
        <.review_check label="Reisendenprofil" done?={@profile_complete?} linked?={false} />
        <.review_check
          label="Ticket & Rechnung"
          done?={@documents_complete?}
          href={Map.fetch!(@step_paths, :documents)}
        />
        <.review_check
          label="Erkannte Angaben"
          done?={@suggestions_complete?}
          href={Map.fetch!(@step_paths, :suggestions)}
        />
        <.review_check
          label="Reiseverlauf"
          done?={@claim_complete?}
          href={Map.fetch!(@step_paths, :claim)}
        />
        <.review_check
          label="Geplante Verbindung"
          done?={@planned_complete?}
          href={Map.fetch!(@step_paths, :planned)}
        />
        <.review_check
          label="Tatsächliche Reise"
          done?={@actual_complete?}
          href={Map.fetch!(@step_paths, :actual)}
        />
      </div>

      <section
        :if={!@profile_complete?}
        id="payout-form-section"
        class="mt-6 rounded-2xl border border-slate-200 bg-slate-50 p-4 sm:p-5"
      >
        <h3 class="text-sm font-semibold text-slate-950">Auszahlung ergänzen</h3>
        <p class="mt-1 text-xs leading-5 text-slate-500">
          Diese Angaben werden für zukünftige Anträge gespeichert. IBAN und BIC liegen verschlüsselt.
        </p>

        <.form
          for={@payout_form}
          id="payout-form"
          phx-change="payout_validate"
          phx-submit="payout_save"
          class="mt-4 space-y-5"
        >
          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              field={@payout_form[:salutation]}
              id="payout-salutation"
              type="select"
              label="Anrede *"
              prompt="Bitte auswählen"
              options={[{"Frau", "female"}, {"Herr", "male"}, {"Neutrale Anrede", "neutral"}]}
            />
            <.input field={@payout_form[:first_name]} id="payout-first-name" label="Vorname *" />
            <.input field={@payout_form[:last_name]} id="payout-last-name" label="Nachname *" />
            <.input field={@payout_form[:street]} id="payout-street" label="Straße *" />
            <.input field={@payout_form[:house_number]} id="payout-house-number" label="Hausnummer *" />
            <.input field={@payout_form[:postal_code]} id="payout-postal-code" label="Postleitzahl *" />
            <.input field={@payout_form[:city]} id="payout-city" label="Ort *" />
            <.input field={@payout_form[:country]} id="payout-country" label="Staat *" />
          </div>
          <div class="grid gap-4 sm:grid-cols-3">
            <.input
              field={@payout_form[:account_holder]}
              id="payout-account-holder"
              label="Kontoinhaber *"
            />
            <.input field={@payout_form[:iban]} id="payout-iban" label="IBAN *" autocomplete="off" />
            <.input field={@payout_form[:bic]} id="payout-bic" label="BIC *" autocomplete="off" />
          </div>
          <button
            id="payout-save"
            type="submit"
            phx-disable-with="Wird gespeichert …"
            class="inline-flex min-h-11 items-center gap-2 rounded-xl bg-slate-950 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-slate-800"
          >
            <.icon name="hero-check" class="size-4" /> Auszahlungsdaten speichern
          </button>
        </.form>
      </section>

      <section
        id="official-form-review"
        class="mt-6 rounded-2xl border border-slate-200 bg-slate-50 p-4 sm:p-5"
      >
        <h3 class="text-sm font-semibold text-slate-950">Angaben in Formularreihenfolge</h3>
        <dl class="mt-4 grid gap-4 text-sm sm:grid-cols-2">
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-slate-500">
              Reisestrecke
            </dt><dd class="mt-1 font-semibold text-slate-900">{route_label(@claim)}</dd>
          </div>
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-slate-500">
              Reisedatum
            </dt><dd class="mt-1 font-semibold text-slate-900">
              {format_date(@claim.travel_date)}
            </dd>
          </div>
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-slate-500">
              Reiseergebnis
            </dt><dd class="mt-1 font-semibold text-slate-900">
              {journey_outcome_label(@claim.journey_outcome)}
            </dd>
          </div>
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-slate-500">
              Ursache
            </dt><dd class="mt-1 font-semibold text-slate-900">
              {disruption_label(@claim.disruption_cause)}
            </dd>
          </div>
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-slate-500">
              Fahrtrichtung
            </dt><dd class="mt-1 font-semibold text-slate-900">
              {journey_direction_label(@claim.journey_direction)}
            </dd>
          </div>
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-slate-500">
              Auszahlung
            </dt><dd class="mt-1 font-semibold text-slate-900">Überweisung</dd>
          </div>
        </dl>
      </section>

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
          {source_label(source.operation)} · {source.provider} · {format_datetime(source.fetched_at)}
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
      <p id="export-status" role="status" aria-live="polite" class="sr-only">
        {if @export_state == :generating, do: "PDF wird erstellt …"}
      </p>

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

      <section
        :if={@exports_available?}
        id="submission-checklist"
        class="mt-6 rounded-2xl border border-violet-200 bg-violet-50 p-4 sm:p-5"
      >
        <h3 class="text-sm font-semibold text-violet-950">Nach dem Download</h3>
        <ol class="mt-3 grid gap-2 text-sm text-violet-950 sm:grid-cols-2">
          <li class="flex items-center gap-2">
            <span class="flex size-6 items-center justify-center rounded-full bg-violet-700 text-xs font-bold text-white">1</span>
            Gesamt-PDF herunterladen
          </li>
          <li class="flex items-center gap-2">
            <span class="flex size-6 items-center justify-center rounded-full bg-violet-700 text-xs font-bold text-white">2</span>
            Formular unterschreiben
          </li>
          <li class="flex items-center gap-2">
            <span class="flex size-6 items-center justify-center rounded-full bg-violet-700 text-xs font-bold text-white">3</span>
            Ticket und Rechnung prüfen
          </li>
          <li class="flex items-center gap-2">
            <span class="flex size-6 items-center justify-center rounded-full bg-violet-700 text-xs font-bold text-white">4</span>
            Antrag versenden
          </li>
        </ol>
      </section>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :topic, :string, required: true
  attr :label, :string, required: true
  attr :items, :any, required: true
  attr :documents_by_id, :map, required: true
  attr :editable?, :boolean, required: true

  def suggestion_group(assigns) do
    ~H"""
    <section id={@id} class="rounded-2xl border border-slate-200 bg-white p-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <h3 class="text-sm font-semibold text-slate-950">{@label}</h3>
        <div class="flex flex-wrap gap-2">
          <button
            id={"accept-#{@topic}-suggestions"}
            type="button"
            phx-click="set_suggestion_group_state"
            phx-value-topic={@topic}
            phx-value-state="accepted"
            disabled={!@editable?}
            class="inline-flex min-h-9 items-center gap-1.5 rounded-lg bg-emerald-50 px-3 py-2 text-xs font-semibold text-emerald-800 transition hover:bg-emerald-100 disabled:opacity-40"
          >
            <.icon name="hero-check" class="size-4" /> Gruppe übernehmen
          </button>
          <button
            id={"reject-#{@topic}-suggestions"}
            type="button"
            phx-click="set_suggestion_group_state"
            phx-value-topic={@topic}
            phx-value-state="rejected"
            disabled={!@editable?}
            class="inline-flex min-h-9 items-center gap-1.5 rounded-lg bg-slate-50 px-3 py-2 text-xs font-semibold text-slate-700 transition hover:bg-slate-100 disabled:opacity-40"
          >
            <.icon name="hero-x-mark" class="size-4" /> Gruppe verwerfen
          </button>
        </div>
      </div>
      <div id={"#{@id}-items"} phx-update="stream" class="mt-3 grid gap-3">
        <p
          id={"#{@id}-empty"}
          class="hidden rounded-xl bg-slate-50 p-3 text-xs text-slate-500 only:block"
        >
          Keine erkannten Werte in diesem Bereich.
        </p>
        <article
          :for={{dom_id, suggestion} <- @items}
          id={dom_id}
          class={[
            "rounded-xl border p-4 transition",
            suggestion_card_style(suggestion.state)
          ]}
        >
          <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <span class="text-xs font-bold uppercase tracking-[0.14em] text-slate-500">
                  {suggestion_field_label(suggestion.field)}
                </span>
                <span class="rounded-full bg-white px-2 py-0.5 text-[0.68rem] font-semibold text-slate-500 shadow-sm">
                  {confidence_label(suggestion.confidence)}
                </span>
                <span
                  :if={suggestion_unresolved?(suggestion)}
                  class="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-[0.68rem] font-semibold text-amber-800"
                >
                  <.icon name="hero-exclamation-triangle" class="size-3" /> Kein Bahnhof gefunden
                </span>
              </div>
              <p class="mt-2 text-sm font-semibold text-slate-950">{suggestion_value(suggestion)}</p>
              <p
                :if={suggestion_unresolved?(suggestion)}
                class="mt-1 text-xs leading-5 text-amber-800"
              >
                Dieser Text konnte nicht gegen einen echten Bahnhof abgeglichen werden. Bitte vor dem Übernehmen prüfen und ggf. korrigieren.
              </p>
              <p class="mt-2 text-xs leading-5 text-slate-500">
                {source_document_name(@documents_by_id, suggestion.document_id)} · Seite {suggestion.source_page}: „{suggestion.source_excerpt}“
              </p>
            </div>
            <div class="flex shrink-0 flex-wrap gap-2">
              <%= if suggestion.state == :proposed do %>
                <button
                  id={"accept-suggestion-#{suggestion.id}"}
                  type="button"
                  phx-click="set_suggestion_state"
                  phx-value-id={suggestion.id}
                  phx-value-state="accepted"
                  disabled={!@editable?}
                  class="inline-flex min-h-9 items-center gap-1.5 rounded-lg bg-emerald-700 px-3 py-2 text-xs font-semibold text-white transition hover:bg-emerald-800 disabled:opacity-40"
                >
                  <.icon name="hero-check" class="size-4" /> {accept_label(suggestion.field)}
                </button>
                <button
                  id={"reject-suggestion-#{suggestion.id}"}
                  type="button"
                  phx-click="set_suggestion_state"
                  phx-value-id={suggestion.id}
                  phx-value-state="rejected"
                  disabled={!@editable?}
                  class="inline-flex min-h-9 items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 transition hover:border-slate-300 disabled:opacity-40"
                >
                  <.icon name="hero-x-mark" class="size-4" /> Verwerfen
                </button>
              <% else %>
                <span class={[
                  "inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-semibold",
                  suggestion_state_style(suggestion.state)
                ]}>
                  <.icon
                    name={if(suggestion.state == :accepted, do: "hero-check", else: "hero-x-mark")}
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
  attr :href, :string, default: nil
  attr :navigate, :boolean, default: false
  attr :linked?, :boolean, default: true

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
      <span :if={@done?} class="ml-auto text-xs font-semibold text-emerald-700">Bestätigt</span>
      <span :if={!@done? && !@linked?} class="ml-auto text-xs font-semibold text-amber-800">
        Siehe unten
      </span>
      <.link
        :if={!@done? && @linked? && !@navigate}
        patch={@href}
        class="ml-auto rounded-lg px-2 py-1 text-xs font-bold text-amber-900 underline decoration-amber-400 underline-offset-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-amber-700"
      >
        Öffnen
      </.link>
      <.link
        :if={!@done? && @linked? && @navigate}
        navigate={@href}
        class="ml-auto rounded-lg px-2 py-1 text-xs font-bold text-amber-900 underline decoration-amber-400 underline-offset-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-amber-700"
      >
        Öffnen
      </.link>
    </div>
    """
  end
end
