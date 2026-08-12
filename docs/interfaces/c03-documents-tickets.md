# C03-Schnittstellen: Dokumente und Ticketimport

C03 besitzt PDF-Metadaten, das private Dokumentvolume, autorisierte Downloads,
Textgewinnung und unbestätigte Ticketvorschläge. Upload-, Analyse- und
Downloadaufrufer verwenden ausschließlich `Fahrgastrechte.Documents` und
`Fahrgastrechte.Tickets`; Speicherpfade und Tabellen sind keine öffentliche
Schnittstelle.

## Documents

```elixir
Documents.put_document(
  current_scope,
  claim_id,
  kind,
  %{
    path: trusted_temporary_path,
    original_filename: browser_filename,
    content_type: "application/pdf"
  },
  expected_claim_lock_version
)

Documents.get_document(current_scope, document_id)
Documents.list_documents(current_scope, claim_id)
Documents.stream_document(current_scope, document_id)
Documents.delete_document(current_scope, document_id, expected_claim_lock_version)
Documents.delete_claim(current_scope, claim_id, expected_claim_lock_version)
```

`put_document/5` akzeptiert `ticket`, `invoice`, `generated_cover`,
`generated_form` und `generated_bundle`. Der Pfad stammt aus einem
serverseitigen LiveView-Upload oder der Ausgabeerzeugung und ist kein
Browserparameter. Der Originalname wird nur als bereinigtes Anzeigemetadatum
gespeichert.

Die Funktion prüft deklarierte MIME-Art, PDF-Signatur, Dateigröße und
Poppler-Metadaten. Sie liefert den gespeicherten `document`-Datensatz und den
gegebenenfalls durch Ausgabe-Invaliderung aktualisierten `claim`. C06 muss die
zurückgegebene Claim-`lock_version` übernehmen. Fehler sind unter anderem
`:wrong_content_type`, `:invalid_pdf`, `:file_too_large`, `:too_many_pages`,
`:timeout`, `:storage_unavailable`, `:stale` und `:not_found`.

`stream_document/2` liefert Metadaten und einen binären, verzögerten Stream;
niemals einen internen Pfad oder Speicherschlüssel. Der authentifizierte
Controller unter `/dokumente/:id/download` setzt `private, no-store` und prüft
den Scope vor dem ersten Byte.

### Ersetzung und Löschung

Pro Antrag und Dokumentart existiert genau ein aktuelles Dokument. Bei einer
Ersetzung wird die neue Datei zuerst atomar und mit Modus `0600` gespeichert.
Die Datenbanktransaktion macht anschließend das alte Dokument unsichtbar, legt
das neue an und invalidiert eine aktuelle Ausgabe. Erst nach Commit wird die
alte Datei entfernt. Ein fehlgeschlagener Cleanup bleibt als nicht sichtbarer
Datensatz markiert und wird beim nächsten Listenaufruf erneut versucht.

Einzel- und Antragslöschungen sind zweiphasig. Dokumente werden zuerst als
ausstehend markiert, anschließend idempotent aus dem Volume entfernt und erst
dann aus der Datenbank gelöscht. `Documents.delete_claim/3` ist der von C06 zu
verwendende koordinierte Endpunkt; ein direkter Aufruf von
`Claims.delete_claim/3` würde die Dateibereinigung umgehen.

## Tickets

```elixir
Tickets.analyze_document(
  current_scope,
  document_id,
  expected_claim_lock_version
)
Tickets.list_suggestions(current_scope, document_id)
Tickets.set_suggestion_state(
  current_scope,
  suggestion_id,
  state,
  expected_claim_lock_version
)
Tickets.set_suggestion_states(
  current_scope,
  suggestion_ids,
  state,
  expected_claim_lock_version
)
```

`analyze_document/3` verwendet Popplers `pdftotext -layout -enc UTF-8` in
einem begrenzten, überwachten Prozess. Es findet keine OCR-Ausführung statt.
Erneute Analyse ersetzt alle früheren Vorschläge; neue Vorschläge beginnen
immer im Zustand `proposed`. Analyse und Statusänderungen invalidieren die
Ausgabe des zugehörigen Antrags in derselben Datenbanktransaktion und liefern
den Antrag mit aktualisierter `lock_version` zurück. Eine veraltete erwartete
Version ergibt `:stale`; bei einem Fehler bleiben Analyse und Vorschläge
unverändert.

Jeder Vorschlag enthält:

- ein festes fachliches Feld,
- einen JSON-kompatiblen Wert,
- Konfidenz zwischen 0 und 1,
- Quellseite und Textausschnitt sowie
- `proposed`, `accepted` oder `rejected`.

Erkannt werden nur ausdrücklich beschriftete Auftragsnummern, Geltungstage,
Start/Ziel, Flexpreis-Produkt und eindeutig zugeordnete Beträge. Zug und
Sollzeiten entstehen ausschließlich aus einem ausdrücklich gedruckten
Reiseplan. Via-Angaben, tatsächlich genutzte Züge und Istzeiten werden nicht
abgeleitet.

Textlose oder verschlüsselte PDFs ergeben erfolgreich den Analysestatus
`manual_required` mit leerer Vorschlagsliste. Timeout, ungültige PDF-Struktur
oder Ressourcenüberschreitung ergeben `failed` und können erneut analysiert
werden. Kein Analyseergebnis bestätigt oder übernimmt Werte automatisch.

## Betrieb

Produktion verlangt einen absoluten `DOCUMENT_STORAGE_PATH` außerhalb von
`priv/static` und des Release-Verzeichnisses. Das Verzeichnis wird mit `0700`,
jede Datei mit `0600` angelegt. `pdfinfo`, `pdftotext` und das persistente Volume
müssen im Release-Container beziehungsweise auf dem Laufzeithost verfügbar
sein. Datenbank und Volume bilden eine gemeinsame Backup- und Restore-Einheit.
