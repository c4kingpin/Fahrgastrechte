# ADR 0002: Textbasierte Ticketextraktion ohne OCR

- Status: akzeptiert
- Datum: 2026-07-27
- Betrifft: C00, C03

## Kontext

Digitale DB-Tickets und Rechnungen können eingebetteten Text enthalten, ihr
Layout und ihre Bezeichnungen sind aber nicht als stabile Maschinenschnittstelle
versioniert. Flexpreis-Fahrkarten haben keine Zugbindung. Die aufgedruckte
Verbindung beweist daher nicht, welche Züge tatsächlich genutzt wurden. Laut
[DB-Produktinformation](https://www.bahn.de/angebot/sparpreis-flexpreis/flexpreis)
dürfen am Reisetag andere Züge auf der gebuchten Strecke genutzt werden.

Ein OCR-System würde zusätzliche Abhängigkeiten, Fehlermodi und
Datenschutzrisiken einführen und gehört nicht zum MVP.

## Entscheidung

Die Extraktion erfolgt in einem isolierten Prozess mit Popplers
`pdftotext -layout -enc UTF-8`. `pdfinfo` liefert Seitenzahl,
Verschlüsselungsstatus und Seitengröße. Der fachliche Vertrag ist
`Fahrgastrechte.Tickets.Extractor`.

Zuverlässig vorgeschlagen werden nur explizit beschriftete und syntaktisch
plausible Werte:

| Feld | Regel | Maximale Startkonfidenz |
| --- | --- | --- |
| Auftragsnummer | exakt 12 Ziffern neben passender Bezeichnung | 0,98 |
| Geltungstag/-zeitraum | eindeutig beschriftetes Datum | 0,95 |
| Start und Ziel | getrennt beschriftete Ortsfelder | 0,90 |
| Produkt | ausdrücklich genannter Flexpreis-Typ | 0,95 |
| Fahrpreis | Währung und Zuordnung zu Ticket/Gesamtbetrag eindeutig | 0,90 |
| Zugart/-nummer und Sollzeit | nur aus ausdrücklich gedrucktem Reiseplan | 0,80 |

Folgende Werte werden nicht abgeleitet:

- tatsächlich benutzte Züge oder Istzeiten,
- ein konkreter Zug allein aus einem Flexpreis-Reiseplan,
- Umstiege allein aus einer tariflichen Via-Angabe,
- ein Ticketpreis aus einem nicht eindeutig zugeordneten Rechnungsbetrag.

Jeder Vorschlag enthält Seite, Textausschnitt und Konfidenz. Kein Vorschlag wird
automatisch bestätigt. Textlose, verschlüsselte oder nicht eindeutig lesbare
PDFs wechseln direkt in die manuelle Eingabe; OCR findet nicht statt.

## Varianten und Fixtures

Die synthetischen Fixtures decken regulären Flexpreis, Flexpreis Business und
eine getrennte Rechnung ab. Sie sind keine Nachbildungen echter Kundendokumente
und enthalten ausschließlich markierte Testdaten. Der reproduzierbare
PDF-Spike prüft, dass `pdftotext` das Beispiel einschließlich
Auftragsnummer, Strecke und Preis zurückliefert.

Bevor C03 produktiv fertiggestellt wird, muss die Erkennung zusätzlich mit
vollständig anonymisierten Beispielen der tatsächlich verwendeten
Ticketgeneratoren getestet werden. Neue Layouts dürfen nur neue Vorschläge
verhindern, niemals falsche Werte bestätigen.

## Folgen

Die Lösung ist klein, lokal betreibbar und datenschutzfreundlich. Sie nimmt
bewusst in Kauf, dass ein Teil der Dokumente vollständig manuell erfasst wird.
Die fachliche Unterscheidung zwischen gebuchter, geplanter und tatsächlich
genutzter Reise bleibt erhalten.
