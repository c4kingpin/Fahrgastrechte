# ADR 0003: AcroForm, Flattening und qpdf-Merge

- Status: akzeptiert
- Datum: 2026-07-27
- Betrifft: C00, C03, C05

## Kontext

Das am 2026-07-27 über die
[offizielle DB-Seite](https://www.bahn.de/faq/wo-erhalte-ich-das-fahrgastrechte-formular)
verlinkte deutsche Formular ist ein zweiseitiges A4-PDF mit AcroForm-Feldern
und eingebettetem JavaScript. Es trägt die Formularversion
`Formular 2025 (ME/08/25)`. Die geprüfte Datei hat SHA-256
`4a30f9c7f00593bf5bda1b6eaa2d1b6e293357faa48631a1d7e2ade3b77a39a9`.
Ihre Linearization-Hinweistabellen sind inkonsistent; qpdf kann die Datei lesen
und schreibt vor der weiteren Verarbeitung eine strukturell saubere Kopie.

Das aktuelle Formular enthält Felder für geplante Strecke und Zeit,
tatsächliche Ankunft, Ticket, Überweisung und Person. Anders als ältere
Formulare enthält es keine Felder für den ersten gestörten oder letzten
tatsächlich benutzten Zug. Diese Angaben dürfen nicht auf nicht vorhandene
Koordinaten gelegt werden; sie bleiben im Deckblatt beziehungsweise
Antragsdatensatz.

## Entscheidung

Der fachliche Vertrag ist `Fahrgastrechte.Exports.PDFBackend`. Die isolierte
Pipeline verwendet:

- `pdfinfo` und `qpdf --check` für Struktur- und Limitprüfung,
- `pdftotext` für Textgewinnung,
- `qpdf` für die Normalisierung des Templates und das Flattening,
- `pdftk-java` für die AcroForm-Befüllung,
- `pdftocairo -pdf` für neue Seiten ohne interaktive Aktionen und
- `qpdf --empty --pages ...` für den geordneten Merge in ein neues Dokument.

Ein Koordinaten-Overlay wird für die geprüfte Formularversion nicht verwendet.
Vor jeder Befüllung werden URL, SHA-256 und die erwarteten Feldnamen geprüft.
Eine geänderte Prüfsumme oder ein fehlendes Feld bricht den Export ab, bis eine
neue Template-Version ausdrücklich aufgenommen wurde.

Das Merge-Dokument beginnt mit `--empty`. Dadurch wird keine dokumentweite
Struktur eines Eingangs-PDFs als primäres Dokument übernommen. Formularfelder
werden geflattet. Anschließend erzeugt Poppler/Cairo aus jeder Eingabeseite eine
neue PDF-Seite; Annotationen und referenzierte JavaScript-Aktionen werden nicht
übernommen. Das Ergebnis muss:

- mit `qpdf --check` valide sein,
- ausschließlich A4-Seiten enthalten,
- genau die erwartete Seitenzahl haben,
- keine AcroForm-Felder, JavaScript-Aktionen, offenen Aktionen oder Anhänge
  enthalten und
- mit `pdftotext` weiterhin die erwarteten synthetischen Werte enthalten.

Das Unterschriftsfeld und nicht benötigte optionale Einwilligungen werden nie
befüllt. Der reproduzierbare Versuch steht in
[`scripts/c00/verify_pdf_pipeline.sh`](../../scripts/c00/verify_pdf_pipeline.sh).

## Ressourcen- und Prozessgrenzen

Die folgenden konfigurierbaren Startwerte gelten pro Eingabedokument:

- ausschließlich `%PDF-`-Signatur und MIME-Typ `application/pdf`,
- maximal 15 MiB und 20 Seiten,
- maximal 10 Sekunden für Prüfung, 15 Sekunden für Textgewinnung und
  30 Sekunden für Befüllung/Merge,
- höchstens zwei gleichzeitige PDF-Jobs pro App-Instanz,
- temporäres Verzeichnis `0700`, Dateien `0600`, atomare Umbenennung am Ende.

Die Werkzeuge laufen ohne Netzwerk, mit schreibgeschütztem Original, eigenem
temporären Verzeichnis und Betriebssystemlimits für CPU, Speicher, Prozesse
und Dateigröße. Dateinamen und Inhalte werden nicht geloggt. Ghostscript wird
nicht auf hochgeladene Dokumente angewendet.

## Folgen

AcroForm-Felder sind robuster als ein Koordinaten-Overlay, binden die
Implementierung aber bewusst an eine geprüfte Formularversion. `pdftk-java`
bringt eine Java-Laufzeit mit; sie bleibt im isolierten PDF-Prozess und nicht
im Phoenix-Prozess. Poppler/Cairo erzeugt interaktionsfreie Seiten; qpdf setzt
sie in einem neuen Dokument zusammen. Beide Werkzeuge verarbeiten weiterhin
nicht vertrauenswürdige Daten und ersetzen deshalb nicht die Prozessisolation.
