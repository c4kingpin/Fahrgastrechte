# Betriebshandbuch

## Laufzeit und Persistenz

Der Installer richtet folgende dauerhaft getrennte Pfade ein:

| Inhalt | Pfad | Eigentümer/Modus |
| --- | --- | --- |
| Runtime-Secrets | `/etc/fahrgastrechte/fahrgastrechte.env` | `root:fahrgastrechte`, `0640` |
| Age-Backup-Identität | `/etc/fahrgastrechte/backup.agekey` | `root:root`, `0600` |
| PostgreSQL | Debian-PostgreSQL-Datenverzeichnis | `postgres` |
| Dokumente | `/var/lib/fahrgastrechte/documents` | `fahrgastrechte`, `0750` |
| Formulartemplates | `/var/lib/fahrgastrechte/form-templates` | `root:fahrgastrechte`, `0750` |
| verschlüsselte Backups | `/var/backups/fahrgastrechte` | `root:root`, `0700` |
| versionierte Releases | `/opt/fahrgastrechte/releases` | `root:fahrgastrechte` |

Release-Verzeichnisse sind austauschbar; Daten, Secrets und Backups liegen
außerhalb. Ein Neustart oder App-Update verändert die persistenten Pfade nicht.
Für einen vollständigen Neuaufbau müssen PostgreSQL, Dokumente und die
Entschlüsselungsidentität verfügbar sein.

## Secrets und externe Dienste

Der Installer erzeugt Datenbankpasswort, `SECRET_KEY_BASE`,
`FIELD_ENCRYPTION_KEY` und standardmäßig eine lokale Age-Identität. Die drei
Authentik-Werte sind für die Anmeldung gemeinsam erforderlich; optionale DB-API-
und Bahndatenwerte sowie alle gesetzten Werte werden bei Updates bewahrt:

```text
AUTHENTIK_ISSUER
AUTHENTIK_CLIENT_ID
AUTHENTIK_CLIENT_SECRET
DB_CLIENT_ID
DB_API_KEY
BAHNVORHERSAGE_DATA_PATH
BAHNVORHERSAGE_DATASET_VERSION
```

Secrets niemals als Shellargument, in Git, Tickets oder Chat kopieren. Im LXC
die geschützte Environment-Datei mit einem lokalen Editor ändern, Berechtigungen
danach prüfen und den Dienst neu starten:

```bash
stat -c '%U:%G %a' /etc/fahrgastrechte/fahrgastrechte.env
systemctl restart fahrgastrechte
curl -H 'Host: fahrgastrechte.example.org' \
  -H 'X-Forwarded-Proto: https' \
  http://127.0.0.1:4000/readyz
```

Erwartete Berechtigung ist `root:fahrgastrechte 640`. API-/OIDC-Secrets dürfen
nicht in Diagnoseausgaben landen. Phoenix filtert zusätzlich Passwort-, Token-,
IBAN- und BIC-Parameter; Produktionslogs laufen auf Info-Level.

Nach einer Authentik-Änderung zusätzlich Anmeldung, Callback, Zugriff auf
`/antraege`, Abmeldung und Rückkehr zu `/auth/abgemeldet` im Browser prüfen.
`/readyz` bestätigt bewusst nur die lokale Betriebsbereitschaft und ersetzt
keinen OIDC-Smoke-Test.

## Health und Diagnose

- `/healthz` meldet nur, dass der BEAM-/HTTP-Prozess antwortet.
- `/readyz` prüft mit kurzem Timeout PostgreSQL sowie einen Schreib-/Lösch-Probezugriff
  auf den Dokumentenspeicher.

Beide Endpunkte geben ausschließlich Status und Namen fehlgeschlagener
Subsysteme aus, keine Credentials, Pfade oder Dokumentdaten.

```bash
systemctl status fahrgastrechte
systemctl status fahrgastrechte-backup.timer
journalctl -u fahrgastrechte --since today --no-pager
journalctl -u fahrgastrechte-backup --since today --no-pager
```

Logs vor dem Weitergeben auf personenbezogene Inhalte prüfen. Keine Dumps der
Runtime-Environment, Request-Bodies oder Original-PDFs an Supportkanäle hängen.

## Verschlüsselte Backups

`fahrgastrechte-backup.timer` startet täglich um 03:15 Uhr mit bis zu 45 Minuten
zufälliger Verzögerung. Für einen konsistenten gemeinsamen Stand stoppt der Job
die App kurz, erstellt einen PostgreSQL-Custom-Dump und archiviert Dokumente,
Runtime-Secrets sowie das aktive Formulartemplate. Eine SHA-256-Manifestprüfung
wird zusammen mit den Daten per Age verschlüsselt. Standardaufbewahrung: 30
Tage.

