defmodule Fahrgastrechte.Documents.CommandRunner do
  @moduledoc false

  require Logger

  # `Task.shutdown(:brutal_kill)` only tears down the BEAM-side task; closing the
  # port does not reliably terminate the operating system process behind it, so a
  # PDF that sends qpdf or pdftk into a long loop would leave one running process
  # per attempt. The command is therefore wrapped in coreutils `timeout`, which
  # signals the whole process group and outlives the BEAM task.
  @timeout_exit_status 124
  @killed_exit_status 137
  @kill_grace_seconds 5
  # The operating system timeout has to fire first; the BEAM task only remains as
  # a backstop for the case where `timeout` itself never returns.
  @backstop_ms 2_000

  @spec run(String.t(), [String.t()], pos_integer()) ::
          {:ok, String.t()} | {:error, :timeout | :command_failed}
  @spec run(String.t(), [String.t()], pos_integer(), [non_neg_integer()]) ::
          {:ok, String.t()} | {:error, :timeout | :command_failed}
  def run(executable, arguments, timeout_ms, accepted_exit_codes \\ [0]) do
    {command, command_arguments} = wrap(executable, arguments, timeout_ms)

    task =
      Task.Supervisor.async_nolink(Fahrgastrechte.ExternalCommandSupervisor, fn ->
        System.cmd(command, command_arguments, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms + @backstop_ms) do
      {:ok, {_output, status}} when status in [@timeout_exit_status, @killed_exit_status] ->
        # 137 is also what an out-of-memory kill produces. Both mean the command
        # was stopped from outside after exhausting a resource limit, which is
        # what the caller needs to know.
        {:error, :timeout}

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

  defp wrap(executable, arguments, timeout_ms) do
    case timeout_executable() do
      nil ->
        {executable, arguments}

      timeout_command ->
        {timeout_command,
         [
           "--kill-after=#{@kill_grace_seconds}s",
           seconds(timeout_ms),
           executable | arguments
         ]}
    end
  end

  @doc """
  Fails fast when the OS-level `timeout` wrapper this module depends on to
  bound external PDF-processing commands is unavailable. Called only in
  `:prod` (see `Fahrgastrechte.Application`) — without it, `run/4` still
  works in dev/test but loses its OS-level cutoff (see moduledoc).
  """
  @spec ensure_timeout_tool!() :: :ok
  def ensure_timeout_tool! do
    if is_nil(timeout_executable()) do
      raise "required external command missing: #{configured_timeout_name()}"
    end

    :ok
  end

  defp seconds(timeout_ms), do: :erlang.float_to_binary(timeout_ms / 1000, decimals: 3)

  defp timeout_executable do
    case System.find_executable(configured_timeout_name()) do
      nil ->
        Logger.warning(
          "#{configured_timeout_name()} is unavailable; external commands cannot be terminated reliably"
        )

        nil

      path ->
        path
    end
  end

  defp configured_timeout_name do
    :fahrgastrechte
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:timeout_executable, "timeout")
  end
end
