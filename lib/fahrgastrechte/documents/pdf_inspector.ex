defmodule Fahrgastrechte.Documents.PDFInspector do
  @moduledoc false

  alias Fahrgastrechte.Documents.CommandRunner

  @type inspection :: %{required(:page_count) => pos_integer(), required(:encrypted) => boolean()}

  @spec inspect(Path.t()) :: {:ok, inspection()} | {:error, atom()}
  def inspect(path) do
    timeout = config(:command_timeout_ms)

    with {:ok, output} <- CommandRunner.run(config(:pdfinfo_executable), [path], timeout),
         {:ok, page_count} <- parse_positive_integer(output, ~r/^Pages:\s+(\d+)$/m),
         {:ok, encrypted} <- parse_encrypted(output),
         :ok <- validate_page_count(page_count) do
      {:ok, %{page_count: page_count, encrypted: encrypted}}
    else
      {:error, :timeout} -> {:error, :timeout}
      {:error, :too_many_pages} -> {:error, :too_many_pages}
      _error -> {:error, :invalid_pdf}
    end
  end

  defp parse_positive_integer(output, pattern) do
    case Regex.run(pattern, output, capture: :all_but_first) do
      [value] ->
        case Integer.parse(value) do
          {number, ""} when number > 0 -> {:ok, number}
          _other -> {:error, :invalid_metadata}
        end

      _other ->
        {:error, :invalid_metadata}
    end
  end

  defp parse_encrypted(output) do
    case Regex.run(~r/^Encrypted:\s+(yes|no)/m, output, capture: :all_but_first) do
      ["yes"] -> {:ok, true}
      ["no"] -> {:ok, false}
      _other -> {:error, :invalid_metadata}
    end
  end

  defp validate_page_count(page_count) do
    if page_count <= config(:max_page_count), do: :ok, else: {:error, :too_many_pages}
  end

  defp config(key) do
    :fahrgastrechte
    |> Application.fetch_env!(Fahrgastrechte.Documents)
    |> Keyword.fetch!(key)
  end
end
