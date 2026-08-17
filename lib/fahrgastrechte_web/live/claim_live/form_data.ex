defmodule FahrgastrechteWeb.ClaimLive.FormData do
  @moduledoc """
  HEEx form projections for the claim workspace view.

  Field names, defaults and `datetime-local` formatting for the workspace's
  journey and correction forms — kept out of `Fahrgastrechte.ClaimWorkspace`
  so the application layer stays free of UI-specific form shapes.
  """

  alias Fahrgastrechte.Claims.Claim
  alias Fahrgastrechte.Rail.BerlinTime

  def planned_form_data(claim, nil) do
    %{
      "origin_name" => claim.origin || "",
      "destination_name" => claim.destination || "",
      "train_category" => "",
      "train_number" => "",
      "scheduled_departure" => default_departure(claim),
      "scheduled_arrival" => "",
      "via_name" => "",
      "transfer_arrival" => "",
      "transfer_departure" => "",
      "second_category" => "",
      "second_number" => ""
    }
  end

  def planned_form_data(_claim, journey) do
    first = List.first(journey.segments)
    last = List.last(journey.segments)
    second = Enum.at(journey.segments, 1)

    %{
      "origin_name" => first.origin_name || "",
      "destination_name" => last.destination_name || "",
      "train_category" => first.train_category || "",
      "train_number" => first.train_number || "",
      "scheduled_departure" => datetime_local(first.scheduled_departure),
      "scheduled_arrival" => datetime_local(last.scheduled_arrival),
      "via_name" => if(second, do: first.destination_name || "", else: ""),
      "transfer_arrival" => if(second, do: datetime_local(first.scheduled_arrival), else: ""),
      "transfer_departure" =>
        if(second, do: datetime_local(second.scheduled_departure), else: ""),
      "second_category" => if(second, do: second.train_category || "", else: ""),
      "second_number" => if(second, do: second.train_number || "", else: "")
    }
  end

  def actual_form_data(claim, planned, nil) do
    planned_data = planned_form_data(claim, planned)

    Map.merge(planned_data, %{
      "actual_departure" => "",
      "actual_arrival" => "",
      "replacement_category" => "",
      "replacement_number" => "",
      "replacement_departure" => "",
      "replacement_arrival" => "",
      "missed_connection_category" => "",
      "missed_connection_number" => "",
      "missed_connection_departure" => "",
      "missed_connection_arrival" => ""
    })
  end

  def actual_form_data(%Claim{disruption_cause: :missed_connection} = claim, planned, journey)
      when not is_nil(journey) do
    first = List.first(journey.segments)
    onward = Enum.at(journey.segments, 1)

    claim
    |> actual_form_data(planned, nil)
    |> Map.put("origin_name", first.origin_name || claim.origin || "")
    |> Map.put("destination_name", first.destination_name || "")
    |> Map.put("train_category", first.train_category || "")
    |> Map.put("train_number", first.train_number || "")
    |> Map.put("scheduled_departure", datetime_local(first.scheduled_departure))
    |> Map.put("scheduled_arrival", datetime_local(first.scheduled_arrival))
    |> Map.put(
      "actual_departure",
      datetime_local(first.actual_departure || first.estimated_departure)
    )
    |> Map.put("actual_arrival", datetime_local(first.actual_arrival || first.estimated_arrival))
    |> maybe_put_missed_connection(onward)
  end

  def actual_form_data(claim, planned, journey) do
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

  defp maybe_put_missed_connection(data, nil), do: data

  defp maybe_put_missed_connection(data, onward) do
    data
    |> Map.put("missed_connection_category", onward.train_category || "")
    |> Map.put("missed_connection_number", onward.train_number || "")
    |> Map.put(
      "missed_connection_departure",
      datetime_local(onward.actual_departure || onward.scheduled_departure)
    )
    |> Map.put(
      "missed_connection_arrival",
      datetime_local(onward.actual_arrival || onward.scheduled_arrival)
    )
  end

  def connection_search_data(claim, planned) do
    planned_data = planned_form_data(claim, planned)

    %{
      "origin" => claim.origin || "",
      "destination" => claim.destination || "",
      "departure_at" => planned_data["scheduled_departure"],
      "train_number" => planned_data["train_number"]
    }
  end

  def suggestion_correction_data(claim) do
    %{
      "travel_date" => if(claim.travel_date, do: Date.to_iso8601(claim.travel_date), else: ""),
      "origin" => claim.origin || "",
      "destination" => claim.destination || ""
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
end
