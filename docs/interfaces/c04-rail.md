# C04 – öffentliche Rail-Schnittstelle

`Fahrgastrechte.Rail` ist die einzige fachliche Schnittstelle für
Bahnhofssuche, Verbindungsvorschläge, bestätigte Reiseverläufe und die von C05
benötigten Formularwerte. Jede benutzerbezogene Funktion verlangt einen
`Fahrgastrechte.Accounts.Scope`; eine Antrag-, Journey- oder Segment-ID allein
berechtigt nie zum Zugriff.

## Provider und Suche

Der providerneutrale Vertrag steht in `Fahrgastrechte.Rail.Provider`. Externe
IDs sind stets `%{provider: Modul, value: "..."}`. Provider liefern nur
normalisierte Bahnhöfe, Fahrten und Ereignisse. Erfolgreiche HTTP-Antworten
können zusätzlich unveränderte Snapshots an den Rail-Kontext geben; dieser
speichert sie unmittelbar am gescopten Antrag. `list_api_snapshots/2` liefert
nur Audit-Metadaten und Prüfsummen, nie den rohen Payload.

Öffentliche Suchfunktionen:

- `search_stations(scope, claim_id, query, options \\ [])`
- `search_connections(scope, claim_id, query, options \\ [])`
- `departures(scope, claim_id, station_id, from, until, options \\ [])`
- `load_provider_journey(scope, claim_id, journey_id, options \\ [])`

Ein Provider kann pro Aufruf mit `provider: Modul` gewählt werden. Ohne Option
wird der konfigurierte Timetables-Adapter genutzt. Vorschläge werden niemals
automatisch bestätigt oder gespeichert.

`Fahrgastrechte.Rail.Providers.Timetables` nutzt `Req`, höchstens zwei
gleichzeitige Aufrufe, 45 Aufrufe pro Minute und maximal zwei idempotente
Wiederholungen. `429`, Timeout, fehlende Daten und nicht unterstützte direkte
Verbindungssuche werden als `:rate_limited`, `:timeout`, `:not_found` oder
`:unsupported` zurückgegeben. Zugangsdaten stammen ausschließlich aus
`DB_CLIENT_ID` und `DB_API_KEY`.

`Fahrgastrechte.Rail.Providers.BahnVorhersageArchive` arbeitet ausschließlich
mit einer lokal bereitgestellten, read-only CSV-Projektion des in C00
dokumentierten Schemas. Es gibt keine Web- oder API-Aufrufe. Konfiguriert werden
`BAHNVORHERSAGE_DATA_PATH` und `BAHNVORHERSAGE_DATASET_VERSION`. Fehlt die Datei
oder deckt sie den Zeitraum nicht ab, folgt sofort `:history_unavailable` und
damit der manuelle Ersatzweg. Nur finale Werte werden als `actual_at`
normalisiert; sonst bleibt `time_real` eine Prognose.

## Bestätigte Reisen

`confirm_connection/4` übernimmt einen Verbindungsvorschlag als geplante und
tatsächliche Reise in einer einzigen Transaktion. Die geplante Variante wird
ohne Prognose- und Istwerte aus denselben Segmenten abgeleitet. Beide Varianten
werden gemeinsam ersetzt und die Claim-`lock_version` wird genau einmal
fortgeschrieben; bei einem Fehler bleibt auch die bisherige Reise unverändert.

`confirm_journey/5` speichert höchstens eine geplante (`:planned`) und eine
tatsächliche (`:actual`) Reise pro Antrag. Die geplante Reise ist für jeden
Export erforderlich; bei `not_started` ist bewusst keine tatsächliche Reise
erforderlich. Die übergebene Segmentliste bestimmt
die Reihenfolge; fremde Positionswerte werden ignoriert. Ein Segment enthält:

- Start und Ziel samt optionalen providergebundenen IDs
- Zugart und Zugnummer
- Soll-, Prognose- und Istzeiten
- Ausfallstatus und externe Fahrt-ID
- Quelle, Abrufzeit und Herkunftsmetadaten
- die Kennzeichnung `manual`

Weitere Mutationen:

- `update_segment/4` markiert jede Benutzeränderung als manuell.
- `refresh_journey/5` ersetzt nur automatische Segmente. Manuelle Segmente und
  gesetzte Summary-Overrides bleiben atomar erhalten.
- `set_summary_overrides/4` überschreibt den ersten gestörten Zug, den
  verpassten Anschluss, den letzten verwendeten Zug oder die tatsächliche
  Zielankunft. Segment-IDs müssen zur eigenen tatsächlichen Reise gehören.

Der tatsächliche Reiseeditor speichert einen manuellen Anschlussverlust als
drei geordnete Segmente: verspäteter Zubringer, nicht genutzter planmäßiger
Anschluss und tatsächlich genutzte Ersatzverbindung. Die Istankunft des
Zubringers muss nach der Sollabfahrt des Anschlusses liegen. Dadurch kann die
Domäne den verpassten Anschluss ableiten und die Ersatzankunft exportieren.

Alle Änderungen verwenden die erwartete `claim.lock_version` und rufen
`Claims.invalidate_output/3` innerhalb derselben Datenbanktransaktion auf. Ein
aktueller `ready`- oder `sent`-Export fällt dadurch auf `draft` zurück.

## Ableitungen und C05

`travel_summary/2` leitet aus der tatsächlichen Segmentfolge ab:

- den ersten ausgefallenen oder verspäteten Zug,
- den Anschluss, dessen Sollabfahrt vor der effektiven Ankunft des Zubringers
  liegt,
- das letzte nicht ausgefallene Segment und
- dessen tatsächliche, ersatzweise prognostizierte Zielankunft.

Manuelle Overrides haben dabei Vorrang. `form_values/2` liefert anschließend
eine stabile Map mit `scheduled_departure`, `scheduled_arrival`,
`first_disrupted_train`, `missed_connection`, `last_used_train` und
`actual_destination_arrival`. Alle für Anzeige und Formular bestimmten Zeiten
liegen als `DateTime` in `Europe/Berlin` vor; Speicherung und Providergrenzen
bleiben UTC.

Die Pflichtableitungen hängen vom Reiseergebnis ab: `not_started` benötigt
keine tatsächliche Reise, `aborted` keine Zielankunft, und
`continued_with_other_transport` keinen letzten verwendeten Zug. Eine
verspätete Zielankunft benötigt alle tatsächlichen Basiswerte; die Ursache
`missed_connection` zusätzlich den verpassten Anschluss. Fehlende Werte werden
als `%{type: :incomplete, errors: [...]}` strukturiert zurückgegeben.

## Fehlervertrag

Neben Changesets sind insbesondere `:not_authenticated`, `:not_found`,
`:not_editable`, `:stale`, `:invalid_segments`, `:invalid_override`,
`:history_unavailable`, `:rate_limited`, `:timeout`, `:unsupported` und
`{:upstream, detail}` möglich. Providerfehler blockieren keine manuelle
Erfassung.
