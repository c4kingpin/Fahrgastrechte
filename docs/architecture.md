# Technische Übersicht

## Systemgrenze

Fahrgastrechte ist eine private Phoenix-LiveView-Anwendung. Zoraxy beendet TLS
und leitet HTTP sowie WebSockets an Phoenix weiter. Authentik übernimmt OIDC;
PostgreSQL speichert Fach- und Metadaten, während PDF-Inhalte in einem privaten
Dateispeicher liegen.

```text
Browser
  │
  ▼
Zoraxy / TLS ──► Phoenix LiveView ──► Authentik / OIDC
                         │
                         ├──► PostgreSQL
                         ├──► privater PDF-Speicher
                         ├──► begrenzte PDF-Prozesse
                         └──► DB-Fahrplandaten über Req
```

Jede benutzerbezogene Operation erhält einen authentifizierten
`Fahrgastrechte.Accounts.Scope`. Eine ungescopte ID berechtigt weder zum Lesen
noch zum Ändern. Authentifizierte Seiten und Dokumentdownloads werden mit
`Cache-Control: private, no-store` ausgeliefert.

## Fachkontexte

| Kontext | Verantwortung |
| --- | --- |
| `Accounts` | OIDC-Identität, Scope, Reisendenprofil und verschlüsselte Bankdaten |
| `Claims` | Antrag, optimistisches Locking, Status und Statushistorie |
| `Documents` | PDF-Prüfung, privater Speicher, Download und Löschkoordination |
| `Tickets` | Textauslesung und nachvollziehbare, unbestätigte Datenvorschläge |
| `Rail` | Provider, Snapshots, geplante/tatsächliche Reise und manuelle Korrektur |
| `Exports` | Exportbereitschaft, offizielles Formular und versioniertes Gesamt-PDF |

Die öffentlichen Kontextverträge für C02 bis C05 sind unter
[`docs/interfaces/`](interfaces/README.md) beschrieben. Verbindliche technische
Entscheidungen stehen als [ADR](decisions/README.md); der historische
Komponenten- und Wellenplan liegt getrennt unter
[`docs/implementation-plan/`](implementation-plan/README.md).

## Wichtigste Abläufe

### Antrag

1. `Claims` legt einen benutzergebundenen Entwurf an.
2. `Documents` prüft Ticket und Rechnung und speichert sie privat.
3. `Tickets` erzeugt Vorschläge; der Benutzer bestätigt oder verwirft sie.
4. `Rail` speichert geplante und tatsächliche Segmente, unabhängig davon, ob
   sie von einem Provider oder aus manueller Eingabe stammen.
5. `Exports` prüft alle Kontexte und veröffentlicht Deckblatt, Formular und
   Gesamt-PDF gemeinsam mit einer unveränderlichen Exportversion.
6. `Claims` verfolgt anschließend Versand und Abschluss.

### Konsistenz

Claim-Mutationen verwenden `lock_version`, damit konkurrierende Änderungen
nicht unbemerkt überschrieben werden. Abhängige Änderungen aus Documents und
Rail erhöhen diese Version auch bei einem Entwurf atomar mit ihrer fachlichen
Mutation. Profiländerungen, Dokumentanalysen und Vorschlagsstatus invalidieren
abhängige Ausgaben atomar über claimgebundene Kontextoperationen. Alle
exportrelevanten Mutationen übernehmen dabei die aktualisierte Claim-Sperrversion.
Generierte PDF-Sets werden erst nach vollständiger Validierung
gemeinsam veröffentlicht; historische Versionen bleiben unveränderlich
erhalten.

### PDF- und Zeitgrenzen

Uploads werden auf Inhalt, Größe und Seitenzahl geprüft. Externe Werkzeuge
laufen mit Zeit- und Ressourcenlimits; Dokumentinhalte und Speicherpfade werden
nicht geloggt. Bahnzeiten werden intern als UTC gespeichert und an UI- und
Formulargrenzen zentral über `Fahrgastrechte.Rail.BerlinTime` in deutsche
Ortszeit umgerechnet.

## Laufzeitkonfiguration

Lokale Datenbankwerte sind in der [README](../README.md) beschrieben.
Produktionsvariablen, Secret-Handhabung und externe Dienste dokumentiert das
[Betriebshandbuch](deployment/operations.md). Die Anwendung startet in dieser
Reihenfolge:

1. Telemetrie und Repository
2. PubSub sowie Supervisor für externe Kommandos
3. globaler Rate-Limiter für den Rail-Provider
4. Phoenix-Endpoint

## Qualitätsgrenze

`mix precommit` kompiliert mit Warnungen als Fehler, entfernt unbenutzte
Lock-Einträge, formatiert den Code und führt die Tests aus. CI prüft zusätzlich
Deployment-Shellskripte mit `bash -n` und ShellCheck. Praktische Druck-,
Proxy-, Backup-/Restore- und Produktionsprüfungen bleiben im
[Abnahmeprotokoll](deployment/acceptance.md) dokumentiert.
