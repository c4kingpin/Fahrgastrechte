defmodule Fahrgastrechte.Exports.FormManifest do
  @moduledoc false

  @required_keys ~w(
    source_url displayed_version sha256 required_fields radio_values intentionally_blank
  )

  @spec current() :: {:ok, map()} | {:error, :template_unavailable | :template_changed}
  def current do
    path =
      :fahrgastrechte
      |> Application.fetch_env!(Fahrgastrechte.Exports)
      |> Keyword.fetch!(:template_manifest_path)

    with true <- is_binary(path) and File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, manifest} <- Jason.decode(content),
         :ok <- validate(manifest),
         {:ok, sha256} <- Base.decode16(manifest["sha256"], case: :mixed) do
      {:ok,
       %{
         source: manifest["source_url"],
         version: manifest["displayed_version"],
         sha256: sha256,
         required_fields: manifest["required_fields"],
         radio_values: manifest["radio_values"],
         intentionally_blank: manifest["intentionally_blank"]
       }}
    else
      false -> {:error, :template_unavailable}
      {:error, :enoent} -> {:error, :template_unavailable}
      _error -> {:error, :template_changed}
    end
  end

  defp validate(manifest) when is_map(manifest) do
    valid? =
      Enum.all?(@required_keys, &Map.has_key?(manifest, &1)) and
        is_binary(manifest["source_url"]) and
        is_binary(manifest["displayed_version"]) and
        is_binary(manifest["sha256"]) and
        string_list?(manifest["required_fields"]) and
        radio_values?(manifest["radio_values"]) and
        string_list?(manifest["intentionally_blank"])

    if valid?, do: :ok, else: {:error, :invalid_manifest}
  end

  defp validate(_manifest), do: {:error, :invalid_manifest}

  defp radio_values?(values) when is_map(values) do
    Enum.all?(values, fn {field, options} -> is_binary(field) and string_list?(options) end)
  end

  defp radio_values?(_values), do: false

  defp string_list?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp string_list?(_values), do: false
end
