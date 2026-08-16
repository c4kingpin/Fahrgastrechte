defmodule Fahrgastrechte.ReferenceData do
  @moduledoc """
  Versioned, installation-wide official form and railway archive sources.

  Uploaded files are validated before an immutable copy is stored. Activating a
  new version is transactional; older versions stay available for audit and for
  exports that already recorded their source metadata.

  These sources are operational data for the whole installation, so every
  authenticated user may replace them — the functions here deliberately check
  that a user is signed in, not which one. An installation is one trust zone;
  see `docs/decisions/0005-installation-trust-zone.md` for the reasoning and
  its limits. User-owned data is scoped as strictly as everywhere else.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Documents.LocalStorage
  alias Fahrgastrechte.Exports.FormManifest
  alias Fahrgastrechte.Rail.Providers.BahnVorhersageArchive
  alias Fahrgastrechte.ReferenceData.Version
  alias Fahrgastrechte.Repo

  @type domain_error ::
          :not_authenticated
          | :not_found
          | :invalid_pdf
          | :encrypted
          | :missing_field
          | :invalid_archive
          | :file_too_large
          | :resource_limit
          | :storage_unavailable
          | :timeout
          | {:command_failed, String.t()}
          | {:upstream, term()}

  @doc "Lists all stored versions of one data-source kind, newest first."
  @spec list_versions(Scope.t(), Version.kind()) ::
          {:ok, [Version.t()]} | {:error, domain_error()}
  def list_versions(%Scope{user: %User{}}, kind)
      when kind in [:official_form, :bahn_vorhersage_archive] do
    {:ok,
     Repo.all(
       from version in Version,
         where: version.kind == ^kind,
         order_by: [desc: version.inserted_at, desc: version.id]
     )}
  end

  def list_versions(_scope, _kind), do: {:error, :not_authenticated}

  @doc "Returns the active managed version and its private local path."
  @spec current_file(Version.kind()) ::
          {:ok, %{version: Version.t(), path: Path.t()}}
          | {:error, :not_found | :storage_unavailable}
  def current_file(kind) when kind in [:official_form, :bahn_vorhersage_archive] do
    case Repo.one(from version in Version, where: version.kind == ^kind and version.current) do
      %Version{} = version ->
        case LocalStorage.with_path(version.storage_key, fn path ->
               {:ok, %{version: version, path: path}}
             end) do
          {:error, :not_found} -> {:error, :storage_unavailable}
          result -> result
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Validates and activates a structurally compatible official PDF form."
  @spec replace_official_form(Scope.t(), Path.t(), map()) ::
          {:ok, Version.t()} | {:error, Changeset.t() | domain_error()}
  def replace_official_form(
        %Scope{user: %User{id: user_id}},
        source_path,
        attrs
      )
      when is_binary(source_path) and is_map(attrs) do
    normalized = normalize_attrs(attrs)

    with :ok <- validate_version_attrs(:official_form, normalized),
         :ok <- validate_source_file(source_path, config(:max_form_size_bytes)),
         {:ok, metadata} <- validate_official_form(source_path),
         {:ok, stored} <- LocalStorage.put(source_path, config(:max_form_size_bytes)) do
      persist_version(user_id, :official_form, normalized, stored, metadata)
    end
  end

  def replace_official_form(_scope, _source_path, _attrs),
    do: {:error, :not_authenticated}

  @doc "Validates and activates a Bahn-Vorhersage CSV projection."
  @spec replace_bahn_archive(Scope.t(), Path.t(), map()) ::
          {:ok, Version.t()} | {:error, Changeset.t() | domain_error()}
  def replace_bahn_archive(
        %Scope{user: %User{id: user_id}},
        source_path,
        attrs
      )
      when is_binary(source_path) and is_map(attrs) do
    normalized = normalize_attrs(attrs)

    with :ok <- validate_version_attrs(:bahn_vorhersage_archive, normalized),
         :ok <- validate_source_file(source_path, config(:max_archive_size_bytes)),
         {:ok, archive_metadata} <-
           BahnVorhersageArchive.validate_archive(source_path,
             dataset_version: normalized.version,
             source_name: normalized.original_filename
           ),
         {:ok, stored} <- LocalStorage.put(source_path, config(:max_archive_size_bytes)) do
      persist_version(
        user_id,
        :bahn_vorhersage_archive,
        normalized,
        stored,
        stringify_metadata(archive_metadata)
      )
    else
      {:error, :history_unavailable} -> {:error, :invalid_archive}
      {:error, {:upstream, :invalid_archive_projection}} -> {:error, :invalid_archive}
      {:error, reason} -> {:error, reason}
    end
  end

  def replace_bahn_archive(_scope, _source_path, _attrs),
    do: {:error, :not_authenticated}

  defp validate_official_form(path) do
    config = Application.fetch_env!(:fahrgastrechte, Fahrgastrechte.Exports)
    backend = Keyword.fetch!(config, :backend)
    options = pdf_backend_options(config)

    with {:ok, manifest} <- FormManifest.current(),
         {:ok, info} <- backend.validate(path, Keyword.put(options, :template, true)),
         false <- info.encrypted,
         :ok <- backend.validate_template(path, manifest, options) do
      {:ok,
       %{
         "pages" => info.pages,
         "required_fields" => manifest.required_fields,
         "radio_values" => manifest.radio_values,
         "intentionally_blank" => manifest.intentionally_blank
       }}
    else
      true -> {:error, :encrypted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_version(user_id, kind, attrs, stored, metadata) do
    version_attrs = %{
      kind: kind,
      version: attrs.version,
      source_url: attrs.source_url,
      original_filename: attrs.original_filename,
      storage_key: stored.storage_key,
      size_bytes: stored.size_bytes,
      sha256: stored.sha256,
      metadata: metadata,
      current: true
    }

    changeset =
      %Version{uploaded_by_user_id: user_id}
      |> Version.create_changeset(version_attrs)

    result =
      Multi.new()
      |> Multi.update_all(
        :retire_previous,
        from(version in Version, where: version.kind == ^kind and version.current),
        set: [current: false]
      )
      |> Multi.insert(:version, changeset)
      |> Repo.transaction()

    case result do
      {:ok, %{version: version}} ->
        {:ok, version}

      {:error, :version, reason, _changes} ->
        _ = LocalStorage.delete(stored.storage_key)
        {:error, reason}

      {:error, _step, _reason, _changes} ->
        _ = LocalStorage.delete(stored.storage_key)
        {:error, :storage_unavailable}
    end
  end

  defp validate_version_attrs(kind, attrs) do
    source_required? = kind == :official_form

    cond do
      attrs.version == "" or byte_size(attrs.version) > 120 ->
        {:error, invalid_changeset(kind, attrs, :version, "muss angegeben werden")}

      attrs.original_filename == "" or byte_size(attrs.original_filename) > 255 ->
        {:error, invalid_changeset(kind, attrs, :original_filename, "ist ungültig")}

      source_required? and is_nil(attrs.source_url) ->
        {:error, invalid_changeset(kind, attrs, :source_url, "muss angegeben werden")}

      is_binary(attrs.source_url) and not valid_https_url?(attrs.source_url) ->
        {:error,
         invalid_changeset(kind, attrs, :source_url, "muss eine gültige HTTPS-Adresse sein")}

      true ->
        :ok
    end
  end

  defp invalid_changeset(kind, attrs, field, message) do
    %Version{kind: kind}
    |> Version.create_changeset(%{
      version: attrs.version,
      source_url: attrs.source_url,
      original_filename: attrs.original_filename
    })
    |> Changeset.add_error(field, message)
  end

  defp normalize_attrs(attrs) do
    version = attrs |> value(:version) |> normalize_optional()
    source_url = attrs |> value(:source_url) |> normalize_optional()
    original_filename = attrs |> value(:original_filename) |> to_string() |> Path.basename()

    %{
      version: version || "",
      source_url: source_url,
      original_filename: original_filename
    }
  end

  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) || ""

  defp normalize_optional(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional(_value), do: nil

  defp valid_https_url?(value) do
    uri = URI.parse(value)

    uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo) and
      is_nil(uri.fragment)
  end

  defp validate_source_file(path, max_size_bytes) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 and size <= max_size_bytes ->
        :ok

      {:ok, %File.Stat{size: size}} when size > max_size_bytes ->
        {:error, :file_too_large}

      _error ->
        {:error, :storage_unavailable}
    end
  end

  defp stringify_metadata(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
  end

  defp pdf_backend_options(config) do
    [
      timeout_ms: Keyword.fetch!(config, :command_timeout_ms),
      max_bytes: config(:max_form_size_bytes),
      max_pages: Keyword.fetch!(config, :max_page_count),
      qpdf: Keyword.fetch!(config, :qpdf_executable),
      pdfinfo: Keyword.fetch!(config, :pdfinfo_executable),
      pdftk: Keyword.fetch!(config, :pdftk_executable),
      pdftocairo: Keyword.fetch!(config, :pdftocairo_executable),
      font_path: Keyword.fetch!(config, :font_path)
    ]
  end

  defp config(key) do
    :fahrgastrechte
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(key)
  end
end
