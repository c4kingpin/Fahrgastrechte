# Referenzdaten – versionierte Betriebsquellen

`Fahrgastrechte.ReferenceData` verwaltet installationsweit das offizielle
Fahrgastrechteformular und die CSV-Projektion der Bahn-Vorhersage-Exporte. Die
authentifizierte LiveView unter `/datenquellen` ist die Bedienoberfläche für
diese globalen Quellen; sie weist deshalb ausdrücklich darauf hin, dass eine
Aktivierung alle künftig erzeugten Ausgaben der Installation betrifft.

## Öffentliche Funktionen

- `replace_official_form(scope, path, attrs)` prüft und aktiviert ein PDF.
- `replace_bahn_archive(scope, path, attrs)` prüft und aktiviert eine CSV.
- `list_versions(scope, kind)` liefert die unveränderliche Historie.
- `current_file(kind)` ist die interne Leseschnittstelle für `Exports` und den
  Bahn-Vorhersage-Provider.

Schreib- und Listenoperationen verlangen einen authentifizierten
`Fahrgastrechte.Accounts.Scope`. Die aktive Quelldatei wird über eine private,
zufällige Speicher-ID adressiert und nie direkt durch den Webserver
ausgeliefert.

Geprüft wird dabei ausschließlich, *dass* ein Benutzer angemeldet ist, nicht
*welcher*: Referenzdaten sind installationsweite Betriebsdaten ohne
Rollentrennung. Das ist eine bewusste Entscheidung und in
[ADR 0005](../decisions/0005-installation-trust-zone.md) samt ihrer Grenzen
festgehalten. Für benutzerbezogene Daten gilt sie ausdrücklich nicht.

## Aktivierung und Historie

Uploads werden zuerst vollständig validiert und anschließend in den privaten
Dateispeicher kopiert. Erst danach setzt eine Datenbanktransaktion die bisher
aktive Version auf inaktiv und veröffentlicht die neue Version. Scheitert die
Transaktion, wird die neu kopierte Datei wieder entfernt. Frühere Dateien und
Metadaten bleiben erhalten.

Für Formulare werden HTTPS-Quelle, Versionsname, Dateigröße, PDF-/A4-Struktur,
Verschlüsselung, alle bekannten AcroForm-Felder und deren erwartete
Radio-Auswahlwerte geprüft. Für Bahn-Vorhersage werden Versionsname, Dateigröße,
Pflichtspalten, mindestens ein verwertbarer Zeitwert sowie die Abdeckung
geprüft. Gespeichert werden unter anderem SHA-256, Originaldateiname,
Aktivierungszeit, Uploader und quellspezifische Metadaten.

## Fallback und Betrieb

Ohne UI-verwaltetes Formular verwendet `Exports` weiterhin die mitgelieferte
beziehungsweise über `FORM_TEMPLATE_PATH` konfigurierte, gepinnte Vorlage.
Ohne UI-verwaltetes Bahn-Archiv verwendet der Provider weiterhin
`BAHNVORHERSAGE_DATA_PATH` und `BAHNVORHERSAGE_DATASET_VERSION`.

Die Dateien liegen gemeinsam mit privaten Dokumenten außerhalb der Releases
und werden vom vorhandenen verschlüsselten Backup- und Restore-Ablauf erfasst.
Die Versionsmetadaten liegen in PostgreSQL.
