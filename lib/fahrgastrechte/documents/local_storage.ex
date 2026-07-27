defmodule Fahrgastrechte.Documents.LocalStorage do
  @moduledoc false

  @chunk_size 64 * 1024
  @storage_key_pattern ~r/\A[0-9a-f]{64}\z/

  @type stored_file :: %{
          required(:storage_key) => String.t(),
          required(:size_bytes) => pos_integer(),
          required(:sha256) => binary()
        }

  @spec put(Path.t(), pos_integer()) :: {:ok, stored_file()} | {:error, atom()}
  def put(source_path, max_size_bytes) when is_binary(source_path) do
    with :ok <- ensure_ready(),
         {:ok, %File.Stat{type: :regular, size: size}} when size > 0 <- File.stat(source_path),
         :ok <- validate_size(size, max_size_bytes),
         {:ok, stored} <- copy_atomically(source_path, size) do
      {:ok, stored}
    else
      {:ok, %File.Stat{}} -> {:error, :invalid_file}
      {:error, :enoent} -> {:error, :invalid_file}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete(String.t()) :: :ok | {:error, atom()}
  def delete(storage_key) do
    with {:ok, path} <- storage_path(storage_key) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _reason} -> {:error, :storage_unavailable}
      end
    end
  end

  @spec stream(String.t(), pos_integer()) :: {:ok, Enumerable.t()} | {:error, atom()}
  def stream(storage_key, chunk_size \\ @chunk_size) do
    with {:ok, path} <- storage_path(storage_key),
         {:ok, %File.Stat{type: :regular}} <- File.stat(path) do
      stream =
        Stream.resource(
          fn -> File.open!(path, [:read, :binary]) end,
          fn file ->
            case IO.binread(file, chunk_size) do
              :eof ->
                {:halt, file}

              {:error, reason} ->
                raise File.Error, reason: reason, action: "stream", path: "document"

              data ->
                {[data], file}
            end
          end,
          &File.close/1
        )

      {:ok, stream}
    else
      _error -> {:error, :not_found}
    end
  end

  @spec with_path(String.t(), (Path.t() -> result)) :: result | {:error, atom()}
        when result: term()
  def with_path(storage_key, callback) when is_function(callback, 1) do
    with {:ok, path} <- storage_path(storage_key),
         {:ok, %File.Stat{type: :regular}} <- File.stat(path) do
      callback.(path)
    else
      _error -> {:error, :not_found}
    end
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(storage_key) do
    case storage_path(storage_key) do
      {:ok, path} -> File.regular?(path)
      {:error, _reason} -> false
    end
  end

  defp copy_atomically(source_path, size) do
    storage_key = random_storage_key()
    directory = Path.join(root_path(), binary_part(storage_key, 0, 2))
    final_path = Path.join(directory, storage_key)
    temporary_path = final_path <> ".tmp"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.cp(source_path, temporary_path),
         :ok <- File.chmod(temporary_path, 0o600),
         {:ok, %File.Stat{type: :regular, size: ^size}} <- File.stat(temporary_path),
         {:ok, sha256} <- sha256(temporary_path),
         :ok <- File.rename(temporary_path, final_path) do
      {:ok, %{storage_key: storage_key, size_bytes: size, sha256: sha256}}
    else
      _error ->
        _ = File.rm(temporary_path)
        {:error, :storage_unavailable}
    end
  end

  defp sha256(path) do
    digest =
      path
      |> File.stream!(@chunk_size, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    {:ok, digest}
  rescue
    _error -> {:error, :storage_unavailable}
  end

  defp ensure_ready do
    with :ok <- File.mkdir_p(root_path()),
         :ok <- File.chmod(root_path(), 0o700) do
      :ok
    else
      _error -> {:error, :storage_unavailable}
    end
  end

  defp storage_path(storage_key) when is_binary(storage_key) do
    if Regex.match?(@storage_key_pattern, storage_key) do
      {:ok,
       root_path()
       |> Path.join(binary_part(storage_key, 0, 2))
       |> Path.join(storage_key)}
    else
      {:error, :invalid_storage_key}
    end
  end

  defp storage_path(_storage_key), do: {:error, :invalid_storage_key}

  defp validate_size(size, max_size_bytes) when size <= max_size_bytes, do: :ok
  defp validate_size(_size, _max_size_bytes), do: {:error, :file_too_large}

  defp random_storage_key do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp root_path do
    :fahrgastrechte
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:path)
  end
end