Manueller Lauf:

```bash
fahrgastrechte-backup
systemctl list-timers fahrgastrechte-backup.timer
```

Nur Dateien mit Endung `.tar.gz.age` verlassen den Container. Das
Backup-Verzeichnis muss regelmäßig auf Proxmox Backup Server, ein verschlüsseltes
NAS oder ein anderes getrenntes System repliziert werden. Ein Backup nur auf
demselben LXC-Datenträger schützt nicht vor dessen Verlust.

Die private Age-Identität getrennt und zugriffsgeschützt hinterlegen. Ohne sie
ist kein Restore möglich. Bei einem externen Age-Empfänger kann vor der
Erstinstallation `BACKUP_AGE_RECIPIENT` gesetzt werden; dann verbleibt dessen
private Identität ausschließlich im externen Secret Store.

## Restore und Restore-Test

Ein Restore ist absichtlich bestätigungspflichtig und erstellt zunächst ein
Sicherheitsbackup des aktuellen Zustands:

```bash
fahrgastrechte-restore \
  /var/backups/fahrgastrechte/fahrgastrechte-YYYYMMDDTHHMMSSZ.tar.gz.age \
  --confirm
```

Nur wenn der Ist-Zustand so beschädigt ist, dass kein Sicherheitsbackup mehr
möglich ist, darf `--skip-safety-backup` bewusst verwendet werden. Restore
prüft Entschlüsselung und SHA-256-Manifest, ersetzt Datenbank, Dokumente,
Runtime-Secrets und Template, richtet Eigentümer neu ein und verlangt danach
eine erfolgreiche Readiness-Prüfung.

Der vierteljährliche Restore-Test erfolgt nicht auf der Produktivinstanz:

1. LXC aus demselben geprüften App-Ref isoliert neu erstellen.
2. Ein extern verwahrtes verschlüsseltes Backup und die passende Age-Identität
   kontrolliert einspielen.
3. `fahrgastrechte-restore ... --confirm` ausführen.
4. Readiness, Antragsanzahl und SHA-256 eines ausgewählten synthetischen
   Testdokuments gegen das Abnahmeprotokoll prüfen.
5. Test-LXC löschen und Datum, Backupname, App-Commit sowie Ergebnis
   protokollieren – niemals Dateninhalte oder Secrets.

## Upgrade, Migration und Rollback

Im Container installiert ein unveränderlicher Tag oder Commit reproduzierbar:

```bash
update v0.2.0
# oder
update 0123456789abcdef0123456789abcdef01234567
```

Der Ablauf ist: Quellstand holen, Betriebswerkzeuge aktualisieren,
verschlüsseltes Vorab-Backup, OTP-Release bauen, Migrationen ausführen,
`current` atomar umschalten und `/readyz` prüfen. Bei fehlgeschlagener Readiness
wird die vorherige App-Release automatisch reaktiviert.

Manueller App-Rollback:

```bash
fahrgastrechte-rollback
fahrgastrechte-rollback RELEASE-VERZEICHNIS
```

Auch dieser Wechsel erzeugt zuerst ein Backup. Er rollt keine bereits
ausgeführten Datenbankmigrationen zurück. Deshalb müssen Migrationen
rückwärtskompatibel mit mindestens der vorigen App-Release sein. Ein
Datenbank-Rollback erfolgt nur als vollständiger Restore nach dokumentierter
Entscheidung.

## Ressourcen und PDF-Prozesse

Der systemd-Cgroup begrenzt Phoenix einschließlich der gestarteten
PDF-Werkzeuge auf 180 % CPU, 1536 MiB RAM, 256 Tasks und 4096 offene Dateien.
Zusätzlich begrenzt die Anwendung PDF-Größe, Seitenzahl und Kommando-Laufzeit.
Timeouts oder `resource_limit` sind Betriebsereignisse, kein Grund, Limits ohne
Ursachenanalyse pauschal zu erhöhen.

## Offizielles Formulartemplate wechseln

1. Neue offizielle Quelle und Version prüfen; keine per E-Mail zugesandte Datei
   ungeprüft übernehmen.
2. AcroForm-Felder, A4-Abmessungen und aktive Inhalte mit dem C00/C05-PDF-Test
   prüfen.
3. URL, Dateiname, `template_version` und SHA-256 gemeinsam in Code und
   Installer ändern.
4. PDF-Tests und A4-/DIN-lang-Druckprobe durchführen.
5. Version als normalen App-Release ausrollen; das Vorab-Backup enthält das
   vorherige Template.

Historische Exportversionen bleiben mit Template-Version und SHA-256
nachvollziehbar. Ein Templatewechsel erzeugt vorhandene Exporte nicht heimlich
neu.
