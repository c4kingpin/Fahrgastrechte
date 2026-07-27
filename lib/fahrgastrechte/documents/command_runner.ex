defmodule Fahrgastrechte.Documents.CommandRunner do
  @moduledoc false

  @spec run(String.t(), [String.t()], pos_integer()) ::
          {:ok, String.t()} | {:error, :timeout | :command_failed}
  @spec run(String.t(), [String.t()], pos_integer(), [non_neg_integer()]) ::
          {:ok, String.t()} | {:error, :timeout | :command_failed}
  def run(executable, arguments, timeout_ms, accepted_exit_codes \\ [0]) do
    task =
      Task.Supervisor.async_nolink(Fahrgastrechte.ExternalCommandSupervisor, fn ->
        System.cmd(executable, arguments, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {output, status}} ->
        if status in accepted_exit_codes,
          do: {:ok, output},
          else: {:error, :command_failed}

      {:exit, _reason} ->
        {:error, :command_failed}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end
end
