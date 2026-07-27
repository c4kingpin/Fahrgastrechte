fixture_dir =
  __DIR__
  |> Path.join("../../test/fixtures/c00")
  |> Path.expand()

File.mkdir_p!(fixture_dir)

escape_pdf_text = fn text ->
  text
  |> String.replace("\\", "\\\\")
  |> String.replace("(", "\\(")
  |> String.replace(")", "\\)")
end

build_pdf = fn lines ->
  content =
    lines
    |> Enum.map(escape_pdf_text)
    |> Enum.map_join(" T*\n", &"(#{&1}) Tj")
    |> then(&"BT\n/F1 12 Tf\n16 TL\n72 790 Td\n#{&1}\nET\n")

  objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    """
    << /Type /Page
       /Parent 2 0 R
       /MediaBox [0 0 595 842]
       /Resources << /Font << /F1 4 0 R >> >>
       /Contents 5 0 R
    >>
    """,
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    "<< /Length #{byte_size(content)} >>\nstream\n#{content}endstream"
  ]

  header = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"

  {numbered_objects, end_offset} =
    objects
    |> Enum.with_index(1)
    |> Enum.map_reduce(byte_size(header), fn {body, number}, offset ->
      object = "#{number} 0 obj\n#{body}\nendobj\n"
      {{offset, object}, offset + byte_size(object)}
    end)

  xref_entries =
    numbered_objects
    |> Enum.map_join(fn {offset, _object} ->
      "#{String.pad_leading(Integer.to_string(offset), 10, "0")} 00000 n \n"
    end)

  body = numbered_objects |> Enum.map_join(&elem(&1, 1))

  header <>
    body <>
    "xref\n0 #{length(objects) + 1}\n" <>
    "0000000000 65535 f \n" <>
    xref_entries <>
    "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\n" <>
    "startxref\n#{end_offset}\n%%EOF\n"
end

fixtures = %{
  "synthetic-ticket-flexpreis.pdf" => [
    "SYNTHETISCHES TESTTICKET - NICHT GUELTIG",
    "Produkt: Flexpreis",
    "Auftragsnummer: 000000000001",
    "Geltungstag: 15.04.2026",
    "Von: Teststadt Hbf",
    "Nach: Beispielstadt Hbf",
    "Reiseplan (nicht zuggebunden): ICE 100",
    "Teststadt Hbf ab 08:04",
    "Beispielstadt Hbf an 12:10",
    "Fahrpreis: 129,90 EUR"
  ],
  "synthetic-ticket-flexpreis-business.pdf" => [
    "SYNTHETISCHES TESTTICKET - NICHT GUELTIG",
    "Produkt: Flexpreis Business",
    "Auftragsnummer: 000000000002",
    "Geltungszeitraum: 14.04.2026 bis 18.04.2026",
    "Von: Teststadt Hbf",
    "Nach: Beispielstadt Hbf",
    "Via: Zwischenstadt",
    "Fahrpreis: 189,90 EUR",
    "Keine Aussage ueber tatsaechlich genutzte Zuege"
  ],
  "synthetic-invoice.pdf" => [
    "SYNTHETISCHE RECHNUNG - KEIN ECHTER BELEG",
    "Rechnungsnummer: TEST-2026-0001",
    "Auftragsnummer: 000000000001",
    "Leistung: Flexpreis Teststadt - Beispielstadt",
    "Leistungsdatum: 15.04.2026",
    "Gesamtbetrag: 129,90 EUR",
    "Zahlstatus: TESTDATEN"
  ]
}

Enum.each(fixtures, fn {filename, lines} ->
  path = Path.join(fixture_dir, filename)
  File.write!(path, build_pdf.(lines))
  IO.puts("generated #{Path.relative_to_cwd(path)}")
end)
