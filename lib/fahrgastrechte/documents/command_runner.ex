defmodule Fahrgastrechte.Documents.CommandRunner do
  @moduledoc false

  @spec run(String.t(), [String.t()], pos_integer()) ::
          {:ok, String.t()} | {:error, :timeout | :command_failed}
  def run(executable, arguments, timeout_ms) do
    task =
      Task.Supervisor.async_nolink(Fahrgastrechte.ExternalCommandSupervisor, fn ->
        System.cmd(executable, arguments, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {_output, _status}} ->
        {:error, :command_failed}

      {:exit, _reason} ->
        {:error, :command_failed}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end
end
