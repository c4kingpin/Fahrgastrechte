defmodule Fahrgastrechte.Exports.Template do
  @moduledoc false

  @required_fields ~w(
    journey planned_day planned_month planned_year planned_direction
    planned_departure_station planned_departure_hours planned_departure_minutes
    planned_destination_station planned_destination_hours planned_destination_minutes
    arrived_day arrived_month arrived_year arrived_hours arrived_minutes
    ticket_digital ticket_digital_number compensation compensation_accountholder
    compensation_iban compensation_bic personal personal_firstname personal_lastname
    personal_street personal_housenumber personal_postcode personal_city date signature
  )

  @spec current() :: {:ok, map()} | {:error, :template_unavailable | :template_changed}
  def current do
    config = Application.fetch_env!(:fahrgastrechte, Fahrgastrechte.Exports)
    path = Keyword.fetch!(config, :template_path)
    expected_sha256 = Keyword.fetch!(config, :template_sha256)

    with true <- is_binary(path) and File.regular?(path),
         {:ok, sha256} <- sha256(path),
         true <- secure_compare(sha256, expected_sha256) do
      {:ok,
       %{
         path: path,
         version: Keyword.fetch!(config, :template_version),
         source: Keyword.fetch!(config, :template_source),
         sha256: sha256,
         required_fields: @required_fields
       }}
    else
      false ->
        if is_binary(path) and File.regular?(path),
          do: {:error, :template_changed},
          else: {:error, :template_unavailable}

      _error ->
        {:error, :template_unavailable}
    end
  end

  defp sha256(path) do
    digest =
      path
      |> File.stream!(64 * 1024, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    {:ok, digest}
  rescue
    _error -> {:error, :template_unavailable}
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_compare(_left, _right), do: false
end
