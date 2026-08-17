defmodule Fahrgastrechte.CommandRunnerTest do
  use ExUnit.Case, async: true

  alias Fahrgastrechte.Documents.CommandRunner

  test "returns the output of a successful command" do
    assert {:ok, output} = CommandRunner.run("echo", ["fahrgastrechte"], 5_000)
    assert String.trim(output) == "fahrgastrechte"
  end

  test "reports a non-zero exit status as a failed command" do
    assert {:error, :command_failed} = CommandRunner.run("false", [], 5_000)
  end

  test "accepts the additional exit codes a caller allows" do
    assert {:error, :command_failed} = CommandRunner.run("sh", ["-c", "exit 3"], 5_000)
    assert {:ok, _output} = CommandRunner.run("sh", ["-c", "exit 3"], 5_000, [0, 3])
  end

  test "terminates a command that exceeds its timeout" do
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :timeout} = CommandRunner.run("sleep", ["30"], 300)

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed < 5_000, "expected the command to be cut short, took #{elapsed}ms"
  end

  describe "ensure_timeout_tool!/0" do
    test "succeeds when the configured timeout binary is available" do
      assert :ok = CommandRunner.ensure_timeout_tool!()
    end

    test "raises when the configured timeout binary is unavailable" do
      original = Application.get_env(:fahrgastrechte, CommandRunner, [])

      Application.put_env(
        :fahrgastrechte,
        CommandRunner,
        Keyword.put(original, :timeout_executable, "definitely-not-a-real-binary")
      )

      on_exit(fn -> Application.put_env(:fahrgastrechte, CommandRunner, original) end)

      assert_raise RuntimeError, ~r/required external command missing/, fn ->
        CommandRunner.ensure_timeout_tool!()
      end
    end
  end

  @tag :external_process
  test "leaves no operating system process behind after a timeout" do
    marker = "fahrgastrechte-timeout-#{System.unique_integer([:positive])}"

    # The marker only exists so the descendant can be found again; `timeout`
    # signals the whole process group, so the inner sleep must be gone too.
    assert {:error, :timeout} =
             CommandRunner.run("sh", ["-c", "sleep 30 # #{marker}"], 300)

    assert running_processes(marker) == [],
           "a descendant of the timed out command is still running"
  end

  defp running_processes(marker) do
    case System.find_executable("pgrep") do
      nil ->
        []

      pgrep ->
        # Give the signal a moment to take effect before looking.
        Process.sleep(200)

        case System.cmd(pgrep, ["-f", marker], stderr_to_stdout: true) do
          {output, 0} -> output |> String.split("\n", trim: true)
          {_output, _status} -> []
        end
    end
  end
end
