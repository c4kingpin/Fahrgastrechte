# Refactoring-Roadmap

Stand: 12. August 2026

Die gesamte Lösung wurde entlang von Domäne, Webschicht, Tests, Konfiguration,
Deployment und Dokumentation geprüft. Diese Roadmap hält die bewusst noch
offenen, kontextübergreifenden Arbeiten fest. Kleine, verhaltensneutrale
Bereinigungen gehören nicht hierher; jeder Punkt benötigt einen fokussierten
Branch mit Regressionstests.

## Priorität 0 – Datenkonsistenz und fachliche Korrektheit

Keine offenen Punkte.

## Priorität 1 – Sicherheits- und Laufzeitgrenzen

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
