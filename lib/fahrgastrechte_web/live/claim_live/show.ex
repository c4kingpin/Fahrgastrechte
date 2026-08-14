defmodule FahrgastrechteWeb.ClaimLive.Show do
  use FahrgastrechteWeb, :live_view

  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.ClaimWorkspace
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Exports
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
      label: "Falldaten",
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
    step = requested_step || resume_step(socket.assigns.steps)
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

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"kind" => kind, "ref" => ref}, socket)
      when kind in ["ticket", "invoice"] do
    {:noreply, cancel_upload(socket, String.to_existing_atom(kind), ref)}
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
      when type in ["delay", "cancellation"] do
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

        <nav
          id="claim-stepper"
          aria-label="Schritte des Antragsassistenten"
          class={["overflow-x-auto rounded-3xl border border-slate-200 bg-white p-3 shadow-sm"]}
        >
          <ol class={["grid min-w-[54rem] grid-cols-6 gap-2"]}>
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
              upload_forms={@upload_forms}
              upload_kinds={@upload_kinds}
              uploads={@uploads}
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
              documents_complete?={@documents_complete?}
              export_state_label={@export_state_label}
              exports_available?={@exports_available?}
              planned_complete?={@planned_complete?}
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
            <section
              id="claim-next-steps"
              class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm"]}
            >
              <p class={["text-xs font-semibold uppercase tracking-[0.2em] text-slate-500"]}>
                Ablauf
              </p>
              <h2 class={["mt-2 text-lg font-semibold text-slate-950"]}>Dein Fortschritt</h2>
              <ol class={["mt-5 space-y-2"]}>
                <li :for={step <- @steps}>
                  <.link
                    id={"claim-progress-step-#{step.slug}"}
                    patch={step_path(@claim, step)}
                    aria-current={if(@active_step == step.id, do: "step", else: nil)}
                    data-state={step.state}
                    class={[
                      "flex items-center gap-3 rounded-xl px-3.5 py-3 transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700",
                      if(@active_step == step.id,
                        do: "bg-slate-950 text-white",
                        else: "bg-slate-50 hover:bg-slate-100"
                      )
                    ]}
                  >
                    <span class={[
                      "flex size-7 shrink-0 items-center justify-center rounded-full",
                      if(@active_step == step.id,
                        do: "bg-white/15 text-white",
                        else: step_badge_style(step.state)
                      )
                    ]}>
                      <.icon name={step_badge_icon(step.state)} class="size-4" />
                    </span>
                    <span class="min-w-0">
                      <span class="block truncate text-sm font-semibold">{step.label}</span>
                      <span class={[
                        "mt-0.5 block text-xs font-semibold",
                        if(@active_step == step.id, do: "text-slate-300", else: "text-slate-500")
                      ]}>
                        {step_badge_label(step.state)}
                      </span>
                    </span>
                  </.link>
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
                  <dd class="font-semibold text-slate-800">{format_datetime(@claim.completed_at)}</dd>
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
                  <p class="text-xs font-semibold text-slate-800">{status_history_label(entry)}</p>
                  <p class="mt-1 text-[0.68rem] text-slate-500">
                    {format_datetime(entry.changed_at)}
                  </p>
                </article>
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
        socket
        |> assign(:save_state, :error)
        |> put_flash(:error, "Dieser Antrag muss vor Änderungen erneut geöffnet werden.")

      {:error, _reason} ->
        socket
        |> assign(:save_state, :error)
        |> put_flash(:error, "Die Falldaten konnten nicht gespeichert werden.")
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

  defp start_document_analysis(socket, document) do
    token = async_token()
    scope = socket.assigns.current_scope
    claim_id = socket.assigns.claim.id

    socket
    |> assign(
      :analysis_tokens,
      Map.put(socket.assigns.analysis_tokens, document.id, token)
    )
    |> start_async({:analyze_document, document.id, token}, fn ->
      Tickets.analyze_document(scope, claim_id, document.id)
    end)
  end

  defp handle_upload_result(socket, [{:ok, %{document: document, claim: claim}}]) do
    socket
    |> load_workspace(claim)
    |> start_document_analysis(document)
    |> put_flash(:info, "Das Dokument wurde sicher gespeichert. Die Auswertung läuft.")
  end

  defp handle_upload_result(socket, [{:error, reason}]) do
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
      |> put_flash(:info, "Die erkannten Angaben wurden gemeinsam übernommen.")
    else
      {:error, :stale} ->
        handle_stale(socket)

      {:error, _reason} ->
        put_flash(socket, :error, "Die Vorschläge konnten nicht übernommen werden.")
    end
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

    steps =
      Enum.map(
        @steps,
        &Map.put(&1, :state, Map.fetch!(workspace.step_states, &1.id))
      )

    completed_steps = Enum.count(steps, &(&1.state == :confirmed))
    step_paths = Map.new(steps, &{&1.id, step_path(workspace.claim, &1)})

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
    |> stream(:route_suggestions, route_suggestions, reset: true)
    |> stream(:booking_suggestions, booking_suggestions, reset: true)
    |> stream(:other_suggestions, other_suggestions, reset: true)
    |> stream(
      :actual_segments,
      if(workspace.actual_journey, do: workspace.actual_journey.segments, else: []),
      reset: true
    )
    |> stream(:exports, Enum.reverse(workspace.exports), reset: true)
    |> stream(:api_sources, Enum.reverse(workspace.api_sources), reset: true)
    |> stream(:status_history, Enum.reverse(workspace.status_history), reset: true)
  end

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

  defp upload_forms do
    Map.new(@upload_kinds, fn kind ->
      {kind, to_form(%{"kind" => Atom.to_string(kind)}, as: :document)}
    end)
  end

  defp step_by_slug(nil), do: nil

  defp step_by_slug(slug) when is_binary(slug),
    do: Enum.find(@steps, &(&1.slug == slug))

  defp resume_step(steps),
    do: Enum.find(steps, &(&1.state != :confirmed)) || List.last(steps)

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
