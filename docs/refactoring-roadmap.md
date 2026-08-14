# Refactoring-Roadmap

Stand: 12. August 2026

Die gesamte Lösung wurde entlang von Domäne, Webschicht, Tests, Konfiguration,
Deployment und Dokumentation geprüft. Diese Roadmap hält die bewusst noch
offenen, kontextübergreifenden Arbeiten fest. Kleine, verhaltensneutrale
Bereinigungen gehören nicht hierher; jeder Punkt benötigt einen fokussierten
Branch mit Regressionstests.

## Priorität 0 – Datenkonsistenz und fachliche Korrektheit

1. **Abhängige Änderungen atomar sperren.** `Claims.invalidate_output/3`
   erhöht bei Entwürfen aktuell nicht die `lock_version`. Dokument- und
   Reiseänderungen müssen auch im Entwurf eine konkurrierende Änderung erkennen.
2. **Exportabhängigkeiten vollständig invalidieren.** Profiländerungen,
   Dokument-Neuanalysen und Statusänderungen von Ticketvorschlägen können
   exportrelevante Werte verändern. Dafür braucht es claimgebundene
   Kontextoperationen mit Locking und Ausgabeinvalidierung.
3. **Mehrteilige Aktionen zusammenfassen.** Die Übernahme eines
   Verbindungskandidaten sowie das Anwenden und Bestätigen von Vorschlägen
   müssen jeweils innerhalb einer fachlichen Transaktion erfolgen.
4. **Anschlussverlust im Assistenten vervollständigen.** Die Domäne modelliert
   `missed_connection`, der tatsächliche Reiseeditor besitzt dafür aber noch
   keinen vollständigen Speicherpfad.
5. **UI- und Exportbereitschaft vereinen.** `Exports.readiness/2` soll die
   einzige fachliche Wahrheit sein; die LiveView darf daraus nur
   Schrittzustände und Links ableiten.
6. **Aktuelle und historische Ausgabe unterscheiden.** Nach einer
   exportrelevanten Änderung müssen ältere Versionen sichtbar als Archiv statt
   als aktuell versandbereit erscheinen.

## Priorität 1 – Sicherheits- und Laufzeitgrenzen

Status: am 14. August 2026 umgesetzt. Die Kontextgrenzen, der verbundene
Sitzungsablauf, die asynchronen LiveView-Arbeiten, die Rail-Bereinigung und die
explizite Profilfehlerbehandlung besitzen jeweils Regressionstests.

1. Claimgebundene Dokument- und Vorschlagsmutationen zusätzlich in den
   Kontext-APIs erzwingen. Die Webschicht weist manipulierte IDs bereits ab;
   die Domänengrenze soll denselben Vertrag unabhängig vom Aufrufer garantieren.
2. Den Ablauf einer bereits verbundenen LiveView-Sitzung erzwingen, nicht nur
   bei einem späteren HTTP-Request.
3. Provider-, Analyse- und Exportarbeit mit `start_async/3` aus dem
   LiveView-Prozess lösen und veraltete Suchantworten verwerfen.
4. Verwaiste Rail-Summary-Overrides beim Ersetzen automatischer Segmente
   bereinigen.
5. Profil-Entschlüsselungsfehler nicht als bloß unvollständiges Profil
   behandeln und das Profil bei der Exportprüfung nur einmal laden.

## Priorität 2 – Struktur und Wartbarkeit

Der größte Hotspot ist
`FahrgastrechteWeb.ClaimLive.Show`. Die Zielstruktur kommt ohne
LiveComponents aus:

- `ClaimLive.Show`: Mount, Navigation und Event-Dispatch
- reine Function Components für Dokumente, Vorschläge, Reise und Prüfung
- ein fachliches Orchestrierungsmodul für atomare Aktionen und Readiness
- ein kleines Präsentationsmodul für Labels und Zeitformatierung

Beim Zerlegen werden die wiederholten Workspace-Abfragen durch ein geprüftes
Read Model ersetzt. Dashboard-Zählungen sollen aggregierte Datenbankabfragen
verwenden, statt vollständige Antragslisten nur zum Zählen zu laden.

## Priorität 3 – UX und Dokumentation

- Anschluss-, Upload- und Störungsoptionen mit expliziten ARIA-Zuständen
  versehen und einen Skip-Link zum Hauptinhalt ergänzen.
- Generische Phoenix-Fehler- und Verbindungsnachrichten vollständig auf Deutsch
  bereitstellen.
- Den manuellen Weg bei fehlgeschlagener PDF-Analyse ausdrücklich speichern und
  testen.
- Für Webabläufe einen dauerhaften C06-Vertrag ergänzen: Routen,
  Authentifizierung, Schrittzustände, aktuelle Ausgabe, Cache-Regeln und
  Accessibility-Konventionen.

## Abnahmeregel

Jeder Punkt gilt erst als abgeschlossen, wenn mindestens ein Test den zuvor
fehlerhaften Grenzfall reproduziert, `mix precommit` erfolgreich ist und die
betroffene Schnittstellen- oder Betriebsdokumentation aktualisiert wurde.
