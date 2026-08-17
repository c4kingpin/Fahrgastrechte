defmodule FahrgastrechteWeb.ClaimLive.Presentation do
  @moduledoc """
  Labels, formatting and visual-state helpers shared by claim views.
  """

  alias Fahrgastrechte.Documents.Document
  alias Fahrgastrechte.Rail.BerlinTime

  def transition_message(:draft), do: "Der Antrag ist wieder zur Bearbeitung geöffnet."
  def transition_message(:sent), do: "Der Antrag wurde als versendet markiert."
  def transition_message(:completed), do: "Der Antrag wurde als erledigt markiert."

  def editable?(status), do: status in [:draft, :ready]

  def route_label(%{origin: origin, destination: destination})
      when is_binary(origin) and is_binary(destination),
      do: "#{origin} → #{destination}"

  def route_label(_claim), do: "Strecke noch offen"

  def status_label(:draft), do: "Entwurf"
  def status_label(:ready), do: "Druckfertig"
  def status_label(:sent), do: "Versendet"
  def status_label(:completed), do: "Erledigt"

  def status_history_label(%{from_status: nil, to_status: status}),
    do: "Als #{status_label(status)} angelegt"

  def status_history_label(%{from_status: from_status, to_status: to_status}),
    do: "#{status_label(from_status)} → #{status_label(to_status)}"

  def status_style(:draft), do: "bg-amber-400/15 text-amber-200"
  def status_style(:ready), do: "bg-sky-400/15 text-sky-200"
  def status_style(:sent), do: "bg-violet-400/15 text-violet-200"
  def status_style(:completed), do: "bg-emerald-400/15 text-emerald-200"

  def status_explanation(:draft),
    do: "Der Fall kann bearbeitet und mit Dokumenten ergänzt werden."

  def status_explanation(:ready),
    do: "Die Ausgabe ist druckfertig und kann nach dem Versand fortgeschrieben werden."

  def status_explanation(:sent),
    do: "Der Antrag ist versendet. Öffne ihn erneut, bevor du Daten änderst."

  def status_explanation(:completed),
    do: "Dieser Fall ist abgeschlossen und bleibt in deiner Übersicht erhalten."

  def save_state_label(:saved), do: "Erfolgreich gespeichert"
  def save_state_label(:invalid), do: "Eingabe prüfen"
  def save_state_label(:error), do: "Speichern fehlgeschlagen"
  def save_state_label(:conflict), do: "Konflikt erkannt – neu geladen"

  def save_state_style(:saved), do: "bg-emerald-50 text-emerald-700"
  def save_state_style(:invalid), do: "bg-rose-50 text-rose-700"
  def save_state_style(:error), do: "bg-rose-50 text-rose-700"
  def save_state_style(:conflict), do: "bg-amber-50 text-amber-800"

  def step_badge_label(:confirmed), do: "Bestätigt"
  def step_badge_label(:incomplete), do: "Unvollständig"
  def step_badge_label(:open), do: "Offen"
  def step_badge_style(:confirmed), do: "bg-emerald-50 text-emerald-700"
  def step_badge_style(:incomplete), do: "bg-amber-50 text-amber-800"
  def step_badge_style(:open), do: "bg-slate-100 text-slate-600"
  def step_badge_icon(:confirmed), do: "hero-check-circle"
  def step_badge_icon(:incomplete), do: "hero-exclamation-circle"
  def step_badge_icon(:open), do: "hero-minus-circle"

  def candidate_primary_segment(candidate), do: List.first(candidate.segments) || %{}

  def candidate_transfer_label(candidate) do
    case max(length(candidate.segments) - 1, 0) do
      0 -> "Direktverbindung"
      1 -> "1 Umstieg"
      count -> "#{count} Umstiege"
    end
  end

  def candidate_source(candidate),
    do: candidate.source |> to_string() |> String.split(".") |> List.last()

  def candidate_status_label(%{cancelled: true}), do: "Zug fällt aus"

  def candidate_status_label(segment) do
    case delay_minutes(segment) do
      nil -> "Keine Prognose"
      minutes when minutes <= 0 -> "Pünktlich"
      minutes -> "+#{minutes} Min."
    end
  end

  def candidate_status_style(%{cancelled: true}), do: "bg-rose-100 text-rose-800"

  def candidate_status_style(segment) do
    case delay_minutes(segment) do
      nil -> "bg-slate-100 text-slate-700"
      minutes when minutes <= 0 -> "bg-emerald-100 text-emerald-800"
      minutes when minutes < 60 -> "bg-amber-100 text-amber-800"
      _minutes -> "bg-rose-100 text-rose-800"
    end
  end

  def delay_minutes(segment) do
    scheduled = Map.get(segment, :scheduled_arrival) || Map.get(segment, :scheduled_departure)

    current =
      Map.get(segment, :actual_arrival) || Map.get(segment, :estimated_arrival) ||
        Map.get(segment, :actual_departure) || Map.get(segment, :estimated_departure)

    if scheduled && current, do: div(DateTime.diff(current, scheduled, :second), 60), else: nil
  end

  def candidate_current_time(segment) do
    current =
      Map.get(segment, :actual_arrival) || Map.get(segment, :estimated_arrival) ||
        Map.get(segment, :actual_departure) || Map.get(segment, :estimated_departure)

    if current, do: "#{format_time(current)} Uhr", else: "noch keine Prognose"
  end

  def train_label(segment) do
    [Map.get(segment, :train_category), Map.get(segment, :train_number)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> "Verbindung"
      label -> label
    end
  end

  def disruption_choice_style(true),
    do: "border-rose-700 bg-rose-50 text-rose-900 shadow-sm"

  def disruption_choice_style(false),
    do: "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"

  def journey_delay_summary(journey) do
    segment = List.last(journey.segments)

    case delay_minutes(segment) do
      nil -> "#{train_label(segment)} · tatsächliche Ankunft noch ergänzen"
      minutes when minutes <= 0 -> "#{train_label(segment)} · derzeit pünktlich"
      minutes -> "#{train_label(segment)} · derzeit #{minutes} Minuten verspätet"
    end
  end

  def trip_summary_route(%{origin: origin, destination: destination}, _suggestions_by_id)
      when is_binary(origin) and is_binary(destination),
      do: "#{origin} → #{destination}"

  def trip_summary_route(_claim, suggestions_by_id) do
    with origin when is_binary(origin) <- trip_summary_suggested_text(suggestions_by_id, :origin),
         destination when is_binary(destination) <-
           trip_summary_suggested_text(suggestions_by_id, :destination) do
      "#{origin} → #{destination} (Vorschlag)"
    else
      _missing -> "Strecke noch offen"
    end
  end

  def trip_summary_date(%{travel_date: %Date{} = date}, _suggestions_by_id), do: format_date(date)

  def trip_summary_date(_claim, suggestions_by_id) do
    case Enum.find(Map.values(suggestions_by_id), &(&1.field == :travel_date)) do
      %{value: %{"date" => iso_date}} ->
        case Date.from_iso8601(iso_date) do
          {:ok, date} -> "#{format_date(date)} (Vorschlag)"
          {:error, _reason} -> "Noch offen"
        end

      _no_suggestion ->
        "Noch offen"
    end
  end

  defp trip_summary_suggested_text(suggestions_by_id, field) do
    suggestions_by_id
    |> Map.values()
    |> Enum.find(&(&1.field == field))
    |> case do
      %{value: %{"text" => text}} -> text
      _no_suggestion -> nil
    end
  end

  def trip_summary_train(%{segments: [first | _]}, _suggestions_by_id), do: train_label(first)

  def trip_summary_train(_journey, suggestions_by_id) do
    case Enum.find(Map.values(suggestions_by_id), &(&1.field == :scheduled_train)) do
      %{value: %{"category" => category, "number" => number}} ->
        "#{category} #{number} (Vorschlag)"

      _no_suggestion ->
        "Noch offen"
    end
  end

  def trip_summary_scheduled(%{segments: [first | _] = segments}) do
    "#{format_datetime(first.scheduled_departure)} – #{format_datetime(List.last(segments).scheduled_arrival)}"
  end

  def trip_summary_scheduled(_journey), do: "Noch offen"

  def trip_summary_disruption(%{disruption_cause: :cancellation}, _actual_journey),
    do: disruption_label(:cancellation)

  def trip_summary_disruption(_claim, %{segments: [_ | _] = segments}) do
    case delay_minutes(List.last(segments)) do
      nil -> "Noch keine Prognose"
      minutes when minutes <= 0 -> "Pünktlich"
      minutes -> "#{minutes} Minuten verspätet"
    end
  end

  def trip_summary_disruption(_claim, _actual_journey), do: "Noch offen"

  def trip_summary_actual_arrival(%{segments: [_ | _] = segments}) do
    format_optional_datetime(
      List.last(segments).actual_arrival || List.last(segments).estimated_arrival
    )
  end

  def trip_summary_actual_arrival(_journey), do: "Noch offen"

  def trip_summary_order_number(suggestions_by_id) do
    suggestions_by_id
    |> Map.values()
    |> Enum.find(&(&1.field == :order_number))
    |> case do
      %{value: %{"text" => number}} -> number
      _no_order_number -> "Noch offen"
    end
  end

  def workspace_progress_label([]), do: "Bereit zur Prüfung"
  def workspace_progress_label([%{label: label}]), do: "Fast fertig – es fehlt noch: #{label}"

  def workspace_progress_label([%{label: label} | rest]),
    do: "Es fehlt noch: #{label} (+#{length(rest)} weitere)"

  def source_label("search_stations"), do: "Bahnhofssuche"
  def source_label("search_connections"), do: "Verbindungssuche"
  def source_label("departures"), do: "Abfahrten und Abweichungen"
  def source_label(operation), do: operation

  def format_datetime(%DateTime{} = datetime) do
    datetime
    |> BerlinTime.to_local()
    |> Calendar.strftime("%d.%m.%Y, %H:%M Uhr")
  end

  def format_datetime(nil), do: "–"
  def format_optional_datetime(nil), do: "keine Ist-Zeit"
  def format_optional_datetime(datetime), do: format_datetime(datetime)

  def format_date(nil), do: "Noch offen"
  def format_date(%Date{} = date), do: Calendar.strftime(date, "%d.%m.%Y")

  def journey_outcome_label(:delayed_arrival), do: "Verspätet angekommen"
  def journey_outcome_label(:not_started), do: "Reise nicht angetreten"
  def journey_outcome_label(:aborted), do: "Reise abgebrochen"

  def journey_outcome_label(:continued_with_other_transport),
    do: "Mit anderem Verkehrsmittel weitergefahren"

  def journey_outcome_label(_outcome), do: "Noch offen"

  def disruption_label(:delay), do: "Verspätung"
  def disruption_label(:cancellation), do: "Zugausfall"
  def disruption_label(:missed_connection), do: "Anschlussverlust"
  def disruption_label(_cause), do: "Noch offen"

  def journey_direction_label(:outbound), do: "Hinfahrt"
  def journey_direction_label(:return), do: "Rückfahrt"
  def journey_direction_label(_direction), do: "Noch offen"

  def format_time(nil), do: "–"

  def format_time(%DateTime{} = datetime) do
    datetime
    |> BerlinTime.to_local()
    |> Calendar.strftime("%H:%M")
  end

  def document_kind_label(:ticket), do: "DB-Ticket"
  def document_kind_label(:invoice), do: "DB-Rechnung"

  def analysis_label(%Document{analysis_status: :failed, manual_fallback_confirmed_at: at})
      when not is_nil(at),
      do: "Manuell bestätigt"

  def analysis_label(%Document{analysis_status: status}), do: analysis_label(status)

  def analysis_label(:not_started), do: "Noch nicht ausgewertet"
  def analysis_label(:completed), do: "Auswertung abgeschlossen"
  def analysis_label(:manual_required), do: "Manuelle Eingabe nötig"
  def analysis_label(:failed), do: "Auswertung fehlgeschlagen"

  def analysis_style(%Document{analysis_status: :failed, manual_fallback_confirmed_at: at})
      when not is_nil(at),
      do: "bg-amber-50 text-amber-800"

  def analysis_style(%Document{analysis_status: status}), do: analysis_style(status)

  def analysis_style(:not_started), do: "bg-slate-100 text-slate-700"
  def analysis_style(:completed), do: "bg-emerald-50 text-emerald-700"
  def analysis_style(:manual_required), do: "bg-amber-50 text-amber-800"
  def analysis_style(:failed), do: "bg-rose-50 text-rose-700"

  def suggestion_card_style(:proposed), do: "border-sky-200 bg-sky-50/50"
  def suggestion_card_style(:accepted), do: "border-emerald-200 bg-emerald-50/50"
  def suggestion_card_style(:rejected), do: "border-slate-200 bg-slate-50 opacity-70"

  def suggestion_state_style(:accepted), do: "bg-emerald-100 text-emerald-800"
  def suggestion_state_style(:rejected), do: "bg-slate-200 text-slate-700"

  def suggestion_field_label(:order_number), do: "Auftragsnummer"
  def suggestion_field_label(:travel_date), do: "Reisedatum"
  def suggestion_field_label(:valid_until), do: "Gültig bis"
  def suggestion_field_label(:origin), do: "Start"
  def suggestion_field_label(:destination), do: "Ziel"
  def suggestion_field_label(:product), do: "Produkt"
  def suggestion_field_label(:fare), do: "Fahrpreis"
  def suggestion_field_label(:scheduled_train), do: "Geplanter Zug"
  def suggestion_field_label(:scheduled_departure), do: "Planmäßige Abfahrt"
  def suggestion_field_label(:scheduled_arrival), do: "Planmäßige Ankunft"

  def suggestion_value(%{field: field, value: value})
      when field in [:order_number, :origin, :destination, :product],
      do: Map.get(value, "text", "–")

  def suggestion_value(%{field: field, value: value}) when field in [:travel_date, :valid_until],
    do: format_iso_date(Map.get(value, "date"))

  def suggestion_value(%{field: :fare, value: value}),
    do: "#{Map.get(value, "amount", "–")} #{Map.get(value, "currency", "")}" |> String.trim()

  def suggestion_value(%{field: :scheduled_train, value: value}),
    do: "#{Map.get(value, "category", "")} #{Map.get(value, "number", "")}" |> String.trim()

  def suggestion_value(%{field: field, value: value})
      when field in [:scheduled_departure, :scheduled_arrival],
      do: "#{Map.get(value, "station", "–")} · #{Map.get(value, "time", "–")} Uhr"

  def accept_label(field) when field in [:travel_date, :origin, :destination], do: "Übernehmen"
  def accept_label(_field), do: "Bestätigen"

  def suggestion_accept_message(field) when field in [:travel_date, :origin, :destination],
    do: "Der Vorschlag wurde bestätigt und in die Falldaten übernommen."

  def suggestion_accept_message(_field), do: "Der Vorschlag wurde bestätigt."

  def confidence_label(confidence), do: "#{round(confidence * 100)} % sicher"

  @doc "True when a station suggestion could not be matched against a real station."
  def suggestion_unresolved?(%{field: field, value: value})
      when field in [:origin, :destination],
      do: Map.get(value, "unresolved", false) == true

  def suggestion_unresolved?(_suggestion), do: false

  def source_document_name(documents_by_id, document_id) do
    case Map.get(documents_by_id, document_id) do
      nil -> "Dokument"
      document -> document.original_filename
    end
  end

  def format_iso_date(nil), do: "–"

  def format_iso_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Calendar.strftime(date, "%d.%m.%Y")
      {:error, _reason} -> value
    end
  end

  def format_bytes(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  def format_bytes(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  def journey_error_message(:invalid_datetime), do: "Bitte trage alle benötigten Zeiten ein."

  def journey_error_message(:invalid_time_order),
    do: "Die Ankunft darf nicht vor der Abfahrt liegen."

  def journey_error_message(:missing_disruption),
    do: "Bitte wähle Verspätung oder Zugausfall."

  def journey_error_message(:missing_planned),
    do: "Bestätige zuerst die geplante Verbindung."

  def journey_error_message(_reason),
    do: "Die Verbindung konnte nicht bestätigt werden. Bitte prüfe die Angaben."

  def export_error_message(%{type: :incomplete}),
    do: "Der Antrag ist noch unvollständig. Prüfe die markierten Schritte."

  def export_error_message(:template_unavailable),
    do: "Das offizielle Formular ist derzeit nicht verfügbar."

  def export_error_message(:timeout), do: "Die PDF-Erzeugung hat zu lange gedauert."

  def export_error_message(:busy),
    do: "Es wird gerade ein anderes PDF erzeugt. Bitte versuche es in einer Minute erneut."

  def export_error_message(_reason), do: "Das Gesamt-PDF konnte nicht erstellt werden."

  def upload_error_message(:too_large), do: "Die PDF-Datei ist zu groß."
  def upload_error_message(:not_accepted), do: "Bitte verwende ausschließlich PDF-Dateien."
  def upload_error_message(:too_many_files), do: "Bitte wähle höchstens zwei Dateien aus."
  def upload_error_message(_error), do: "Die Datei konnte nicht hochgeladen werden."

  def document_error_message(:wrong_content_type), do: "Die Datei wurde nicht als PDF erkannt."
  def document_error_message(:invalid_pdf), do: "Die PDF-Datei ist beschädigt oder ungültig."

  def document_error_message(:file_too_large),
    do: "Die PDF-Datei überschreitet die Größenbegrenzung."

  def document_error_message(:too_many_pages), do: "Die PDF-Datei enthält zu viele Seiten."
  def document_error_message(:timeout), do: "Die PDF-Prüfung hat zu lange gedauert."

  def document_error_message(:stale),
    do: "Der Antrag wurde geändert. Bitte versuche den Upload erneut."

  def document_error_message(_reason), do: "Das Dokument konnte nicht sicher gespeichert werden."

  def status_style(:draft, :light), do: "bg-amber-50 text-amber-800"
  def status_style(:ready, :light), do: "bg-sky-50 text-sky-800"
  def status_style(:sent, :light), do: "bg-violet-50 text-violet-800"
  def status_style(:completed, :light), do: "bg-emerald-50 text-emerald-800"
end
