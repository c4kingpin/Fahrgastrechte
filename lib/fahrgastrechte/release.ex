defmodule Fahrgastrechte.Release do
  @moduledoc false

  @app :fahrgastrechte

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Rewrites all stored bank data with the currently active encryption key.

  Run after rotating `FIELD_ENCRYPTION_KEY` and bumping
  `FIELD_ENCRYPTION_KEY_VERSION`, with the previous key still listed in
  `FIELD_ENCRYPTION_KEYS`. Once it reports success, the retired key may be
  removed from the environment.
  """
  def rekey_bank_data do
    load_app()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(Fahrgastrechte.Repo, fn _repo ->
        Fahrgastrechte.Accounts.rekey_bank_data()
      end)

    case result do
      {:ok, counts} ->
        IO.puts("Bankdaten neu verschlüsselt: #{counts.rekeyed}, übersprungen: #{counts.skipped}")

        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Neuverschlüsselung fehlgeschlagen: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
