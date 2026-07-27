defmodule Fahrgastrechte.Tickets.PopplerExtractor do
  @moduledoc false

  @behaviour Fahrgastrechte.Tickets.Extractor

  alias Fahrgastrechte.Documents.CommandRunner

  @impl true
  def extract(pdf_path, options) do
    executable = Keyword.fetch!(options, :pdftotext_executable)
    timeout = Keyword.fetch!(options, :command_timeout_ms)
    max_text_bytes = Keyword.fetch!(options, :max_text_bytes)
    pages = Keyword.fetch!(options, :pages)

    case CommandRunner.run(executable, ["-layout", "-enc", "UTF-8", pdf_path, "-"], timeout) do
      {:ok, text} ->
        cond do
          byte_size(text) > max_text_bytes -> {:error, :resource_limit}
          String.trim(text) == "" -> {:error, :no_text}
          true -> {:ok, %{text: text, pages: pages, metadata: %{backend: "poppler"}}}
        end

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :command_failed} ->
        {:error, :invalid_pdf}
    end
  end

  @impl true
  def propose(extraction, options) do
    document_kind = Keyword.fetch!(options, :document_kind)

    suggestions =
      extraction.text
      |> String.split("\f", trim: false)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {page_text, page_number} ->
        page_text
        |> String.split(~r/\R/u, trim: true)
        |> Enum.flat_map(&line_suggestions(String.trim(&1), page_number, document_kind))
      end)
      |> Enum.uniq_by(& &1.field)

    {:ok, suggestions}
  end

  defp line_suggestions("", _page, _kind), do: []

  defp line_suggestions(line, page, kind) do
    []
    |> maybe_add(order_number(line, page))
    |> maybe_add(validity(line, page))
    |> maybe_add(origin(line, page))
    |> maybe_add(destination(line, page))
    |> maybe_add(product(line, page))
    |> maybe_add(fare(line, page, kind))
    |> maybe_add(scheduled_train(line, page))
    |> maybe_add(scheduled_time(line, page, :scheduled_departure, "ab"))
    |> maybe_add(scheduled_time(line, page, :scheduled_arrival, "an"))
    |> List.flatten()
  end

  defp order_number(line, page) do
    case Regex.run(~r/^Auftragsnummer:\s*(\d{12})$/u, line, capture: :all_but_first) do
      [number] -> suggestion(:order_number, %{"text" => number}, 0.98, page, line)
      _other -> nil
    end
  end

  defp validity(line, page) do
    cond do
      captures =
          Regex.run(~r/^Geltungstag:\s*(\d{2}\.\d{2}\.\d{4})$/u, line, capture: :all_but_first) ->
        case captures do
          [date] -> date_suggestion(:travel_date, date, 0.95, page, line)
          _other -> nil
        end

      captures =
          Regex.run(
            ~r/^Geltungszeitraum:\s*(\d{2}\.\d{2}\.\d{4})\s+bis\s+(\d{2}\.\d{2}\.\d{4})$/u,
            line,
            capture: :all_but_first
          ) ->
        case captures do
          [first_date, last_date] ->
            [
              date_suggestion(:travel_date, first_date, 0.95, page, line),
              date_suggestion(:valid_until, last_date, 0.95, page, line)
            ]
            |> Enum.reject(&is_nil/1)

          _other ->
            nil
        end

      true ->
        nil
    end
  end

  defp origin(line, page) do
    case Regex.run(~r/^Von:\s*(.+)$/u, line, capture: :all_but_first) do
      [value] -> suggestion(:origin, %{"text" => String.trim(value)}, 0.90, page, line)
      _other -> nil
    end
  end

  defp destination(line, page) do
    case Regex.run(~r/^Nach:\s*(.+)$/u, line, capture: :all_but_first) do
      [value] -> suggestion(:destination, %{"text" => String.trim(value)}, 0.90, page, line)
      _other -> nil
    end
  end

  defp product(line, page) do
    case Regex.run(~r/^Produkt:\s*(Flexpreis(?: Business)?)$/u, line, capture: :all_but_first) do
      [value] -> suggestion(:product, %{"text" => value}, 0.95, page, line)
      _other -> nil
    end
  end

  defp fare(line, page, kind) do
    label = if kind == :invoice, do: "Gesamtbetrag", else: "Fahrpreis"
    pattern = Regex.compile!("^#{label}:\\s*([0-9]+(?:[.,][0-9]{2}))\\s+(EUR)$", "u")

    case Regex.run(pattern, line, capture: :all_but_first) do
      [amount, currency] ->
        value = %{"amount" => String.replace(amount, ",", "."), "currency" => currency}
        suggestion(:fare, value, 0.90, page, line)

      _other ->
        nil
    end
  end

  defp scheduled_train(line, page) do
    case Regex.run(~r/^Reiseplan.*:\s*([A-Z]{2,5})\s+(\d+)$/u, line, capture: :all_but_first) do
      [category, number] ->
        suggestion(
          :scheduled_train,
          %{"category" => category, "number" => number},
          0.80,
          page,
          line
        )

      _other ->
        nil
    end
  end

  defp scheduled_time(line, page, field, marker) do
    pattern = Regex.compile!("^(.+?)\\s+#{marker}\\s+(\\d{2}:\\d{2})$", "u")

    case Regex.run(pattern, line, capture: :all_but_first) do
      [station, time] ->
        case Time.from_iso8601(time <> ":00") do
          {:ok, _parsed} ->
            suggestion(
              field,
              %{"station" => String.trim(station), "time" => time},
              0.80,
              page,
              line
            )

          {:error, _reason} ->
            nil
        end

      _other ->
        nil
    end
  end

  defp date_suggestion(field, value, confidence, page, line) do
    case Regex.run(~r/^(\d{2})\.(\d{2})\.(\d{4})$/, value, capture: :all_but_first) do
      [day, month, year] ->
        with {day, ""} <- Integer.parse(day),
             {month, ""} <- Integer.parse(month),
             {year, ""} <- Integer.parse(year),
             {:ok, date} <- Date.new(year, month, day) do
          suggestion(field, %{"date" => Date.to_iso8601(date)}, confidence, page, line)
        else
          _error -> nil
        end

      _other ->
        nil
    end
  end

  defp suggestion(field, value, confidence, page, excerpt) do
    %{
      field: field,
      value: value,
      confidence: confidence,
      source: %{page: page, excerpt: String.slice(excerpt, 0, 500)}
    }
  end

  defp maybe_add(suggestions, nil), do: suggestions
  defp maybe_add(suggestions, addition) when is_list(addition), do: [addition | suggestions]
  defp maybe_add(suggestions, addition), do: [addition | suggestions]
end
