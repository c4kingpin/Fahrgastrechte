# C00 – technische Spikes

Stand: 2026-07-27

C00 liefert Entscheidungen und reproduzierbare Versuche, keine
Produktionsfunktion. Alle eingecheckten Beispiele sind synthetisch.

## Ergebnisse

| Risiko | Ergebnis |
| --- | --- |
| DB API | Timetables deckt Suche, Soll und aktuelle Änderungen ab; keine verlässliche Historie oder allgemeine Start-Ziel-Suche |
| Historie | Bahn-Vorhersage wird ausschließlich über lokal importierte ODbL-Jahresarchive genutzt; seine Web-API darf nicht verwendet werden |
| Tickettext | Poppler extrahiert das synthetische Flexpreis-Beispiel reproduzierbar; OCR bleibt ausgeschlossen |
| Formular | aktuelles offizielles PDF ist ein AcroForm; Feldbefüllung und Flattening funktionieren |
| PDF-Merge | Formular, Ticket und Rechnung ergeben ein valides vierseitiges A4-PDF ohne AcroForm/JavaScript |
| Speicher | privates persistentes Volume, gescopte Streams, atomare Dateien und verschlüsselte Bankfelder |

Die verbindlichen Begründungen stehen in
[`docs/decisions/`](../../decisions/README.md). Die daraus entstandenen
Verträge sind:

- `Fahrgastrechte.Rail.Provider`
- `Fahrgastrechte.Tickets.Extractor`
- `Fahrgastrechte.Exports.PDFBackend`

## PDF-Versuch wiederholen

Benötigt werden `curl`, Poppler (`pdfinfo`, `pdftotext`), `qpdf` und
`pdftk-java`. Unter Ubuntu 24.04:

```bash
sudo apt-get install poppler-utils qpdf pdftk-java
mix run --no-start scripts/c00/generate_pdf_fixtures.exs
scripts/c00/verify_pdf_pipeline.sh
```

Der Versuch lädt das offizielle Formular in ein temporäres Verzeichnis, prüft
die festgehaltene SHA-256-Summe und verwendet ausschließlich synthetische
Feldwerte. Mit `C00_OUTPUT_DIR=/sicherer/pfad` können die erzeugten
Zwischenergebnisse zur Sichtprüfung aufbewahrt werden. Standardmäßig werden
sie nach dem Test gelöscht.

## Authentifizierten DB-Aufruf wiederholen

Der Smoke-Test verwendet die offiziellen Header, gibt aber weder Credentials
noch Antwortdaten aus:

```bash
export DB_CLIENT_ID='…'
export DB_API_KEY='…'
mix run --no-start scripts/c00/db_api_smoke.exs
```

Er ruft `/station/Berlin%20Hbf` auf und protokolliert nur HTTP-Status,
Content-Type, Byteanzahl und SHA-256 der Antwort. Die Variablen waren während
C00 in der Entwicklungsumgebung nicht gesetzt; deshalb enthält das Repository
keinen behaupteten Live-Erfolg und selbstverständlich keine Zugangsdaten. Nach
Bereitstellung eines abonnierten Timetables-Zugangs ist genau dieser Befehl
auszuführen und das Ergebnis im PR festzuhalten.

## Bahn-Vorhersage als Historienquelle

Die Web-API von [Bahn-Vorhersage](https://bahnvorhersage.de/) wird nicht
aufgerufen: Der Anbieter untersagt ihre Nutzung durch andere Anwendungen. Für
historische Vorschläge verwenden wir stattdessen den veröffentlichten
[geparsten Verspätungsdatensatz](https://bahnvorhersage.de/open-data/parsed-train-delays/)
als optionalen Offline-Import.

Der Datensatz wird über die Mobilithek als jährliches Archiv mit täglichen
Parquet-Dateien bereitgestellt, regulär erst nach Abschluss eines Jahres. Er
ist ODbL-lizenziert, verlangt Attribution an Bahn-Vorhersage, Deutsche Bahn,
Trainline und DELFI und kann laut Anbieter Crawling-Lücken enthalten. Deshalb:

- keine Downloads oder Aufrufe im Benutzer-Request,
- keine Nutzung für das noch nicht veröffentlichte laufende Jahr,
- `time_real` nur bei `is_final == true` als tatsächliche Zeit behandeln,
- Anbieter, Version, Lizenz, Attribution und Quelldatei-Hash speichern und
- jeden Treffer als bestätigungspflichtigen Vorschlag anzeigen.

Die genaue Provider-Zuordnung und der manuelle Ersatzweg stehen in
[ADR 0001](../../decisions/0001-rail-provider.md).

## Synthetische Fixtures

`test/fixtures/c00/` enthält:

- zwei einseitige, textbasierte Flexpreis-Varianten,
- eine getrennte einseitige Rechnung und
- synthetische Timetables-Antworten für Bahnhof, Sollhalt und Ausfall sowie
- eine synthetische tabellarische Projektion des Bahn-Vorhersage-Parquet-Schemas
  mit Prognose- und finalem Datenpunkt.

Die PDFs werden deterministisch aus
[`generate_pdf_fixtures.exs`](../../../scripts/c00/generate_pdf_fixtures.exs)
erzeugt. Keine Fixture ist von einem echten Dokument abgeleitet.
