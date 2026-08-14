defmodule Fahrgastrechte.Exports.Template do
  @moduledoc false

  alias Fahrgastrechte.Exports.FormManifest
  alias Fahrgastrechte.ReferenceData

  @spec current() :: {:ok, map()} | {:error, :template_unavailable | :template_changed}
  def current do
    case ReferenceData.current_file(:official_form) do
      {:ok, managed} -> current_managed(managed)
      {:error, :not_found} -> current_configured()
      {:error, :storage_unavailable} -> {:error, :template_unavailable}
    end
  end

  defp current_managed(%{version: version, path: path}) do
    with true <- File.regular?(path),
         {:ok, sha256} <- sha256(path),
         true <- secure_compare(sha256, version.sha256),
         {:ok, template} <- managed_template(version, path, sha256) do
      {:ok, template}
    else
      false ->
        if File.regular?(path),
          do: {:error, :template_changed},
          else: {:error, :template_unavailable}

      _error ->
        {:error, :template_changed}
    end
  end

  defp current_configured do
    config = Application.fetch_env!(:fahrgastrechte, Fahrgastrechte.Exports)
    path = Keyword.fetch!(config, :template_path)
    expected_sha256 = Keyword.fetch!(config, :template_sha256)

    with {:ok, manifest} <- FormManifest.current(),
         :ok <- validate_config(manifest, config),
         true <- is_binary(path) and File.regular?(path),
         {:ok, sha256} <- sha256(path),
         true <- secure_compare(sha256, expected_sha256) do
      {:ok,
       manifest
       |> Map.put(:path, path)
       |> Map.put(:sha256, sha256)}
    else
      {:error, reason} when reason in [:template_unavailable, :template_changed] ->
        {:error, reason}

      {:error, :config_mismatch} ->
        {:error, :template_changed}

      false ->
        if is_binary(path) and File.regular?(path),
          do: {:error, :template_changed},
          else: {:error, :template_unavailable}

      _error ->
        {:error, :template_unavailable}
    end
  end

  defp managed_template(version, path, sha256) do
    metadata = version.metadata
    required_fields = metadata["required_fields"]
    radio_values = metadata["radio_values"]
    intentionally_blank = metadata["intentionally_blank"]

    if string_list?(required_fields) and radio_values?(radio_values) and
         string_list?(intentionally_blank) and is_binary(version.source_url) do
      {:ok,
       %{
         source: version.source_url,
         version: version.version,
         sha256: sha256,
         path: path,
         required_fields: required_fields,
         radio_values: radio_values,
         intentionally_blank: intentionally_blank
       }}
    else
      {:error, :invalid_metadata}
    end
  end

  @spec validate_form_fields(map(), [{String.t(), String.t()}]) ::
          :ok | {:error, :template_changed}
  def validate_form_fields(template, fields) when is_map(template) and is_list(fields) do
    field_map = Map.new(fields)
    provided = Map.keys(field_map) |> MapSet.new()
    allowed = MapSet.new(template.required_fields)
    blank = MapSet.new(template.intentionally_blank)

    radio_values_valid? =
      Enum.all?(template.radio_values, fn {field, values} ->
        case Map.fetch(field_map, field) do
          {:ok, value} -> value in values
          :error -> false
        end
      end)

    if MapSet.subset?(provided, allowed) and MapSet.disjoint?(provided, blank) and
         radio_values_valid? do
      :ok
    else
      {:error, :template_changed}
    end
  end

  defp validate_config(manifest, config) do
    expected_sha256 = Keyword.fetch!(config, :template_sha256)

    if manifest.version == Keyword.fetch!(config, :template_version) and
         manifest.source == Keyword.fetch!(config, :template_source) and
         secure_compare(manifest.sha256, expected_sha256) do
      :ok
    else
      {:error, :config_mismatch}
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

  defp radio_values?(values) when is_map(values) do
    Enum.all?(values, fn {field, options} -> is_binary(field) and string_list?(options) end)
  end

  defp radio_values?(_values), do: false

  defp string_list?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp string_list?(_values), do: false
end
