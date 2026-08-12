defmodule Fahrgastrechte.TestPDFBackend do
  @moduledoc false

  @behaviour Fahrgastrechte.Exports.PDFBackend

  @impl true
  def validate(path, _options) do
    with :ok <- maybe_fail(:validate),
         {output, 0} <- System.cmd("pdfinfo", [path], stderr_to_stdout: true),
         [pages] <- Regex.run(~r/^Pages:\s+(\d+)$/m, output, capture: :all_but_first),
         {pages, ""} <- Integer.parse(pages) do
      {:ok,
       %{
         pages: pages,
         bytes: File.stat!(path).size,
         page_sizes: List.duplicate({595.28, 841.89}, pages),
         encrypted: false
       }}
    else
      {:error, reason} -> {:error, reason}
      _error -> {:error, :invalid_pdf}
    end
  end

  @impl true
  def fill_form(template_path, fields, output_path, _options) do
    notify({:pdf_backend_fields, fields})

    with :ok <- maybe_fail(:fill_form),
         :ok <- File.cp(template_path, output_path) do
      :ok
    end
  end

  @impl true
  def normalize(input_path, output_path, _options) do
    with :ok <- maybe_fail(:normalize),
         :ok <- File.cp(input_path, output_path) do
      :ok
    end
  end

  @impl true
  def merge(input_paths, output_path, _options) do
    with :ok <- maybe_fail(:merge),
         {_output, 0} <-
           System.cmd("pdfunite", input_paths ++ [output_path], stderr_to_stdout: true) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _error -> {:error, {:command_failed, "pdfunite"}}
    end
  end

  defp maybe_fail(step) do
    if config(:fail_on) == step, do: {:error, {:command_failed, Atom.to_string(step)}}, else: :ok
  end

  defp notify(message) do
    case config(:test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end

  defp config(key) do
    :fahrgastrechte
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
  end
end
