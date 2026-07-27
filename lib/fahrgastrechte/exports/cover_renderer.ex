defmodule Fahrgastrechte.Exports.CoverRenderer do
  @moduledoc false

  @spec render(map(), Path.t()) :: :ok | {:error, :render_failed}
  def render(model, output_path) do
    content = model |> cover_lines() |> content_stream()
    pdf = build_pdf(content)

    with :ok <- File.write(output_path, pdf, [:binary]),
         :ok <- File.chmod(output_path, 0o600) do
      :ok
    else
      _error -> {:error, :render_failed}
    end
  rescue
    _error -> {:error, :render_failed}
  end

  defp cover_lines(model) do
    profile = model.profile

    [
      {54, 792, 9, "Absender"},
      {54, 777, 11, full_name(profile)},
      {54, 762, 10, "#{profile.street} #{profile.house_number}"},
      {54, 747, 10, "#{profile.postal_code} #{profile.city}"},
      {54, 732, 10, profile.country},
      {160, 590, 12, "DB Fernverkehr AG"},
      {160, 572, 12, "Servicecenter Fahrgastrechte"},
      {160, 554, 12, "60647 Frankfurt am Main"},
      {54, 465, 11, "Antragsnummer: #{model.claim.claim_number}"},
      {54, 430, 15, "Fahrgastrechte-Antrag"},
      {54, 407, 11, "#{model.claim.origin} - #{model.claim.destination}"},
      {54, 388, 11, "Reisedatum: #{format_date(model.claim.travel_date)}"},
      {54, 340, 11, disruption_line(model)},
      {54, 310, 11, "Anlagen:"},
      {72, 290, 10, "1. Fahrgastrechteformular"},
      {72, 274, 10, "2. Ticket"},
      {72, 258, 10, "3. DB-Rechnung"},
      {54, 210, 10, "Hinweis: Das Unterschriftsfeld im Formular ist vor dem Versand"},
      {54, 194, 10, "handschriftlich zu unterschreiben."}
    ]
  end

  defp content_stream(lines) do
    Enum.map_join(lines, "\n", fn {x, y, size, text} ->
      "BT /F1 #{size} Tf #{x} #{y} Td (#{escape_pdf(ascii(text))}) Tj ET"
    end)
  end

  defp build_pdf(content) do
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] " <>
        "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Length #{byte_size(content)} >>\nstream\n#{content}\nendstream"
    ]

    header = <<"%PDF-1.4\n%", 0xE2, 0xE3, 0xCF, 0xD3, "\n">>

    {body, offsets, _offset} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({"", [], byte_size(header)}, fn {object, number}, {body, offsets, offset} ->
        encoded = "#{number} 0 obj\n#{object}\nendobj\n"
        {body <> encoded, offsets ++ [offset], offset + byte_size(encoded)}
      end)

    xref_offset = byte_size(header) + byte_size(body)

    xref_entries =
      Enum.map_join(offsets, "", fn offset ->
        :io_lib.format("~10..0B 00000 n ~n", [offset]) |> IO.iodata_to_binary()
      end)

    header <>
      body <>
      "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <>
      xref_entries <>
      "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\n" <>
      "startxref\n#{xref_offset}\n%%EOF\n"
  end

  defp disruption_line(%{rail: %{first_disrupted_train: nil}}),
    do: "Stoerung: siehe Fahrgastrechteformular"

  defp disruption_line(%{rail: %{first_disrupted_train: train}}) do
    label = [train.train_category, train.train_number] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
    "Erster gestoerter Zug: #{label}"
  end

  defp full_name(profile) do
    [profile.title, profile.first_name, profile.last_name]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp format_date(date), do: Calendar.strftime(date, "%d.%m.%Y")

  defp ascii(value) do
    value
    |> to_string()
    |> String.replace("Ä", "Ae")
    |> String.replace("Ö", "Oe")
    |> String.replace("Ü", "Ue")
    |> String.replace("ä", "ae")
    |> String.replace("ö", "oe")
    |> String.replace("ü", "ue")
    |> String.replace("ß", "ss")
    |> String.normalize(:nfd)
    |> String.replace(~r/[^[:ascii:]]/u, "")
  end

  defp escape_pdf(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
  end
end
