defmodule Fahrgastrechte.Rail.BerlinTime do
  @moduledoc """
  Converts railway timestamps between UTC and German civil time.

  Germany has used the current EU daylight-saving transition rule since 1996:
  clocks move forward on the last Sunday in March and back on the last Sunday
  in October. Railway data remains stored as UTC; only form and UI boundaries
  use `Europe/Berlin`.
  """

  @time_zone "Europe/Berlin"
  @standard_offset_seconds 3_600
  @daylight_offset_seconds 7_200

  @type local_time_error :: :nonexistent_local_time | :ambiguous_local_time

  @spec to_local(DateTime.t()) :: DateTime.t()
  def to_local(%DateTime{} = datetime) do
    utc = datetime |> DateTime.to_unix(:microsecond) |> DateTime.from_unix!(:microsecond)
    daylight? = daylight_at_utc?(utc)
    total_offset = if daylight?, do: @daylight_offset_seconds, else: @standard_offset_seconds

    local_naive =
      utc
      |> DateTime.to_naive()
      |> NaiveDateTime.add(total_offset, :second)

    local_as_utc = DateTime.from_naive!(local_naive, "Etc/UTC")

    %{
      local_as_utc
      | time_zone: @time_zone,
        zone_abbr: if(daylight?, do: "CEST", else: "CET"),
        utc_offset: @standard_offset_seconds,
        std_offset: if(daylight?, do: @standard_offset_seconds, else: 0)
    }
  end

  @spec to_local_naive(DateTime.t()) :: NaiveDateTime.t()
  def to_local_naive(%DateTime{} = datetime) do
    datetime
    |> to_local()
    |> DateTime.to_naive()
  end

  @spec from_local(NaiveDateTime.t()) :: {:ok, DateTime.t()} | {:error, local_time_error()}
  def from_local(%NaiveDateTime{} = local) do
    case local_offset(local) do
      {:ok, offset} ->
        utc =
          local
          |> NaiveDateTime.add(-offset, :second)
          |> DateTime.from_naive!("Etc/UTC")

        {:ok, utc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp daylight_at_utc?(utc) do
    year = utc.year
    starts_at = transition_utc(year, 3)
    ends_at = transition_utc(year, 10)

    DateTime.compare(utc, starts_at) in [:eq, :gt] and
      DateTime.compare(utc, ends_at) == :lt
  end

  defp local_offset(local) do
    start_date = last_sunday(local.year, 3)
    end_date = last_sunday(local.year, 10)
    date = NaiveDateTime.to_date(local)
    time = NaiveDateTime.to_time(local)

    cond do
      Date.compare(date, start_date) == :lt ->
        {:ok, @standard_offset_seconds}

      Date.compare(date, start_date) == :eq and Time.compare(time, ~T[02:00:00]) == :lt ->
        {:ok, @standard_offset_seconds}

      Date.compare(date, start_date) == :eq and Time.compare(time, ~T[03:00:00]) == :lt ->
        {:error, :nonexistent_local_time}

      Date.compare(date, end_date) == :lt ->
        {:ok, @daylight_offset_seconds}

      Date.compare(date, end_date) == :eq and Time.compare(time, ~T[02:00:00]) == :lt ->
        {:ok, @daylight_offset_seconds}

      Date.compare(date, end_date) == :eq and Time.compare(time, ~T[03:00:00]) == :lt ->
        {:error, :ambiguous_local_time}

      true ->
        {:ok, @standard_offset_seconds}
    end
  end

  defp transition_utc(year, month) do
    year
    |> last_sunday(month)
    |> DateTime.new!(~T[01:00:00], "Etc/UTC")
  end

  defp last_sunday(year, month) do
    first_date = Date.new!(year, month, 1)
    last_date = Date.new!(year, month, Date.days_in_month(first_date))
    Date.add(last_date, -rem(Date.day_of_week(last_date), 7))
  end
end
