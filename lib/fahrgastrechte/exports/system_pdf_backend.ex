defmodule Fahrgastrechte.Exports.SystemPDFBackend do
  @moduledoc """
  PDF backend for the isolated qpdf, pdftk-java and Poppler toolchain.
  """

  @behaviour Fahrgastrechte.Exports.PDFBackend

  alias Fahrgastrechte.Documents.CommandRunner

  @a4_width 595.28
  @a4_height 841.89
  @a4_tolerance 2.0

  @impl true
  def validate(path, options) do
    timeout = Keyword.fetch!(options, :timeout_ms)
    max_bytes = Keyword.fetch!(options, :max_bytes)
    max_pages = Keyword.fetch!(options, :max_pages)

    with {:ok, %File.Stat{type: :regular, size: size}} when size > 0 and size <= max_bytes <-
           File.stat(path),
         :ok <- validate_structure(path, options, timeout),
         {:ok, info} <- command_output(options, :pdfinfo, [path], timeout),
         {:ok, pages} <- parse_integer(info, ~r/^Pages:\s+(\d+)$/m),
         true <- pages <= max_pages,
         {:ok, encrypted} <- parse_encrypted(info),
         {:ok, page_sizes} <- page_sizes(path, pages, options, timeout),
         true <- Enum.all?(page_sizes, &a4?/1),
         :ok <- maybe_validate_inactive(path, options, timeout) do
      {:ok, %{pages: pages, bytes: size, page_sizes: page_sizes, encrypted: encrypted}}
    else
      {:ok, %File.Stat{size: size}} when size > max_bytes -> {:error, :resource_limit}
      false -> {:error, :resource_limit}
      {:error, :timeout} -> {:error, :timeout}
      {:error, :active_content} -> {:error, :invalid_pdf}
      {:error, {:command_failed, command}} -> {:error, {:command_failed, command}}
      _error -> {:error, :invalid_pdf}
    end
  end

  @impl true
  def fill_form(template_path, fields, output_path, options) do
    timeout = Keyword.fetch!(options, :timeout_ms)
    xfdf_path = output_path <> ".xfdf"
    normalized_template_path = output_path <> ".template.pdf"

    try do
      with :ok <-
             command(
               options,
               :qpdf,
               [template_path, normalized_template_path],
               timeout,
               [0, 3]
             ),
           {:ok, dump} <-
             command_output(
               options,
               :pdftk,
               [normalized_template_path, "dump_data_fields_utf8"],
               timeout
             ),
           :ok <- verify_fields(dump, Keyword.fetch!(options, :required_fields)),
           :ok <- File.write(xfdf_path, xfdf(fields), [:binary]),
           :ok <- File.chmod(xfdf_path, 0o600),
           :ok <-
             command(
               options,
               :pdftk,
               [
                 normalized_template_path,
                 "fill_form",
                 xfdf_path,
                 "output",
                 output_path,
                 "replacement_font",
                 Keyword.fetch!(options, :font_path)
               ],
               timeout
             ) do
        :ok
      else
        {:error, :missing_field} -> {:error, :missing_field}
        {:error, :timeout} -> {:error, :timeout}
        {:error, {:command_failed, command}} -> {:error, {:command_failed, command}}
        _error -> {:error, :invalid_pdf}
      end
    after
      File.rm(xfdf_path)
      File.rm(normalized_template_path)
    end
  end

  @impl true
  def normalize(input_path, output_path, options) do
    timeout = Keyword.fetch!(options, :timeout_ms)
    flattened_path = output_path <> ".flattened.pdf"

    try do
      with :ok <-
             command(
               options,
               :qpdf,
               [
                 input_path,
                 flattened_path,
                 "--generate-appearances",
                 "--flatten-annotations=all"
               ],
               timeout
             ),
           :ok <-
             command(options, :pdftocairo, ["-pdf", flattened_path, output_path], timeout) do
        :ok
      else
        {:error, :timeout} -> {:error, :timeout}
        {:error, {:command_failed, command}} -> {:error, {:command_failed, command}}
      end
    after
      File.rm(flattened_path)
    end
  end

  @impl true
  def merge(input_paths, output_path, options) do
    timeout = Keyword.fetch!(options, :timeout_ms)
    arguments = ["--empty", "--pages"] ++ input_paths ++ ["--", output_path]

    case command(options, :qpdf, arguments, timeout) do
      :ok -> :ok
      {:error, :timeout} -> {:error, :timeout}
      {:error, {:command_failed, command}} -> {:error, {:command_failed, command}}
    end
  end

  defp page_sizes(path, pages, options, timeout) do
    1..pages
    |> Enum.reduce_while({:ok, []}, fn page, {:ok, sizes} ->
      case command_output(
             options,
             :pdfinfo,
             ["-f", to_string(page), "-l", to_string(page), path],
             timeout
           ) do
        {:ok, output} ->
          case Regex.run(
                 ~r/^Page\s+(?:\d+\s+)?size:\s+([0-9.]+)\s+x\s+([0-9.]+)\s+pts/m,
                 output,
                 capture: :all_but_first
               ) ||
                 Regex.run(~r/^Page size:\s+([0-9.]+)\s+x\s+([0-9.]+)\s+pts/m, output,
                   capture: :all_but_first
                 ) do
            [width, height] ->
              with {:ok, width} <- parse_number(width),
                   {:ok, height} <- parse_number(height) do
                {:cont, {:ok, sizes ++ [{width, height}]}}
              else
                {:error, :invalid_number} -> {:halt, {:error, :invalid_pdf}}
              end

            _other ->
              {:halt, {:error, :invalid_pdf}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp a4?({width, height}) do
    (abs(width - @a4_width) <= @a4_tolerance and
       abs(height - @a4_height) <= @a4_tolerance) or
      (abs(height - @a4_width) <= @a4_tolerance and
         abs(width - @a4_height) <= @a4_tolerance)
  end

  defp maybe_validate_inactive(path, options, timeout) do
    if Keyword.get(options, :inactive, false) do
      qdf_path = path <> ".qdf"

      try do
        with :ok <-
               command(
                 options,
                 :qpdf,
                 ["--qdf", "--object-streams=disable", path, qdf_path],
                 timeout
               ),
             {:ok, content} <- File.read(qdf_path),
             false <- active_content?(content) do
          :ok
        else
          true -> {:error, :active_content}
          {:error, reason} -> {:error, reason}
        end
      after
        File.rm(qdf_path)
      end
    else
      :ok
    end
  end

  defp validate_structure(path, options, timeout) do
    if Keyword.get(options, :template, false) do
      normalized_path =
        Path.join(System.tmp_dir!(), "fahrgastrechte-template-check-#{Ecto.UUID.generate()}.pdf")

      try do
        command(options, :qpdf, [path, normalized_path], timeout, [0, 3])
      after
        File.rm(normalized_path)
      end
    else
      command(options, :qpdf, ["--check", path], timeout)
    end
  end

  defp active_content?(content) do
    Enum.any?(
      ["/AcroForm", "/JavaScript", "/OpenAction", "/EmbeddedFiles"],
      &(:binary.match(content, &1) != :nomatch)
    )
  end

  defp verify_fields(dump, required_fields) do
    available_fields =
      dump
      |> String.split("\n")
      |> Enum.flat_map(fn
        "FieldName: " <> field -> [String.trim(field)]
        _line -> []
      end)
      |> MapSet.new()

    if Enum.all?(required_fields, &MapSet.member?(available_fields, &1)),
      do: :ok,
      else: {:error, :missing_field}
  end

  defp xfdf(fields) do
    encoded_fields =
      Enum.map_join(fields, "\n", fn {name, value} ->
        ~s(    <field name="#{xml(name)}"><value>#{xml(value)}</value></field>)
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">
      <fields>
    #{encoded_fields}
      </fields>
    </xfdf>
    """
  end

  defp xml(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp parse_integer(output, pattern) do
    case Regex.run(pattern, output, capture: :all_but_first) do
      [value] ->
        case Integer.parse(value) do
          {number, ""} when number > 0 -> {:ok, number}
          _other -> {:error, :invalid_pdf}
        end

      _other ->
        {:error, :invalid_pdf}
    end
  end

  defp parse_number(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _other -> {:error, :invalid_number}
    end
  end

  defp parse_encrypted(output) do
    case Regex.run(~r/^Encrypted:\s+(yes|no)/m, output, capture: :all_but_first) do
      ["yes"] -> {:ok, true}
      ["no"] -> {:ok, false}
      _other -> {:error, :invalid_pdf}
    end
  end

  defp command(options, key, arguments, timeout, accepted_exit_codes \\ [0]) do
    executable = Keyword.fetch!(options, key)

    case CommandRunner.run(executable, arguments, timeout, accepted_exit_codes) do
      {:ok, _output} -> :ok
      {:error, :timeout} -> {:error, :timeout}
      {:error, :command_failed} -> {:error, {:command_failed, executable}}
    end
  end

  defp command_output(options, key, arguments, timeout) do
    executable = Keyword.fetch!(options, key)

    case CommandRunner.run(executable, arguments, timeout) do
      {:ok, output} -> {:ok, output}
      {:error, :timeout} -> {:error, :timeout}
      {:error, :command_failed} -> {:error, {:command_failed, executable}}
    end
  end
end
