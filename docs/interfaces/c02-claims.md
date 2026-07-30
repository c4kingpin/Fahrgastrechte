# C02-Schnittstelle: Antragsdomäne

`Fahrgastrechte.Claims` ist die einzige öffentliche Schnittstelle zu Anträgen
und deren Statushistorie. Aufrufer aus C03 bis C06 dürfen die Tabellen
`claims` und `claim_status_history` nicht direkt abfragen oder verändern.

## Eigentum und Nebenläufigkeit

Jede Funktion erhält als erstes Argument einen
`Fahrgastrechte.Accounts.Scope`. Eine fremde oder unbekannte Antrags-ID ergibt
immer `{:error, :not_found}`. Dadurch verrät die API nicht, ob der Antrag einem
anderen Benutzer gehört.

Jede schreibende Funktion erhält zusätzlich die zuletzt gelesene
`lock_version`. Nach einer erfolgreichen Änderung liefert der Antrag eine um
eins erhöhte Version. `{:error, :stale}` bedeutet, dass der Aufrufer den Antrag
neu laden und den Konflikt sichtbar auflösen muss; ein Autosave darf dann nicht
blind wiederholt werden.

## Öffentliche Funktionen

```elixir
Claims.create_claim(current_scope, attrs \\ %{})
Claims.get_claim(current_scope, claim_id)
Claims.change_claim(current_scope, claim_id, attrs \\ %{})
Claims.list_claims(current_scope, filters \\ %{})
Claims.update_claim(current_scope, claim_id, attrs, expected_lock_version)
Claims.delete_claim(current_scope, claim_id, expected_lock_version)

Claims.export_readiness(current_scope, claim_id)
Claims.transition_claim(current_scope, claim_id, target_status, expected_lock_version)
Claims.invalidate_output(current_scope, claim_id, expected_lock_version)
Claims.list_status_history(current_scope, claim_id)
```

`list_claims/2` akzeptiert `status`, `travel_date`, `date_from`, `date_to`,
`route` und `claim_number` als Atom- oder String-Schlüssel. Datumswerte sind
`Date`-Werte oder ISO-8601-Strings. Strecke und Antragsnummer werden ohne
Beachtung der Groß-/Kleinschreibung als Teiltext gesucht.

`change_claim/3` liefert für gescopte LiveView-Formulare ein Changeset, ohne
Änderungen zu speichern. Auch diese Funktion gibt für fremde oder unbekannte
Anträge ausschließlich `{:error, :not_found}` zurück.

Über `create_claim/2` und `update_claim/4` sind `travel_date`, `origin`,
`destination`, `journey_outcome`, `disruption_cause` und `journey_direction`
änderbar. Reiseergebnis (`delayed_arrival`, `not_started`, `aborted`,
`continued_with_other_transport`), Ursache (`delay`, `cancellation`,
`missed_connection`) und Richtung (`outbound`, `return`) bleiben getrennte
Fachwerte. Ein Anschlussverlust ist mit einer nicht angetretenen Reise nicht
vereinbar. Benutzerzuordnung,
Antragsnummer, Status, Entschädigungsart, Zeitpunkte und Sperrversion werden von
der Domäne gesetzt.

## Status und Ausgabe

Die vollständige Übergangsmatrix ist:

| Von | Erlaubte Ziele |
| --- | --- |
| `draft` | `ready` |
| `ready` | `draft`, `sent` |
| `sent` | `draft`, `completed` |
| `completed` | keine |

Der Übergang nach `ready` darf von C05 erst nach erfolgreicher
Ausgabeerzeugung aufgerufen werden und setzt `generated_at`. `sent` und
`completed` setzen die entsprechenden Zeitpunkte. Ein Rücksprung nach `draft`
löscht alle Zeitpunkte, die dadurch nicht mehr gültig sind.

Eine fachliche Änderung an einem `ready`-Antrag setzt ihn in derselben
Datenbanktransaktion auf `draft`, löscht `generated_at` und schreibt einen
Historieneintrag. Ändert ein anderer Kontext ausgaberelevante Daten, verwendet
er `invalidate_output/3`. Bei `sent` ist dieser explizite Aufruf erforderlich;
ein normales Antragsupdate wird mit `{:error, :not_editable}` abgelehnt.

C05 kann seine Ausgabeversion und den Statusübergang in einer äußeren
`Repo.transaction/1` zusammenfassen. Die interne Transaktion des Claims-Kontexts
nimmt an dieser Transaktion teil. Nach einem Fehler muss C05 temporäre oder
bereits atomar umbenannte Dateien entsprechend seinem eigenen Speichervertrag
entfernen.

## Strukturierte Fehler

Fehlende C02-Felder werden so zurückgegeben:

```elixir
{:error,
 %{
   type: :incomplete,
   errors: [
     %{source: :claim, field: :journey_outcome, code: :required},
     %{source: :claim, field: :disruption_cause, code: :invalid_for_outcome}
   ]
 }}
```

`Exports.readiness/2` sammelt Fehler aus Claims, Accounts, Documents und Rail
unter deren jeweiliger `source`, ohne dieses Format zu verändern oder nach dem
ersten unvollständigen Bereich abzubrechen. Weitere Domänenfehler sind
`:not_authenticated`, `:not_found`, `:not_editable`, `:stale`,
`{:invalid_filter, field}` und
`{:invalid_transition, current_status, requested_status}`. Validierungsfehler
von Eingabefeldern werden als `Ecto.Changeset` zurückgegeben.

## Löschkoordination

Datenbankobjekte anderer Kontexte referenzieren `claims.id` mit
`on_delete: :delete_all`. Externe Ressourcen wie PDF-Dateien müssen durch den
besitzenden Kontext entfernt werden, bevor `delete_claim/3` die abschließende
Datenbanklöschung ausführt. C06 startet deshalb später nicht direkt eine
Tabellenlöschung, sondern den koordinierten Löschablauf des Documents-Kontexts;
dieser endet mit `Claims.delete_claim/3`.
