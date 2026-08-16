defmodule Fahrgastrechte.GermanDateTime do
  @moduledoc """
  Parses and formats the German `dd.MM.yyyy[, HH:MM]` date/time display format
  used by form inputs, alongside ISO 8601 for values coming from stored data.
  """

  @date_re ~r/^\s*(\d{2})\.(\d{2})\.(\d{4})\s*$/
  @datetime_re ~r/^\s*(\d{2})\.(\d{2})\.(\d{4}),?\s+(\d{2}):(\d{2})\s*$/

  @spec parse_date(String.t()) :: {:ok, Date.t()} | :error
  def parse_date(value) when is_binary(value) do
    case Regex.run(@date_re, value, capture: :all_but_first) do
      [day, month, year] ->
        case Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> :error
        end

      nil ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> :error
        end
    end
  end

  def parse_date(_value), do: :error

  @spec parse_datetime(String.t()) :: {:ok, NaiveDateTime.t()} | :error
  def parse_datetime(value) when is_binary(value) do
    case Regex.run(@datetime_re, value, capture: :all_but_first) do
      [day, month, year, hour, minute] ->
        [year, month, day, hour, minute]
        |> Enum.map(&String.to_integer/1)
        |> then(fn [year, month, day, hour, minute] ->
          NaiveDateTime.new(year, month, day, hour, minute, 0)
        end)
        |> case do
          {:ok, naive} -> {:ok, naive}
          {:error, _reason} -> :error
        end

      nil ->
        normalized = if String.length(value) == 16, do: value <> ":00", else: value

        case NaiveDateTime.from_iso8601(normalized) do
          {:ok, naive} -> {:ok, naive}
          {:error, _reason} -> :error
        end
    end
  end

  def parse_datetime(_value), do: :error

  @spec format_date(Date.t()) :: String.t()
  def format_date(%Date{} = date), do: Calendar.strftime(date, "%d.%m.%Y")

  @spec format_datetime(NaiveDateTime.t()) :: String.t()
  def format_datetime(%NaiveDateTime{} = naive), do: Calendar.strftime(naive, "%d.%m.%Y, %H:%M")
end
