defmodule FahrgastrechteWeb.ClaimLive.Show do
  use FahrgastrechteWeb, :live_view

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.BicLookup
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.ClaimWorkspace
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Exports
  alias Fahrgastrechte.GermanDateTime
  alias Fahrgastrechte.Tickets
  alias FahrgastrechteWeb.ClaimLive.Components

  import FahrgastrechteWeb.ClaimLive.Presentation

  @upload_kinds ClaimWorkspace.upload_kinds()
  @steps [
    %{
      id: :documents,
      slug: "dokumente",
      label: "Ticket & Rechnung",
      heading_id: "claim-documents-heading",
      icon: "hero-document-arrow-up"
    },
    %{
      id: :suggestions,
      slug: "vorschlaege",
      label: "Angaben prüfen",
      heading_id: "ticket-suggestions-heading",
      icon: "hero-sparkles"
    },
    %{
      id: :claim,
      slug: "falldaten",
      label: "Reiseverlauf",
      heading_id: "claim-data-heading",
      icon: "hero-clipboard-document-list"
    },
    %{
      id: :planned,
      slug: "geplante-reise",
      label: "Geplante Reise",
      heading_id: "planned-journey-heading",
      icon: "hero-map"
    },
    %{
      id: :actual,
      slug: "tatsaechliche-reise",
      label: "Tatsächliche Reise",
      heading_id: "actual-journey-heading",
      icon: "hero-clock"
    },
    %{
      id: :review,
      slug: "pruefung",
      label: "Prüfung & PDF",
      heading_id: "claim-review-heading",
      icon: "hero-document-check"
    }
  ]

  @impl true
  def mount(%{"id" => claim_id}, _session, socket) do
    case ClaimWorkspace.load(socket.assigns.current_scope, claim_id) do
      {:ok, workspace} ->
        claim = workspace.claim
        max_file_size = documents_config(:max_file_size_bytes)

        socket =
          socket
          |> assign(:page_title, "Antrag #{claim.claim_number}")
          |> assign(:save_state, :saved)
          |> assign(:connection_search_state, :idle)
          |> assign(:candidate_lookup, %{})
          |> assign(:export_state, :idle)
          |> assign(:station_search_token, nil)
          |> assign(:connection_search_token, nil)
          |> assign(:analysis_tokens, %{})
          |> assign(:origin_station_options, [])
          |> assign(:destination_station_options, [])
          |> assign(:upload_form, upload_form())
          |> assign(:max_file_size_label, format_bytes(max_file_size))
          |> stream(:connection_candidates, [])
          |> allow_upload(:documents,
            accept: ~w(.pdf),
            max_entries: 2,
            max_file_size: max_file_size,
            auto_upload: true,
            progress: &handle_progress/3
          )
          |> assign_workspace(workspace)

        {:ok, socket}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Dieser Antrag wurde nicht gefunden.")
         |> redirect(to: ~p"/antraege")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    requested_step = step_by_slug(params["step"])
    step = requested_step || resume_step(socket.assigns.steps, socket.assigns.required_inputs)
    index = step_index(step)
    previous_step = if(index > 0, do: Enum.at(@steps, index - 1), else: nil)
    next_step = Enum.at(@steps, index + 1)
    step_changed? = socket.assigns[:active_step] not in [nil, step.id]

    socket =
      socket
      |> assign(:active_step, step.id)
      |> assign(:active_step_number, index + 1)
      |> assign(:previous_step, previous_step)
      |> assign(:next_step, next_step)

    socket =
      if connected?(socket) && step_changed? do
        push_event(socket, "focus-claim-step", %{id: step.heading_id})
      else
        socket
      end

    if connected?(socket) && is_binary(params["step"]) && is_nil(requested_step) do
      {:noreply, push_patch(socket, to: step_path(socket.assigns.claim, step))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("claim_autosave", %{"claim" => params}, socket) do
    {:noreply, persist_claim(socket, params, false)}
  end

  def handle_event("claim_save", %{"claim" => params}, socket) do
    {:noreply, persist_claim(socket, params, true)}
  end

  def handle_event("payout_validate", %{"profile" => params}, socket) do
    changeset =
      socket.assigns.current_scope
      |> Accounts.change_profile(payout_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :payout_form, to_form(changeset, as: :profile))}
  end

  def handle_event("payout_save", %{"profile" => params}, socket) do
    case Accounts.update_profile(socket.assigns.current_scope, payout_params(params)) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> refresh_workspace()
         |> put_flash(:info, "Deine Auszahlungsdaten wurden gespeichert.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :payout_form, to_form(changeset, as: :profile))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Die Angaben konnten nicht gespeichert werden.")}
    end
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :documents, ref)}
  end

  def handle_event("suggest_stations", %{"connection_search" => params}, socket) do
    token = async_token()
    scope = socket.assigns.current_scope
    claim_id = socket.assigns.claim.id

    socket =
      socket
      |> assign(:connection_search_form, to_form(params, as: :connection_search))
      |> assign(:station_search_token, token)

    socket =
      start_async(socket, {:station_options, token}, fn ->
        ClaimWorkspace.station_options(scope, claim_id, params)
      end)

    {:noreply, socket}
  end

  def handle_event("save_suggestion_corrections", %{"correction" => params}, socket) do
    attrs = Map.take(params, ["travel_date", "origin", "destination"])
    socket = persist_claim(socket, attrs, false)

    socket =
      if socket.assigns.save_state == :saved do
        put_flash(socket, :info, "Die manuell geprüften Angaben wurden gespeichert.")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("search_connections", %{"connection_search" => params}, socket) do
    token = async_token()
    scope = socket.assigns.current_scope
    claim = socket.assigns.claim

    socket =
      socket
      |> assign(:connection_search_form, to_form(params, as: :connection_search))
      |> assign(:connection_search_token, token)
      |> assign(:candidate_lookup, %{})
      |> assign(:connection_search_state, :loading)
      |> stream(:connection_candidates, [], reset: true)

    socket =
      start_async(socket, {:connection_search, token}, fn ->
        ClaimWorkspace.search_connections(scope, claim, params)
      end)

    {:noreply, socket}
  end

  def handle_event("choose_connection", %{"index" => index}, socket) do
    with candidate when not is_nil(candidate) <- Map.get(socket.assigns.candidate_lookup, index),
         {:ok, %{claim: claim}} <-
           ClaimWorkspace.confirm_connection(
             socket.assigns.current_scope,
             socket.assigns.claim,
             candidate
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
    with {:ok, %{claim: claim}} <-
           ClaimWorkspace.confirm_planned_journey(
             socket.assigns.current_scope,
             socket.assigns.claim,
             params
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
      when type in ["delay", "cancellation", "missed_connection"] do
    {:noreply, persist_claim(socket, %{"disruption_cause" => type}, false)}
  end

  def handle_event("save_actual_journey", %{"actual" => params}, socket) do
    with {:ok, %{claim: claim}} <-
           ClaimWorkspace.confirm_actual_journey(
             socket.assigns.current_scope,
             socket.assigns.claim,
             socket.assigns.planned_journey,
             params
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
    scope = socket.assigns.current_scope
    claim = socket.assigns.claim

    socket =
      socket
      |> assign(:export_state, :generating)
      |> start_async(:generate_export, fn ->
        Exports.generate_export(
          scope,
          claim.id,
          claim.lock_version
        )
      end)

    {:noreply, socket}
  end

  def handle_event("reanalyze_document", %{"id" => document_id}, socket) do
    with {:ok, document} <- current_claim_document(socket, document_id) do
      {:noreply,
       socket
       |> start_document_analysis(document)
       |> put_flash(:info, "Die erneute Auswertung wurde gestartet.")}
    else
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Die Auswertung konnte nicht gestartet werden.")}
    end
  end

  def handle_event("delete_document", %{"id" => document_id}, socket) do
    with {:ok, _document} <- current_claim_document(socket, document_id),
         {:ok, _claim_or_deleted} <-
           Documents.delete_document(
             socket.assigns.current_scope,
             socket.assigns.claim.id,
             document_id,
             socket.assigns.claim.lock_version
           ) do
      {:noreply,
       socket
       |> refresh_workspace()
       |> put_flash(:info, "Das Dokument wurde sicher gelöscht.")}
    else
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

  def handle_event("set_suggestion_group_state", %{"topic" => topic, "state" => state}, socket)
      when topic in ["route", "booking", "other"] and state in ["accepted", "rejected"] do
    suggestions = proposed_suggestions(socket, String.to_existing_atom(topic))

    result =
      case state do
        "accepted" -> accept_suggestion_group(socket, suggestions)
        "rejected" -> reject_suggestion_group(socket, suggestions)
      end

    {:noreply, result}
  end

  def handle_event("set_all_suggestions_state", %{"state" => state}, socket)
      when state in ["accepted", "rejected"] do
    suggestions = proposed_suggestions(socket, :all)

    result =
      case state do
        "accepted" -> accept_suggestion_group(socket, suggestions)
        "rejected" -> reject_suggestion_group(socket, suggestions)
      end

    {:noreply, result}
  end

  def handle_event("transition_claim", %{"status" => status}, socket) do
    with {:ok, target_status} <- ClaimWorkspace.transition_status(status),
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
  def handle_async({:station_options, token}, result, socket) do
    socket =
      case {token == socket.assigns.station_search_token, result} do
        {false, _result} ->
          socket

        {true, {:ok, {origin_options, destination_options}}} ->
          socket
          |> assign(:origin_station_options, origin_options)
          |> assign(:destination_station_options, destination_options)
          |> assign(:station_search_token, nil)

        {true, _failure} ->
          socket
          |> assign(:origin_station_options, [])
          |> assign(:destination_station_options, [])
          |> assign(:station_search_token, nil)
      end

    {:noreply, socket}
  end

  def handle_async({:connection_search, token}, result, socket) do
    socket =
      case {token == socket.assigns.connection_search_token, result} do
        {false, _result} ->
          socket

        {true, {:ok, {:ok, candidates}}} ->
          assign_connection_candidates(socket, candidates)

        {true, failure} ->
          reason = async_failure_reason(failure)

          socket
          |> assign(:candidate_lookup, %{})
          |> assign(:connection_search_token, nil)
          |> assign(:connection_search_state, {:error, reason})
          |> stream(:connection_candidates, [], reset: true)
      end

    {:noreply, socket}
  end

  def handle_async({:auto_connection_search, token, query}, result, socket) do
    socket =
      case {token == socket.assigns.connection_search_token, result} do
        {false, _result} ->
          socket

        {true, {:ok, {:ok, [single_candidate]}}} ->
          confirm_auto_candidate(socket, single_candidate, query)

        {true, {:ok, {:ok, candidates}}} ->
          socket
          |> assign(:connection_search_form, to_form(query, as: :connection_search))
          |> assign_connection_candidates(candidates)

        {true, _failure} ->
          assign(socket, :connection_search_token, nil)
      end

    {:noreply, socket}
  end

  def handle_async(:generate_export, result, socket) do
    socket =
      case result do
        {:ok, {:ok, %{claim: claim}}} ->
          socket
          |> assign(:export_state, :idle)
          |> load_workspace(claim)
          |> put_flash(:info, "Das druckfertige Gesamt-PDF wurde erstellt.")

        {:ok, {:error, :stale}} ->
          handle_stale(socket)

        failure ->
          reason = async_failure_reason(failure)

          socket
          |> assign(:export_state, :idle)
          |> put_flash(:error, export_error_message(reason))
      end

    {:noreply, socket}
  end

  def handle_async({:analyze_document, document_id, token}, result, socket) do
    if Map.get(socket.assigns.analysis_tokens, document_id) != token do
      {:noreply, socket}
    else
      socket =
        assign(
          socket,
          :analysis_tokens,
          Map.delete(socket.assigns.analysis_tokens, document_id)
        )

      socket =
        case result do
          {:ok, {:ok, _analysis}} ->
            socket
            |> refresh_workspace()
            |> put_flash(:info, "Das Dokument wurde ausgewertet.")

          {:ok, {:error, :stale}} ->
            handle_stale(socket)

          {:ok, {:error, :not_editable}} ->
            put_flash(
              socket,
              :error,
              "Dieser Antrag muss vor Änderungen erneut geöffnet werden."
            )

          _failure ->
            put_flash(socket, :error, "Das Dokument konnte nicht ausgewertet werden.")
        end

      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_section={:claims}>
      <div
        id="claim-workspace"
        phx-hook=".ClaimStepFocus"
        class={["space-y-7 pb-28 lg:pb-14"]}
      >
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
                <span class={["text-slate-300"]}>Status</span>
                <span id="workspace-progress-label">
                  {workspace_progress_label(@required_inputs)}
                </span>
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

        <nav
          id="claim-stepper"
          aria-label="Schritte des Antragsassistenten"
          class={["rounded-3xl border border-slate-200 bg-white p-3 shadow-sm"]}
        >
          <ol class={["grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-6"]}>
            <li :for={{step, step_number} <- Enum.with_index(@steps, 1)}>
              <.link
                id={"claim-step-#{step.slug}"}
                patch={step_path(@claim, step)}
                aria-current={if(@active_step == step.id, do: "step", else: nil)}
                data-state={step.state}
                class={[
                  "group flex min-h-20 items-center gap-3 rounded-2xl px-3 py-3 text-left transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700",
                  if(@active_step == step.id,
                    do: "bg-slate-950 text-white shadow-sm",
                    else: "text-slate-600 hover:bg-slate-50 hover:text-slate-950"
                  )
                ]}
              >
                <span class={[
                  "flex size-8 shrink-0 items-center justify-center rounded-xl text-xs font-bold",
                  if(@active_step == step.id,
                    do: "bg-white/15 text-white",
                    else: "bg-slate-100 text-slate-600 group-hover:bg-white"
                  )
                ]}>
                  {step_number}
                </span>
                <span class="min-w-0">
                  <span class="block truncate text-xs font-bold">{step.label}</span>
                  <span class={[
                    "mt-1 flex items-center gap-1 text-[0.68rem] font-semibold",
                    if(@active_step == step.id, do: "text-slate-300", else: "text-slate-500")
                  ]}>
                    <.icon name={step_badge_icon(step.state)} class="size-3.5" />
                    {step_badge_label(step.state)}
                  </span>
                </span>
              </.link>
            </li>
          </ol>
        </nav>

        <div class={["grid gap-7 xl:grid-cols-[minmax(0,1.45fr)_minmax(20rem,0.75fr)]"]}>
          <div class={["space-y-7"]}>
            <Components.claim_data
              active_step={@active_step}
              claim={@claim}
              claim_form={@claim_form}
              save_state={@save_state}
              step_number={step_number(:claim)}
              step_states={@step_states}
            />

            <Components.documents
              active_step={@active_step}
              documents_by_kind={@documents_by_kind}
              max_file_size_label={@max_file_size_label}
              step_number={step_number(:documents)}
              step_states={@step_states}
              upload_form={@upload_form}
              upload_kinds={@upload_kinds}
              upload={@uploads.documents}
            />

            <Components.trip_summary
              active_step={@active_step}
              claim={@claim}
              planned_journey={@planned_journey}
              actual_journey={@actual_journey}
              proposed_suggestions?={@proposed_suggestions?}
              suggestions_by_id={@suggestions_by_id}
              step_paths={@step_paths}
              order_number_mismatch={@order_number_mismatch}
            />

            <Components.suggestions
              active_step={@active_step}
              claim={@claim}
              documents_by_id={@documents_by_id}
              proposed_suggestions?={@proposed_suggestions?}
              step_number={step_number(:suggestions)}
              step_states={@step_states}
              streams={@streams}
              suggestion_correction_form={@suggestion_correction_form}
              suggestions_empty?={@suggestions_empty?}
            />

            <Components.planned_journey
              active_step={@active_step}
              claim={@claim}
              connection_search_form={@connection_search_form}
              connection_search_state={@connection_search_state}
              destination_station_options={@destination_station_options}
              origin_station_options={@origin_station_options}
              planned_complete?={@planned_complete?}
              planned_form={@planned_form}
              planned_state={@planned_state}
              step_number={step_number(:planned)}
              streams={@streams}
            />

            <Components.actual_journey
              active_step={@active_step}
              actual_form={@actual_form}
              actual_journey={@actual_journey}
              actual_state={@actual_state}
              claim={@claim}
              step_number={step_number(:actual)}
              streams={@streams}
            />

            <Components.review
              active_step={@active_step}
              actual_complete?={@actual_complete?}
              claim={@claim}
              claim_complete?={@claim_complete?}
              current_export={@current_export}
              documents_complete?={@documents_complete?}
              export_state_label={@export_state_label}
              exports_available?={@exports_available?}
              latest_export_version={@latest_export_version}
              planned_complete?={@planned_complete?}
              payout_form={@payout_form}
              profile_complete?={@profile_complete?}
              profile_error={@profile_error}
              review_complete?={@review_complete?}
              step_number={step_number(:review)}
              step_paths={@step_paths}
              streams={@streams}
              suggestions_complete?={@suggestions_complete?}
            />
          </div>

          <aside class={["space-y-5"]}>
            <details
              id="claim-more-options"
              class={["group rounded-3xl border border-slate-200 bg-white shadow-sm"]}
            >
              <summary class={[
                "flex cursor-pointer list-none items-center justify-between gap-3 rounded-3xl px-6 py-5 text-sm font-semibold text-slate-950 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700"
              ]}>
                Weitere Optionen
                <.icon name="hero-chevron-down" class="size-4 transition group-open:rotate-180" />
              </summary>

              <div class={["space-y-5 px-6 pb-6"]}>
                <section id="claim-status-actions">
                  <h2 class={["text-sm font-semibold text-slate-950"]}>Status</h2>
                  <p class={["mt-2 text-xs leading-5 text-slate-500"]}>
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

                  <dl
                    :if={@claim.sent_at || @claim.completed_at}
                    class="mt-5 grid gap-2 rounded-xl bg-slate-50 p-3 text-xs"
                  >
                    <div :if={@claim.sent_at} class="flex items-center justify-between gap-3">
                      <dt class="font-semibold text-slate-500">Versendet</dt>
                      <dd class="font-semibold text-slate-800">{format_datetime(@claim.sent_at)}</dd>
                    </div>
                    <div :if={@claim.completed_at} class="flex items-center justify-between gap-3">
                      <dt class="font-semibold text-slate-500">Abgeschlossen</dt>
                      <dd class="font-semibold text-slate-800">
                        {format_datetime(@claim.completed_at)}
                      </dd>
                    </div>
                  </dl>

                  <div id="claim-status-history" phx-update="stream" class="mt-5 space-y-2">
                    <p
                      id="claim-status-history-heading"
                      class="text-xs font-semibold uppercase tracking-wide text-slate-500"
                    >
                      Verlauf
                    </p>
                    <article
                      :for={{dom_id, entry} <- @streams.status_history}
                      id={dom_id}
                      class="rounded-xl border border-slate-200 px-3 py-2.5"
                    >
                      <p class="text-xs font-semibold text-slate-800">
                        {status_history_label(entry)}
                      </p>
                      <p class="mt-1 text-[0.68rem] text-slate-500">
                        {format_datetime(entry.changed_at)}
                      </p>
                    </article>
                  </div>
                </section>

                <section class={["rounded-2xl border border-rose-200 bg-rose-50/60 p-5"]}>
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
              </div>
            </details>
          </aside>
        </div>

        <nav
          id="claim-step-mobile-navigation"
          aria-label="Navigation zwischen den Antragsschritten"
          class={[
            "fixed inset-x-4 bottom-24 z-30 grid grid-cols-[1fr_auto_1fr] items-center gap-2 rounded-2xl border border-slate-200 bg-white/95 p-2 shadow-[0_18px_50px_-20px_rgba(15,23,42,0.5)] backdrop-blur-xl md:hidden"
          ]}
        >
          <%= if @previous_step do %>
            <.link
              id="claim-step-back"
              patch={step_path(@claim, @previous_step)}
              class="inline-flex min-h-11 items-center justify-start gap-2 rounded-xl px-3 text-sm font-semibold text-slate-700 transition hover:bg-slate-100 focus-visible:outline focus-visible:outline-2 focus-visible:outline-rose-700"
            >
              <.icon name="hero-arrow-left" class="size-4" /> Zurück
            </.link>
          <% else %>
            <.link
              id="claim-step-back"
              navigate={~p"/antraege"}
              class="inline-flex min-h-11 items-center justify-start gap-2 rounded-xl px-3 text-sm font-semibold text-slate-700 transition hover:bg-slate-100 focus-visible:outline focus-visible:outline-2 focus-visible:outline-rose-700"
            >
              <.icon name="hero-arrow-left" class="size-4" /> Anträge
            </.link>
          <% end %>

          <span class="whitespace-nowrap px-2 text-xs font-bold text-slate-500">
            {@active_step_number} / {length(@steps)}
          </span>

          <%= if @next_step do %>
            <.link
              id="claim-step-forward"
              patch={step_path(@claim, @next_step)}
              class="inline-flex min-h-11 items-center justify-end gap-2 rounded-xl bg-slate-950 px-3 text-sm font-semibold text-white transition hover:bg-rose-700 focus-visible:outline focus-visible:outline-2 focus-visible:outline-rose-700"
            >
              Weiter <.icon name="hero-arrow-right" class="size-4" />
            </.link>
          <% else %>
            <span
              id="claim-step-forward"
              aria-disabled="true"
              class="inline-flex min-h-11 items-center justify-end gap-2 rounded-xl bg-emerald-700 px-3 text-sm font-semibold text-white"
            >
              Fertig <.icon name="hero-check" class="size-4" />
            </span>
          <% end %>
        </nav>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".ClaimStepFocus">
          export default {
            mounted() {
              this.handleEvent("focus-claim-step", ({id}) => {
                window.requestAnimationFrame(() => {
                  const heading = document.getElementById(id)
                  if (!heading) return

                  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches
                  heading.focus({preventScroll: true})
                  heading.scrollIntoView({behavior: reducedMotion ? "auto" : "smooth", block: "start"})
                })
              })
            }
          }
        </script>
      </div>
    </Layouts.app>
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
              </div>
              <p class="mt-2 text-sm font-semibold text-slate-950">{suggestion_value(suggestion)}</p>
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
  attr :href, :string, required: true
  attr :navigate, :boolean, default: false

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
      <.link
        :if={!@done? && !@navigate}
        patch={@href}
        class="ml-auto rounded-lg px-2 py-1 text-xs font-bold text-amber-900 underline decoration-amber-400 underline-offset-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-amber-700"
      >
        Öffnen
      </.link>
      <.link
        :if={!@done? && @navigate}
        navigate={@href}
        class="ml-auto rounded-lg px-2 py-1 text-xs font-bold text-amber-900 underline decoration-amber-400 underline-offset-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-amber-700"
      >
        Öffnen
      </.link>
    </div>
    """
  end

  defp persist_claim(socket, params, show_flash?) do
    params = normalize_claim_dates(params)

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
          do: put_flash(socket, :info, "Dein Reiseverlauf wurde gespeichert."),
          else: socket

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> assign(:save_state, :invalid)
        |> assign(:claim_form, to_form(%{changeset | action: :validate}))

      {:error, :stale} ->
        handle_stale(socket)

      {:error, :not_editable} ->
        socket
        |> assign(:save_state, :error)
        |> put_flash(:error, "Dieser Antrag muss vor Änderungen erneut geöffnet werden.")

      {:error, _reason} ->
        socket
        |> assign(:save_state, :error)
        |> put_flash(:error, "Dein Reiseverlauf konnte nicht gespeichert werden.")
    end
  end

  defp handle_progress(:documents, entry, socket) when entry.done? do
    documents_by_kind = socket.assigns.documents_by_kind

    tagged_result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {kind, ambiguous?} = resolve_document_kind(path, documents_by_kind)

        result =
          Documents.put_document(
            socket.assigns.current_scope,
            socket.assigns.claim.id,
            kind,
            %{
              path: path,
              original_filename: entry.client_name,
              content_type: entry.client_type
            },
            socket.assigns.claim.lock_version
          )

        {:ok, {result, ambiguous?}}
      end)

    {:noreply, handle_upload_result(socket, [tagged_result])}
  end

  defp handle_progress(:documents, _entry, socket), do: {:noreply, socket}

  defp resolve_document_kind(path, documents_by_kind) do
    case Tickets.classify_upload(path) do
      {:ok, kind, _confidence} -> {kind, false}
      {:error, :ambiguous} -> {fallback_document_kind(documents_by_kind), true}
    end
  end

  defp fallback_document_kind(documents_by_kind) do
    Enum.find(@upload_kinds, :ticket, &(!Map.has_key?(documents_by_kind, &1)))
  end

  defp start_document_analysis(socket, document) do
    token = async_token()
    scope = socket.assigns.current_scope
    claim_id = socket.assigns.claim.id
    lock_version = socket.assigns.claim.lock_version

    socket
    |> assign(
      :analysis_tokens,
      Map.put(socket.assigns.analysis_tokens, document.id, token)
    )
    |> start_async({:analyze_document, document.id, token}, fn ->
      Tickets.analyze_document(scope, claim_id, document.id, lock_version)
    end)
  end

  defp handle_upload_result(socket, [{{:ok, %{document: document, claim: claim}}, ambiguous?}]) do
    message =
      if ambiguous? do
        "Wir konnten die Art des Dokuments nicht sicher erkennen und haben es vorläufig als " <>
          document_kind_label(document.kind) <>
          " gespeichert. Bitte löschen und neu hochladen, falls das nicht stimmt."
      else
        "Das Dokument wurde sicher gespeichert. Die Auswertung läuft."
      end

    socket
    |> load_workspace(claim)
    |> start_document_analysis(document)
    |> put_flash(:info, message)
  end

  defp handle_upload_result(socket, [{{:error, reason}, _ambiguous?}]) do
    put_flash(socket, :error, document_error_message(reason))
  end

  defp handle_upload_result(socket, _results) do
    put_flash(socket, :error, "Bitte wähle zuerst eine vollständige PDF-Datei aus.")
  end

  defp accept_suggestion_group(socket, []),
    do: put_flash(socket, :info, "In diesem Bereich sind keine offenen Vorschläge vorhanden.")

  defp accept_suggestion_group(socket, suggestions) do
    with {:ok, %{claim: claim}} <-
           ClaimWorkspace.accept_suggestions(
             socket.assigns.current_scope,
             socket.assigns.claim,
             suggestions
           ) do
      socket
      |> load_workspace(claim)
      |> maybe_auto_search_connections()
      |> maybe_advance_to_next_question()
      |> put_flash(:info, "Die erkannten Angaben wurden gemeinsam übernommen.")
    else
      {:error, :stale} ->
        handle_stale(socket)

      {:error, :not_editable} ->
        put_flash(socket, :error, "Dieser Antrag muss vor Änderungen erneut geöffnet werden.")

      {:error, _reason} ->
        put_flash(socket, :error, "Die Vorschläge konnten nicht übernommen werden.")
    end
  end

  defp maybe_auto_search_connections(socket) do
    claim = socket.assigns.claim

    with nil <- socket.assigns.planned_journey,
         true <- editable?(claim.status),
         query when not is_nil(query) <-
           ClaimWorkspace.automatic_connection_query(claim, socket.assigns.suggestions_by_id) do
      token = async_token()
      scope = socket.assigns.current_scope

      socket
      |> assign(:connection_search_token, token)
      |> assign(:connection_search_state, :loading)
      |> start_async({:auto_connection_search, token, query}, fn ->
        ClaimWorkspace.search_connections(scope, claim, query)
      end)
    else
      _skip -> socket
    end
  end

  defp maybe_advance_to_next_question(socket) do
    current_step_id = socket.assigns.active_step
    required_inputs = socket.assigns.required_inputs

    with false <- Enum.any?(required_inputs, &(&1.step == current_step_id)),
         [%{step: next_step_id} | _] <- required_inputs,
         next_step when not is_nil(next_step) <-
           Enum.find(socket.assigns.steps, &(&1.id == next_step_id)) do
      push_patch(socket, to: step_path(socket.assigns.claim, next_step))
    else
      _no_advance -> socket
    end
  end

  defp confirm_auto_candidate(socket, candidate, query) do
    case ClaimWorkspace.confirm_connection(
           socket.assigns.current_scope,
           socket.assigns.claim,
           candidate
         ) do
      {:ok, %{claim: claim}} ->
        socket
        |> load_workspace(claim)
        |> assign(:connection_search_token, nil)
        |> assign(:connection_search_state, :idle)
        |> maybe_advance_to_next_question()
        |> put_flash(
          :info,
          "Wir haben die passende Verbindung samt aktueller Verspätung automatisch übernommen."
        )

      {:error, :stale} ->
        handle_stale(socket)

      {:error, _reason} ->
        socket
        |> assign(:connection_search_form, to_form(query, as: :connection_search))
        |> assign_connection_candidates([candidate])
    end
  end

  defp assign_connection_candidates(socket, candidates) do
    indexed = Enum.with_index(candidates, 1)

    lookup =
      Map.new(indexed, fn {candidate, index} -> {Integer.to_string(index), candidate} end)

    items =
      Enum.map(indexed, fn {candidate, index} -> %{id: index, candidate: candidate} end)

    socket
    |> assign(:candidate_lookup, lookup)
    |> assign(:connection_search_token, nil)
    |> assign(:connection_search_state, if(candidates == [], do: :empty, else: :results))
    |> stream(:connection_candidates, items, reset: true)
  end

  defp reject_suggestion_group(socket, []),
    do: put_flash(socket, :info, "In diesem Bereich sind keine offenen Vorschläge vorhanden.")

  defp reject_suggestion_group(socket, suggestions) do
    case ClaimWorkspace.reject_suggestions(
           socket.assigns.current_scope,
           socket.assigns.claim,
           suggestions
         ) do
      {:ok, _result} ->
        socket
        |> refresh_workspace()
        |> put_flash(:info, "Die erkannten Angaben wurden gemeinsam verworfen.")

      {:error, :stale} ->
        handle_stale(socket)

      {:error, :not_editable} ->
        put_flash(socket, :error, "Dieser Antrag muss vor Änderungen erneut geöffnet werden.")

      {:error, _reason} ->
        put_flash(socket, :error, "Die Vorschläge konnten nicht aktualisiert werden.")
    end
  end

  defp proposed_suggestions(socket, topic) do
    ClaimWorkspace.proposed_suggestions(socket.assigns.suggestions_by_id, topic)
  end

  defp accept_suggestion(socket, suggestion_id) do
    with suggestion when not is_nil(suggestion) <- find_suggestion(socket, suggestion_id),
         {:ok, %{claim: claim}} <-
           ClaimWorkspace.accept_suggestions(
             socket.assigns.current_scope,
             socket.assigns.claim,
             [suggestion]
           ) do
      socket
      |> load_workspace(claim)
      |> put_flash(:info, suggestion_accept_message(suggestion.field))
    else
      nil ->
        put_flash(socket, :error, "Der Vorschlag wurde nicht gefunden.")

      {:error, :stale} ->
        handle_stale(socket)

      {:error, :not_editable} ->
        put_flash(socket, :error, "Dieser Antrag muss vor Änderungen erneut geöffnet werden.")

      {:error, _reason} ->
        put_flash(socket, :error, "Der Vorschlag konnte nicht übernommen werden.")
    end
  end

  defp update_suggestion_state(socket, suggestion_id, _state) do
    with suggestion when not is_nil(suggestion) <- find_suggestion(socket, suggestion_id),
         {:ok, _result} <-
           ClaimWorkspace.reject_suggestions(
             socket.assigns.current_scope,
             socket.assigns.claim,
             [suggestion]
           ) do
      socket
      |> refresh_workspace()
      |> put_flash(:info, "Der Vorschlag wurde verworfen.")
    else
      nil ->
        put_flash(socket, :error, "Der Vorschlag wurde nicht gefunden.")

      {:error, :stale} ->
        handle_stale(socket)

      {:error, :not_editable} ->
        put_flash(socket, :error, "Dieser Antrag muss vor Änderungen erneut geöffnet werden.")

      {:error, _reason} ->
        put_flash(socket, :error, "Der Vorschlag konnte nicht aktualisiert werden.")
    end
  end

  defp current_claim_document(socket, document_id) do
    with document when not is_nil(document) <-
           Map.get(socket.assigns.documents_by_id, document_id),
         true <-
           document.claim_id == socket.assigns.claim.id and document.kind in @upload_kinds do
      {:ok, document}
    else
      _error -> {:error, :not_found}
    end
  end

  defp find_suggestion(socket, suggestion_id) do
    Map.get(socket.assigns.suggestions_by_id, suggestion_id)
  end

  defp load_workspace(socket, claim) do
    case ClaimWorkspace.load(socket.assigns.current_scope, claim.id) do
      {:ok, workspace} ->
        assign_workspace(socket, workspace)

      {:error, _reason} ->
        put_flash(socket, :error, "Der Arbeitsbereich konnte nicht vollständig geladen werden.")
    end
  end

  defp assign_workspace(socket, workspace) do
    route_suggestions = workspace.suggestion_groups.route
    booking_suggestions = workspace.suggestion_groups.booking
    other_suggestions = workspace.suggestion_groups.other
    suggestions = Map.values(workspace.suggestions_by_id)
    exports = workspace_entries(workspace, :exports)
    api_sources = workspace_entries(workspace, :api_sources)
    status_history = workspace_entries(workspace, :status_history)

    steps =
      Enum.map(
        @steps,
        &Map.put(&1, :state, Map.fetch!(workspace.step_states, &1.id))
      )

    completed_steps = Enum.count(steps, &(&1.state == :confirmed))
    step_paths = Map.new(steps, &{&1.id, step_path(workspace.claim, &1)})
    required_inputs = ClaimWorkspace.required_inputs(workspace)
    payout_form = payout_form(socket.assigns.current_scope, workspace)
    order_number_mismatch = ClaimWorkspace.order_number_mismatch(workspace)

    socket
    |> assign(:claim, workspace.claim)
    |> assign(:claim_form, to_form(workspace.claim_changeset))
    |> assign(:documents_by_kind, workspace.documents_by_kind)
    |> assign(:documents_by_id, workspace.documents_by_id)
    |> assign(:suggestions_by_id, workspace.suggestions_by_id)
    |> assign(:suggestions_empty?, suggestions == [])
    |> assign(:proposed_suggestions?, Enum.any?(suggestions, &(&1.state == :proposed)))
    |> assign(
      :suggestion_correction_form,
      to_form(workspace.suggestion_correction_data, as: :correction)
    )
    |> assign(:upload_kinds, @upload_kinds)
    |> assign(:claim_complete?, workspace.claim_complete?)
    |> assign(:documents_complete?, workspace.documents_complete?)
    |> assign(:profile_complete?, workspace.profile_complete?)
    |> assign(:profile_error, workspace.profile_error)
    |> assign(:planned_journey, workspace.planned_journey)
    |> assign(:actual_journey, workspace.actual_journey)
    |> assign(:suggestions_complete?, workspace.suggestions_complete?)
    |> assign(:planned_complete?, workspace.planned_complete?)
    |> assign(:actual_complete?, workspace.actual_complete?)
    |> assign(:review_complete?, workspace.review_complete?)
    |> assign(:workspace_readiness, workspace.readiness)
    |> assign(:exports_available?, workspace.exports_available?)
    |> assign(:current_export, workspace.current_export)
    |> assign(:latest_export_version, latest_export_version(workspace.exports))
    |> assign(:step_states, workspace.step_states)
    |> assign(:steps, steps)
    |> assign(:step_paths, step_paths)
    |> assign(:planned_state, workspace.step_states.planned)
    |> assign(:actual_state, workspace.step_states.actual)
    |> assign(:export_state_label, workspace.step_states.review)
    |> assign(:planned_form, to_form(workspace.planned_form_data, as: :planned))
    |> assign(:actual_form, to_form(workspace.actual_form_data, as: :actual))
    |> assign(
      :connection_search_form,
      to_form(workspace.connection_search_data, as: :connection_search)
    )
    |> assign(:completed_steps, completed_steps)
    |> assign(:required_inputs, required_inputs)
    |> assign(:payout_form, payout_form)
    |> assign(:order_number_mismatch, order_number_mismatch)
    |> stream(:route_suggestions, route_suggestions, reset: true)
    |> stream(:booking_suggestions, booking_suggestions, reset: true)
    |> stream(:other_suggestions, other_suggestions, reset: true)
    |> stream(
      :actual_segments,
      if(workspace.actual_journey, do: workspace.actual_journey.segments, else: []),
      reset: true
    )
    |> stream(:exports, exports, reset: true)
    |> stream(:api_sources, api_sources, reset: true)
    |> stream(:status_history, status_history, reset: true)
  end

  defp workspace_entries(workspace, key) do
    case Map.get(workspace, key) do
      entries when is_list(entries) -> Enum.reverse(entries)
      _other -> []
    end
  end

  defp latest_export_version([]), do: nil
  defp latest_export_version(exports), do: List.last(exports).version

  defp payout_form(_scope, %{profile_complete?: true}), do: nil
  defp payout_form(_scope, %{profile_error: reason}) when not is_nil(reason), do: nil

  defp payout_form(scope, _workspace) do
    case Accounts.get_profile(scope) do
      {:ok, profile} ->
        to_form(Accounts.change_profile(profile, payout_default_attrs(profile)), as: :profile)

      {:error, _reason} ->
        nil
    end
  end

  defp payout_default_attrs(%{country: country}) when country in [nil, ""],
    do: %{"country" => "Deutschland"}

  defp payout_default_attrs(_profile), do: %{}

  defp payout_params(params) do
    params
    |> put_derived_account_holder()
    |> put_derived_bic()
  end

  defp put_derived_account_holder(params) do
    case Map.get(params, "account_holder") do
      value when value in [nil, ""] ->
        name =
          [Map.get(params, "first_name"), Map.get(params, "last_name")]
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.join(" ")

        if name == "", do: params, else: Map.put(params, "account_holder", name)

      _value ->
        params
    end
  end

  defp put_derived_bic(params) do
    with value when value in [nil, ""] <- Map.get(params, "bic"),
         {:ok, bic} <- BicLookup.derive(Map.get(params, "iban")) do
      Map.put(params, "bic", bic)
    else
      _keep -> params
    end
  end

  defp normalize_claim_dates(%{"travel_date" => value} = params) do
    case GermanDateTime.parse_date(value) do
      {:ok, date} -> Map.put(params, "travel_date", Date.to_iso8601(date))
      :error -> params
    end
  end

  defp normalize_claim_dates(params), do: params

  defp refresh_workspace(socket) do
    load_workspace(socket, socket.assigns.claim)
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

  defp upload_form, do: to_form(%{}, as: :document)

  defp step_by_slug(nil), do: nil

  defp step_by_slug(slug) when is_binary(slug),
    do: Enum.find(@steps, &(&1.slug == slug))

  defp resume_step(steps, [%{step: step_id} | _rest]),
    do: Enum.find(steps, &(&1.id == step_id)) || List.last(steps)

  defp resume_step(steps, []), do: List.last(steps)

  defp step_index(step),
    do: Enum.find_index(@steps, &(&1.id == step.id))

  defp step_number(id),
    do: Enum.find_index(@steps, &(&1.id == id)) + 1

  defp step_path(claim, step),
    do: ~p"/antraege/#{claim.id}/#{step.slug}"

  defp async_failure_reason({:ok, {:error, reason}}), do: reason
  defp async_failure_reason({:exit, _reason}), do: :async_failed
  defp async_failure_reason(_result), do: :async_failed

  defp async_token, do: System.unique_integer([:positive, :monotonic])

  defp documents_config(key) do
    :fahrgastrechte
    |> Application.fetch_env!(Documents)
    |> Keyword.fetch!(key)
  end
end
