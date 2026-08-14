defmodule FahrgastrechteWeb.ReferenceDataLive do
  use FahrgastrechteWeb, :live_view

  alias Fahrgastrechte.Exports.Template
  alias Fahrgastrechte.Rail.Providers.BahnVorhersageArchive
  alias Fahrgastrechte.ReferenceData

  @archive_source_url "https://bahnvorhersage.de/open-data/parsed-train-delays/"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Datenquellen")
      |> assign(:official_form_form, official_form_form())
      |> assign(:archive_form, archive_form())
      |> allow_upload(:official_form,
        accept: ~w(.pdf),
        max_entries: 1,
        max_file_size: reference_config(:max_form_size_bytes),
        auto_upload: true
      )
      |> allow_upload(:bahn_archive,
        accept: ~w(.csv),
        max_entries: 1,
        max_file_size: reference_config(:max_archive_size_bytes),
        auto_upload: true,
        chunk_timeout: 120_000
      )
      |> refresh_sources()

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_official_form", %{"official_form" => params}, socket) do
    {:noreply, assign(socket, :official_form_form, to_form(params, as: :official_form))}
  end

  def handle_event("validate_archive", %{"archive" => params}, socket) do
    {:noreply, assign(socket, :archive_form, to_form(params, as: :archive))}
  end

  def handle_event("cancel_upload", %{"upload" => upload, "ref" => ref}, socket) do
    case upload do
      "official_form" -> {:noreply, cancel_upload(socket, :official_form, ref)}
      "bahn_archive" -> {:noreply, cancel_upload(socket, :bahn_archive, ref)}
      _unknown -> {:noreply, socket}
    end
  end

  def handle_event("replace_official_form", %{"official_form" => params}, socket) do
    case consume_one(socket, :official_form, fn path, entry ->
           ReferenceData.replace_official_form(
             socket.assigns.current_scope,
             path,
             Map.put(params, "original_filename", entry.client_name)
           )
         end) do
      {:ok, version} ->
        {:noreply,
         socket
         |> put_flash(:info, "Das offizielle Formular #{version.version} ist jetzt aktiv.")
         |> assign(:official_form_form, official_form_form())
         |> refresh_sources()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, source_error_message(:official_form, reason))}
    end
  end

  def handle_event("replace_archive", %{"archive" => params}, socket) do
    case consume_one(socket, :bahn_archive, fn path, entry ->
           ReferenceData.replace_bahn_archive(
             socket.assigns.current_scope,
             path,
             Map.put(params, "original_filename", entry.client_name)
           )
         end) do
      {:ok, version} ->
        {:noreply,
         socket
         |> put_flash(:info, "Der Bahn-Vorhersage-Datensatz #{version.version} ist jetzt aktiv.")
         |> assign(:archive_form, archive_form())
         |> refresh_sources()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, source_error_message(:archive, reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_section={:sources}>
      <div id="reference-data-page" class={["space-y-8"]}>
        <section class={[
          "relative overflow-hidden rounded-3xl bg-slate-950 px-6 py-8 text-white shadow-xl sm:px-10"
        ]}>
          <div class={[
            "absolute -right-16 -top-20 size-64 rounded-full bg-rose-600/20 blur-3xl"
          ]}>
          </div>
          <div class={["relative max-w-2xl"]}>
            <p class={["text-xs font-semibold uppercase tracking-[0.24em] text-rose-300"]}>
              Betriebsdaten
            </p>
            <h1 class={["mt-3 text-3xl font-semibold tracking-tight sm:text-4xl"]}>
              Verlässliche Quellen, direkt aktualisiert
            </h1>
            <p class={["mt-3 text-sm leading-6 text-slate-300 sm:text-base"]}>
              Hier werden das offizielle Fahrgastrechteformular und die historische
              Bahn-Vorhersage-Projektion für diese Installation gepflegt. Neue Dateien
              werden geprüft, bevor sie aktive Anträge beeinflussen.
            </p>
          </div>
        </section>

        <div
          id="reference-data-global-notice"
          class={[
            "flex items-start gap-3 rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-950"
          ]}
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-amber-700" />
          <p>
            Eine Aktivierung gilt für alle künftig erzeugten Ausgaben dieser Installation.
            Bereits erzeugte PDF-Versionen bleiben unverändert.
          </p>
        </div>

        <div class={["grid gap-7 xl:grid-cols-2"]}>
          <.source_panel
            id="official-form-source"
            eyebrow="PDF-Vorlage"
            title="Offizielles Formular"
            icon="hero-document-check"
            current={@official_form_current}
          >
            <:description>
              Akzeptiert wird ein A4-PDF mit allen bekannten AcroForm-Feldern. Struktur,
              Verschlüsselung und Feldvertrag werden vor der Aktivierung geprüft.
            </:description>

            <.form
              for={@official_form_form}
              id="official-form-upload-form"
              phx-change="validate_official_form"
              phx-submit="replace_official_form"
              class={["mt-6 space-y-4"]}
            >
              <.input
                field={@official_form_form[:version]}
                id="official-form-version"
                label="Formularversion"
                placeholder="z. B. Formular 2027 (ME/01/27)"
                required
              />
              <.input
                field={@official_form_form[:source_url]}
                id="official-form-source-url"
                type="url"
                label="Offizielle Quelladresse"
                placeholder="https://…"
                required
              />
              <.upload_field
                id="official-form-upload"
                upload={@uploads.official_form}
                label="PDF auswählen"
                hint="PDF · maximal 15 MB"
                upload_name="official_form"
              />
              <button
                id="activate-official-form"
                type="submit"
                disabled={!upload_ready?(@uploads.official_form)}
                phx-disable-with="Formular wird geprüft …"
                class={submit_class()}
              >
                <.icon name="hero-arrow-up-tray" class="size-5" /> Formular prüfen und aktivieren
              </button>
            </.form>
          </.source_panel>

          <.source_panel
            id="bahn-archive-source"
            eyebrow="Historische Ist-Daten"
            title="Bahn-Vorhersage"
            icon="hero-clock"
            current={@archive_current}
          >
            <:description>
              Lade die CSV-Projektion des Parsed-Train-Delays-Exports hoch. Spalten,
              Zeitwerte und Datenabdeckung werden vor der Aktivierung geprüft.
            </:description>

            <.form
              for={@archive_form}
              id="bahn-archive-upload-form"
              phx-change="validate_archive"
              phx-submit="replace_archive"
              class={["mt-6 space-y-4"]}
            >
              <.input
                field={@archive_form[:version]}
                id="bahn-archive-version"
                label="Datensatzversion"
                placeholder="z. B. parsed-delays-2026"
                required
              />
              <.input
                field={@archive_form[:source_url]}
                id="bahn-archive-source-url"
                type="url"
                label="Quelladresse (optional)"
                placeholder="https://…"
              />
              <.upload_field
                id="bahn-archive-upload"
                upload={@uploads.bahn_archive}
                label="CSV-Projektion auswählen"
                hint="CSV · maximal 250 MB"
                upload_name="bahn_archive"
              />
              <button
                id="activate-bahn-archive"
                type="submit"
                disabled={!upload_ready?(@uploads.bahn_archive)}
                phx-disable-with="Datensatz wird geprüft …"
                class={submit_class()}
              >
                <.icon name="hero-arrow-up-tray" class="size-5" /> Datensatz prüfen und aktivieren
              </button>
            </.form>
          </.source_panel>
        </div>

        <section
          id="reference-data-history"
          class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}
        >
          <div class={["flex items-start gap-3"]}>
            <span class={["rounded-xl bg-slate-100 p-2 text-slate-700"]}>
              <.icon name="hero-archive-box" class="size-5" />
            </span>
            <div>
              <h2 class={["text-lg font-semibold text-slate-950"]}>Versionshistorie</h2>
              <p class={["mt-1 text-sm leading-6 text-slate-500"]}>
                Frühere Quelldateien bleiben nachvollziehbar und werden nicht überschrieben.
              </p>
            </div>
          </div>

          <div class={["mt-6 grid gap-6 lg:grid-cols-2"]}>
            <.version_list
              id="official-form-versions"
              title="Formulare"
              versions={@streams.official_form_versions}
            />
            <.version_list
              id="bahn-archive-versions"
              title="Bahn-Vorhersage"
              versions={@streams.bahn_archive_versions}
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :current, :map, default: nil
  slot :description, required: true
  slot :inner_block, required: true

  defp source_panel(assigns) do
    ~H"""
    <section id={@id} class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}>
      <div class={["flex items-start gap-3"]}>
        <span class={["rounded-xl bg-rose-50 p-2.5 text-rose-700"]}>
          <.icon name={@icon} class="size-5" />
        </span>
        <div>
          <p class={["text-xs font-semibold uppercase tracking-[0.18em] text-rose-700"]}>
            {@eyebrow}
          </p>
          <h2 class={["mt-1 text-xl font-semibold text-slate-950"]}>{@title}</h2>
        </div>
      </div>

      <p class={["mt-4 text-sm leading-6 text-slate-600"]}>{render_slot(@description)}</p>

      <div
        id={"#{@id}-current"}
        data-state={if(@current, do: "available", else: "missing")}
        class={[
          "mt-5 rounded-2xl border px-4 py-3",
          if(@current,
            do: "border-emerald-200 bg-emerald-50",
            else: "border-slate-200 bg-slate-50"
          )
        ]}
      >
        <%= if @current do %>
          <div class={["flex items-center justify-between gap-3"]}>
            <div class={["min-w-0"]}>
              <p class={["text-xs font-semibold uppercase tracking-[0.14em] text-emerald-800"]}>
                Aktive Version
              </p>
              <p class={["mt-1 truncate text-sm font-semibold text-slate-950"]}>
                {@current.version}
              </p>
            </div>
            <span class={[
              "shrink-0 rounded-full bg-white px-2.5 py-1 text-xs font-semibold text-emerald-800 shadow-sm"
            ]}>
              {@current.origin}
            </span>
          </div>
          <div class={["mt-3 grid gap-1 text-xs text-slate-600 sm:grid-cols-2"]}>
            <p>Datei: {@current.filename}</p>
            <p>SHA-256: {@current.sha256}</p>
            <p :if={@current.coverage}>Abdeckung: {@current.coverage}</p>
            <p :if={@current.inserted_at}>Aktiviert: {format_datetime(@current.inserted_at)}</p>
          </div>
        <% else %>
          <p class={["text-sm font-semibold text-slate-700"]}>Noch keine Quelle verfügbar</p>
        <% end %>
      </div>

      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :upload, :map, required: true
  attr :upload_name, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, required: true

  defp upload_field(assigns) do
    ~H"""
    <div
      id={@id}
      phx-drop-target={@upload.ref}
      class={[
        "rounded-2xl border border-dashed border-slate-300 bg-slate-50 p-4 transition hover:border-rose-300 hover:bg-rose-50/40"
      ]}
    >
      <div class={["flex items-center justify-between gap-3"]}>
        <div>
          <p class={["text-sm font-semibold text-slate-800"]}>{@label}</p>
          <p class={["mt-0.5 text-xs text-slate-500"]}>{@hint}</p>
        </div>
        <label
          for={@upload.ref}
          class={[
            "cursor-pointer rounded-xl border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-700 shadow-sm transition hover:border-slate-300 hover:text-slate-950"
          ]}
        >
          Datei wählen
        </label>
      </div>
      <.live_file_input upload={@upload} class="sr-only" />

      <div :for={entry <- @upload.entries} class={["mt-3 rounded-xl bg-white px-3 py-2 shadow-sm"]}>
        <div class={["flex items-center gap-3"]}>
          <.icon name="hero-document" class="size-5 shrink-0 text-slate-500" />
          <div class={["min-w-0 flex-1"]}>
            <p class={["truncate text-xs font-semibold text-slate-800"]}>{entry.client_name}</p>
            <div class={["mt-1 h-1.5 overflow-hidden rounded-full bg-slate-100"]}>
              <div
                class={["h-full rounded-full bg-rose-600 transition-all"]}
                style={"width: #{entry.progress}%"}
              >
              </div>
            </div>
          </div>
          <button
            type="button"
            phx-click="cancel_upload"
            phx-value-upload={@upload_name}
            phx-value-ref={entry.ref}
            aria-label="Upload entfernen"
            class={[
              "rounded-lg p-1.5 text-slate-400 transition hover:bg-slate-100 hover:text-slate-700"
            ]}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <p
          :for={error <- upload_errors(@upload, entry)}
          class={["mt-2 text-xs font-medium text-rose-700"]}
        >
          {upload_error_message(error)}
        </p>
      </div>

      <p :for={error <- upload_errors(@upload)} class={["mt-2 text-xs font-medium text-rose-700"]}>
        {upload_error_message(error)}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :versions, :any, required: true

  defp version_list(assigns) do
    ~H"""
    <div>
      <h3 class={["text-sm font-semibold text-slate-950"]}>{@title}</h3>
      <div id={@id} phx-update="stream" class={["mt-3 space-y-2"]}>
        <div
          id={"#{@id}-empty"}
          class={["hidden only:block rounded-xl bg-slate-50 px-3 py-3 text-sm text-slate-500"]}
        >
          Noch keine Version über die Oberfläche aktiviert.
        </div>
        <article
          :for={{dom_id, version} <- @versions}
          id={dom_id}
          class={[
            "flex items-start justify-between gap-3 rounded-xl border px-3 py-3",
            if(version.current,
              do: "border-emerald-200 bg-emerald-50/70",
              else: "border-slate-200 bg-white"
            )
          ]}
        >
          <div class={["min-w-0"]}>
            <p class={["truncate text-sm font-semibold text-slate-900"]}>{version.version}</p>
            <p class={["mt-1 truncate text-xs text-slate-500"]}>{version.original_filename}</p>
          </div>
          <span class={["shrink-0 text-xs font-medium text-slate-500"]}>
            {if(version.current, do: "Aktiv", else: format_date(version.inserted_at))}
          </span>
        </article>
      </div>
    </div>
    """
  end

  defp refresh_sources(socket) do
    scope = socket.assigns.current_scope
    {:ok, form_versions} = ReferenceData.list_versions(scope, :official_form)
    {:ok, archive_versions} = ReferenceData.list_versions(scope, :bahn_vorhersage_archive)

    socket
    |> assign(:official_form_current, current_form_source(form_versions))
    |> assign(:archive_current, current_archive_source(archive_versions))
    |> stream(:official_form_versions, form_versions, reset: true)
    |> stream(:bahn_archive_versions, archive_versions, reset: true)
  end

  defp current_form_source(versions) do
    case Enum.find(versions, & &1.current) do
      nil ->
        case Template.current() do
          {:ok, template} ->
            %{
              version: template.version,
              filename: Path.basename(template.path),
              sha256: short_sha(template.sha256),
              coverage: nil,
              inserted_at: nil,
              origin: "Mitgeliefert"
            }

          {:error, _reason} ->
            nil
        end

      version ->
        managed_source(version, :official_form, nil)
    end
  end

  defp current_archive_source(versions) do
    case Enum.find(versions, & &1.current) do
      nil ->
        config = Application.get_env(:fahrgastrechte, BahnVorhersageArchive, [])
        path = Keyword.get(config, :data_path)

        if is_binary(path) and File.regular?(path) do
          %{
            version: Keyword.get(config, :dataset_version) || "Konfigurierter Datensatz",
            filename: Path.basename(path),
            sha256: "wird beim Abruf geprüft",
            coverage: nil,
            inserted_at: nil,
            origin: "Konfiguration"
          }
        end

      version ->
        coverage =
          case version.metadata do
            %{"coverage_from" => from, "coverage_until" => until} -> "#{from} – #{until}"
            _metadata -> nil
          end

        managed_source(version, :bahn_vorhersage_archive, coverage)
    end
  end

  defp managed_source(version, kind, coverage) do
    case ReferenceData.current_file(kind) do
      {:ok, %{version: %{id: id}}} when id == version.id -> version_source(version, coverage)
      _error -> nil
    end
  end

  defp version_source(version, coverage) do
    %{
      version: version.version,
      filename: version.original_filename,
      sha256: short_sha(version.sha256),
      coverage: coverage,
      inserted_at: version.inserted_at,
      origin: "Interface"
    }
  end

  defp consume_one(socket, upload_name, callback) do
    case uploaded_entries(socket, upload_name) do
      {[_entry], []} ->
        case consume_uploaded_entries(socket, upload_name, fn %{path: path}, consumed_entry ->
               {:ok, callback.(path, consumed_entry)}
             end) do
          [result] -> result
          _other -> {:error, :upload_failed}
        end

      {[], [_entry | _rest]} ->
        {:error, :upload_in_progress}

      _other ->
        {:error, :upload_required}
    end
  end

  defp official_form_form do
    to_form(%{"version" => "", "source_url" => ""}, as: :official_form)
  end

  defp archive_form do
    to_form(%{"version" => "", "source_url" => @archive_source_url}, as: :archive)
  end

  defp upload_ready?(upload) do
    match?(
      {[_entry], []},
      {upload.entries |> Enum.filter(& &1.done?), upload.entries |> Enum.reject(& &1.done?)}
    )
  end

  defp submit_class do
    [
      "inline-flex w-full items-center justify-center gap-2 rounded-xl bg-slate-950 px-5 py-3 text-sm font-semibold text-white shadow-sm transition hover:-translate-y-0.5 hover:bg-rose-700 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700 disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:translate-y-0"
    ]
  end

  defp upload_error_message(:too_large), do: "Die Datei überschreitet die erlaubte Größe."
  defp upload_error_message(:not_accepted), do: "Dieses Dateiformat wird nicht akzeptiert."
  defp upload_error_message(:too_many_files), do: "Bitte wähle genau eine Datei."
  defp upload_error_message(_error), do: "Die Datei konnte nicht hochgeladen werden."

  defp source_error_message(:official_form, %Ecto.Changeset{}),
    do: "Version und offizielle HTTPS-Quelladresse müssen gültig sein."

  defp source_error_message(:archive, %Ecto.Changeset{}),
    do: "Datensatzversion und Quelladresse müssen gültig sein."

  defp source_error_message(:official_form, :missing_field),
    do: "Das PDF enthält nicht alle benötigten Formularfelder."

  defp source_error_message(:official_form, :encrypted),
    do: "Ein verschlüsseltes Formular kann nicht aktiviert werden."

  defp source_error_message(:archive, :invalid_archive),
    do: "Die CSV-Datei entspricht nicht der erwarteten Bahn-Vorhersage-Projektion."

  defp source_error_message(_kind, :upload_required), do: "Bitte wähle zuerst eine Datei aus."

  defp source_error_message(_kind, :upload_in_progress),
    do: "Der Upload ist noch nicht abgeschlossen."

  defp source_error_message(_kind, :file_too_large), do: "Die Datei ist zu groß."
  defp source_error_message(_kind, :resource_limit), do: "Die Datei überschreitet ein Prüflimit."
  defp source_error_message(_kind, :timeout), do: "Die Prüfung hat zu lange gedauert."

  defp source_error_message(_kind, _reason),
    do: "Die Datei konnte nicht geprüft und aktiviert werden."

  defp short_sha(sha256) when is_binary(sha256) do
    sha256
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%d.%m.%Y · %H:%M Uhr")
  end

  defp format_date(datetime), do: Calendar.strftime(datetime, "%d.%m.%Y")

  defp reference_config(key) do
    :fahrgastrechte
    |> Application.fetch_env!(ReferenceData)
    |> Keyword.fetch!(key)
  end
end
