defmodule Fahrgastrechte.Documents.PDFJobLimiterTest do
  use ExUnit.Case, async: true

  alias Fahrgastrechte.Documents.PDFJobLimiter

  setup do
    name = :"pdf_job_limiter_#{System.unique_integer([:positive])}"
    start_supervised!({PDFJobLimiter, name: name, max_concurrency: 1})
    {:ok, name: name}
  end

  test "runs the callback and releases the permit afterwards", %{name: name} do
    assert PDFJobLimiter.with_permit(fn -> :ok end, name) == :ok

    # The permit from the first call was released, so a second call succeeds
    # immediately instead of waiting out the retry budget.
    started_at = System.monotonic_time(:millisecond)
    assert PDFJobLimiter.with_permit(fn -> :ok end, name) == :ok
    assert System.monotonic_time(:millisecond) - started_at < 100
  end

  test "reports :busy once concurrency is exhausted", %{name: name} do
    test_pid = self()

    holder =
      spawn(fn ->
        PDFJobLimiter.with_permit(
          fn ->
            send(test_pid, :holding)

            receive do
              :release -> :ok
            end
          end,
          name
        )
      end)

    assert_receive :holding

    assert {:error, :busy} = PDFJobLimiter.with_permit(fn -> :should_not_run end, name)

    send(holder, :release)
  end

  test "releases the permit when the holding process crashes", %{name: name} do
    test_pid = self()

    holder =
      spawn(fn ->
        PDFJobLimiter.with_permit(
          fn ->
            send(test_pid, :holding)
            Process.sleep(:infinity)
          end,
          name
        )
      end)

    assert_receive :holding
    Process.exit(holder, :kill)

    # Once the monitor observes the crash, the permit becomes available again.
    assert eventually(fn -> PDFJobLimiter.with_permit(fn -> :ok end, name) == :ok end)
  end

  defp eventually(check, attempts \\ 20)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(50)
      eventually(check, attempts - 1)
    end
  end
end
