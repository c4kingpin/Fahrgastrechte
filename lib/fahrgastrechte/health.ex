defmodule Fahrgastrechte.Health do
  @moduledoc """
  Small runtime checks for deployment health probes.

  Liveness deliberately does not depend on external services. Readiness verifies
  that both durable stores required for accepting user traffic are usable.
  """

  alias Fahrgastrechte.Documents.LocalStorage
  alias Fahrgastrechte.Repo

  @type check :: :database | :document_storage

  @spec ready() :: :ok | {:error, [check()]}
  def ready do
    failures =
      [
        database: &database_ready?/0,
        document_storage: &document_storage_ready?/0
      ]
      |> Enum.reject(fn {_name, check} -> check.() == :ok end)
      |> Enum.map(&elem(&1, 0))

    if failures == [], do: :ok, else: {:error, failures}
  end

  defp database_ready? do
    case Repo.query("SELECT 1", [], timeout: 2_000, log: false) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp document_storage_ready? do
    path =
      :fahrgastrechte
      |> Application.fetch_env!(LocalStorage)
      |> Keyword.fetch!(:path)

    probe_path =
      Path.join(path, ".readiness-#{System.unique_integer([:positive, :monotonic])}")

    with :ok <- File.mkdir_p(path),
         :ok <- File.write(probe_path, "ready\n", [:binary, :exclusive]),
         :ok <- File.rm(probe_path) do
      :ok
    else
      _error ->
        File.rm(probe_path)
        :error
    end
  rescue
    _error -> :error
  end
end
