# Ausbauplan nach Wellen

Stand: 30. Juli 2026

Dieser Plan setzt auf dem in C00 bis C06 entstandenen Fach- und
LiveView-Grundgerüst auf. Die erste vollständige Produktversion bleibt bei der
vereinbarten Grenze: deutsche DB-Flexpreis-Reisen, eine reisende Person,
Überweisung, Ticket und Rechnung als PDF sowie keine direkte digitale
Übermittlung an die Deutsche Bahn.

## Ausgangslage

| Bereich | Stand |
| --- | --- |
| Accounts und Profil | Scope, Reisendenprofil, verschlüsselte Bankdaten und Authentik/OIDC vorhanden |
| Claims | Antrag, Statushistorie, Filter und optimistisches Locking vorhanden |
| Documents und Tickets | privater PDF-Speicher, Ersetzen, Analyse, thematische Einzel-/Sammelprüfung und manueller Ersatzweg vorhanden |
| Rail | tastaturbedienbare Suche, Kandidatenvergleich, Umstiegseditor und tatsächliche Timeline vorhanden |
| Exports | Prüfseite, versionierte Erzeugung, historische Downloads und Versandcheckliste vorhanden |
| LiveView | vollständiger fortsetzbarer Sechs-Schritt-Assistent mit fachlichem Fortschritt und Statusverlauf vorhanden |
| Betrieb | Proxmox-Grundlage vorhanden; praktische Druck- und Produktionsabnahme ausstehend |

## Welle 0 – Saubere Ausgangslage

- offene C07-Arbeit verlustfrei auf einem eigenen Zweig sichern
- neuen Ausbauzweig vom aktuellen `origin/main` anlegen
- vollständige Baseline mit `mix precommit` herstellen
- diesen Umsetzungsplan auf den realen Stand aktualisieren
- aktuelles offizielles Formular und reale PDF-Werkzeuge mit dem
  reproduzierbaren C00-Versuch prüfen

Die konkrete Prüfung ist im
[`Baseline-Protokoll`](baseline-2026-07-30.md) festgehalten.

## Welle 1 – Fachliche Exportkorrektheit

- formularnahes Reiseergebnis für verspätete Ankunft, Nichtantritt,
  Reiseabbruch und Weiterfahrt mit anderem Verkehrsmittel modellieren
- Ursache wie Verspätung, Ausfall oder Anschlussverlust getrennt erfassen
- Hin- und Rückfahrt unterstützen
- Pflichtfelder abhängig vom Reiseergebnis bestimmen
- Bahnzeiten für Anzeige und Formular korrekt nach `Europe/Berlin` umwandeln
- Radio-Werte und optionale Profilwerte gegen das Template-Manifest testen
- strukturierte Bereitschaftsfehler für die spätere Prüfseite liefern

## Welle 2 – Authentik und App-Hülle

- OIDC Authorization Code Flow mit PKCE, `state` und `nonce`
- Callback, Tokenprüfung, Session-Erneuerung und Logout
- verständliche Behandlung abgelaufener Sitzungen
- produktive Navigation, aktive Zustände und mobile Bedienung
- Entwicklungs- und MVP-Texte aus der sichtbaren App entfernen

## Welle 3 – Geführter Antragsassistent

- Detailseite in adressierbare, fortsetzbare Schritte gliedern
- Fortschritt ausschließlich aus gespeicherten Fachdaten ableiten
- pro Schritt `offen`, `unvollständig` oder `bestätigt` anzeigen
- mobile Zurück-/Weiter-Navigation und nachvollziehbare Fokusführung
- Autosave-Zustände für Speichern, Erfolg, Fehler und Konflikt

## Welle 4 – Dokumente und Datenerkennung

- Upload, Ersetzen, Abbruch, Wiederholung und Fehlerbehandlung ausbauen
- Vorschläge nach Themen gruppieren und gesammelt oder einzeln bestätigen
- jeden Wert direkt manuell korrigierbar machen
- textlose und unbekannte PDFs ohne Sackgasse in den manuellen Weg führen
- Quelle, Seite und Konfidenz nachvollziehbar anzeigen

## Welle 5 – Geplante und tatsächliche Reise

- tastaturbedienbare Bahnhofssuche
- Verbindung aus Ticketdaten und Abfahrtstafeln rekonstruieren
- Kandidaten mit Zeiten, Umstiegen, Quelle und Abrufzeit vergleichen
- vollständigen manuellen Verbindungseditor anbieten
- tatsächliche Reise als bearbeitbare Timeline mit Ausfällen, Verspätungen,
  Anschlussverlusten und Ersatzverbindungen darstellen
- API-Ausfall, Rate-Limit und fehlende Historie direkt in den manuellen
  Ersatzweg überführen

## Welle 6 – Prüfung, PDF und Status

- vollständige Prüfseite in der Reihenfolge des offiziellen Formulars
- offene Punkte mit direktem Link zum betroffenen Schritt
- verständliche Zustände für PDF-Erzeugung und Fehler
- aktuelle und historische Ausgaben autorisiert herunterladen
- Checkliste für Download, Unterschrift, Belege und Versand
- Statushistorie sowie Versand- und Abschlussdatum bedienen

## Welle 7 – Qualität und Produktionsabnahme

- bestehende Tailwind-Oberfläche konsolidieren und ungenutzte Theme-Reste entfernen
- Tastatur, Kontraste, Reduced Motion und 360-Pixel-Ansicht abnehmen
- getrennte LiveView-Tests für jeden Assistentenschritt
- Referenzfälle für Direktfahrt, Ausfall mit Ersatzverbindung, manuellen
  historischen Fall und zwei strikt getrennte Benutzer
- A4- und DIN-lang-Druckprobe
- Authentik, Zoraxy, Backup/Restore, Rollback und Smoke-Test praktisch abnehmen

Die Softwareanteile der Wellen 4 bis 6 sowie Theme-Bereinigung, Reduced Motion
und die automatisierten Referenzfälle aus Welle 7 sind umgesetzt. A4-/DIN-lang-
Druckprobe und die umgebungsabhängige Betriebsabnahme bleiben bewusst im
[`Betriebsabnahmeprotokoll`](../deployment/acceptance.md) offen.

## Abnahmeziel der ersten vollständigen Version

Ein neuer Benutzer kann sich anmelden, Ticket und Rechnung hochladen,
automatische Angaben prüfen, geplante und tatsächliche Reise erfassen, die
Bearbeitung unterbrechen und fortsetzen, ein korrektes unterschriftsreifes
Gesamt-PDF erzeugen, es autorisiert herunterladen und den Antrag bis
`Erledigt` verfolgen. Der vollständige manuelle Ersatzweg funktioniert ohne
DB-API-Daten.

Zusatzkosten, Zeitkarten, BahnCard 100, mehrere Reisende, internationale
Sonderfälle, EU-Formular und direkte digitale Übermittlung bleiben eine zweite
Produktstufe.
