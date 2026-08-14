# C05 – öffentliche Export-Schnittstelle

Fahrgastrechte.Exports erzeugt versionierte, druckfertige
Fahrgastrechte-PDFs. Jede öffentliche Funktion verlangt einen
Fahrgastrechte.Accounts.Scope; eine Antrag-, Export- oder Dokument-ID allein
berechtigt nie zum Zugriff.

## Bereitschaft und Erzeugung

`readiness(scope, claim_id)` liefert entweder alle geprüften fachlichen
Voraussetzungen oder eine aggregierte Fehlerliste aus Claim, Profil, Rail und
Dokumenten. Die spätere Prüfseite kann damit alle offenen Punkte in einem Lauf
anzeigen.

Die Profilprüfung lädt und entschlüsselt das Profil genau einmal. Fehlende
Pflichtfelder fließen als fachliche `incomplete`-Fehler ein;
Entschlüsselungsfehler wie `:invalid_ciphertext` werden dagegen unverändert
als Betriebs- beziehungsweise Integritätsfehler weitergegeben. C06 startet
`generate_export/3` mit `start_async/3`, sodass Rendering und PDF-Werkzeuge
den LiveView-Prozess nicht blockieren.

`generate_export(scope, claim_id, expected_claim_lock_version)` liest die
Voraussetzungen ausschließlich über die öffentlichen Schnittstellen von
Accounts, Claims, Documents und Rail. Erforderlich sind:

- ein vollständiger Antrag im Status draft,
- ein vollständiges Reisendenprofil einschließlich IBAN und BIC,
- eine bestätigte geplante Reise und die vom Reiseergebnis abhängigen
  tatsächlichen Werte von C04,
- je ein aktuelles Ticket und eine aktuelle Rechnung sowie
- das konfigurierte, unveränderte Formulartemplate.

Fehlende Fachdaten werden strukturiert mit Quelle, Feld und Fehlercode
zurückgegeben. Eine abweichende Template-Prüfsumme liefert
template_changed; fehlende Werkzeuge oder Dateien, Ressourcenlimits und
Timeouts werden ohne teilweise Ausgabe zurückgegeben.

Die Ausgabe besteht immer aus:

1. A4-Deckblatt mit Fensteranschrift, Absender, Antragsnummer, Strecke,
   Anlagenliste und Unterschriftshinweis,
2. ausgefülltem und geflattetem DB-Formular,
3. sanitisiertem Ticket und
4. sanitisierten Rechnungsseiten.

Unterschrift und freiwillige Einwilligungen werden nie an das Backend
übergeben. Das Ergebnis enthält keine AcroForm-Felder, JavaScript-Aktionen,
offenen Aktionen oder Anhänge. Alle Seiten werden als A4 validiert.

## Atomarität und Versionen

Rendering und Normalisierung laufen in einem privaten temporären Verzeichnis.
Erst nach erfolgreicher Abschlussvalidierung werden Deckblatt, Formular und
Gesamt-PDF dauerhaft bereitgestellt. Dokumentmetadaten, unveränderliche
ExportVersion und der Statusübergang draft → ready werden in einer
Datenbanktransaktion geschrieben. Ein Fehler entfernt alle neu vorbereiteten
Dateien und lässt den Antrag als Entwurf bestehen.

Jede Version hält Template-Version, Template-Quelle, Template-Prüfsumme und
eine Prüfsumme des unveränderlichen Exportmodells fest. Sensible Modellwerte
werden nicht zusätzlich im Klartext gespeichert. Frühere generierte Dokumente
bleiben für historische Downloads erhalten; Änderungen an Antrag, Dokumenten
oder Reisen invalidieren nur die aktuelle Ausgabe über C02.

## Lesen und Herunterladen

- list_exports(scope, claim_id) listet die eigenen Versionen aufsteigend.
- get_export(scope, export_id) lädt eine eigene Version.
- stream_bundle(scope, export_id) liefert nach erneuter Scope-Prüfung den
  privaten Dokumentstream einer beliebigen eigenen Version.

Fremde IDs liefern stets not_found.

## Template und Betrieb

Das versionierte JSON-Manifest legt Feldnamen, Radio-Werte und bewusst leere
Felder fest. Vor jedem Rendering werden Konfiguration, Manifestmetadaten,
Template-Prüfsumme und die erzeugten Radio-Werte gegeneinander geprüft.
Optionale Profilwerte ohne Formularfeld werden nicht an das PDF-Backend
übergeben.

Die aufgenommene Fallback-Version ist „Formular 2025 (ME/08/25)“ mit SHA-256
4a30f9c7f00593bf5bda1b6eaa2d1b6e293357faa48631a1d7e2ade3b77a39a9.
Der Installer lädt genau diese Datei, prüft sie vor der Installation und setzt
FORM_TEMPLATE_PATH. Über `/datenquellen` kann eine neue, strukturell kompatible
PDF-Version aktiviert werden. Vorher werden A4-Struktur, Größenlimit,
Verschlüsselung, sämtliche Pflichtfelder und die erwarteten Radio-Werte
geprüft. Die neue Datei wird unveränderlich gespeichert und hat danach Vorrang
vor dem Fallback; bestehende Exportversionen verändern sich nicht.

Das Systembackend benötigt qpdf, pdftk-java, Poppler/Cairo und eine
DejaVu-Schrift. PDF-Jobs werden instanzweit serialisiert, beenden einzelne
Werkzeugaufrufe nach spätestens 30 Sekunden und entfernen ihr Arbeitsverzeichnis
auch bei Fehlern.
