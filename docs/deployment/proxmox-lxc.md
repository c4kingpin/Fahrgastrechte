# Bereitstellung direkt im LXC

Der Installer wird als `root` direkt in einem bereits vorhandenen Debian-LXC
ausgeführt. Er benötigt keine Proxmox-Werkzeuge und greift weder auf den
Proxmox-Host noch auf dessen API zu. Die Erstellung des Containers sowie dessen
VMID-, Storage-, Netzwerk- und Ressourcen-Konfiguration bleiben Aufgabe der
jeweiligen Virtualisierungsumgebung.

Die konkrete TLS-/Firewall-Konfiguration steht unter
[`zoraxy.md`](zoraxy.md). Backup, Restore, Migration, Rollback, Secrets und
Ressourcenlimits beschreibt das [`Betriebshandbuch`](operations.md); die
praktische Freigabe wird mit der
[`C07-Betriebsabnahme`](acceptance.md) protokolliert.

## Schnellinstallation

### Produktionsinstallation (gepinnter Commit)

Als `root` in der Shell des LXC: Installer herunterladen, Prüfsumme
kontrollieren, erst danach ausführen — gegen einen geprüften, unveränderlichen
Commit-SHA statt gegen den sich laufend ändernden `main`-Branch. Es gibt
aktuell keine Release-Tags im Repository; ein vollständiger Commit-SHA ist der
heute nutzbare stabile Referenzpunkt:

```bash
COMMIT=<geprüfter vollständiger Commit-SHA>
curl -fsSL -o fahrgastrechte-install.sh \
  "https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/${COMMIT}/install/fahrgastrechte-install.sh"
sha256sum fahrgastrechte-install.sh   # gegen eine unabhängig bestätigte Quelle prüfen
PHX_HOST=fahrgastrechte.example.org \
APP_REF="$COMMIT" \
INSTALLER_REF="$COMMIT" \
  bash fahrgastrechte-install.sh
```

`APP_REF` bestimmt den ausgecheckten Anwendungsstand, `INSTALLER_REF` den Stand
des Installer-Scripts selbst, das jedes künftige `update` erneut herunterlädt
— beide sollten auf denselben geprüften Commit zeigen.

### Schnellstart für Evaluierung

Der folgende Einzeiler führt ungeprüft den jeweils aktuellen Stand von `main`
als `root` aus — **nur für Evaluierung/Entwicklung geeignet, kein
Produktionsweg**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/main/install/fahrgastrechte-install.sh)"
```

Der öffentliche Phoenix-Hostname ist standardmäßig `fahrgastrechte.local` und
kann direkt beim Start gesetzt werden:

```bash
PHX_HOST=fahrgastrechte.example.org \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/main/install/fahrgastrechte-install.sh)"
```

Vor der Installation können die Voraussetzungen ohne Änderungen geprüft werden:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/main/install/fahrgastrechte-install.sh)" -- --check
```

> Ein `curl | bash`-Einzeiler führt den heruntergeladenen Stand ungeprüft als
> `root` aus. Für Produktion immer den Weg oben verwenden: Installer
> herunterladen, `sha256sum` gegen eine unabhängig bestätigte Quelle
> vergleichen, erst danach mit einem geprüften, vollständigen Commit-SHA als
> `APP_REF`/`INSTALLER_REF` ausführen.

## Aufbau des Deployments

1. [`install/fahrgastrechte-install.sh`](../../install/fahrgastrechte-install.sh)
   prüft, dass es in einem Debian-LXC mit systemd läuft. Anschließend installiert
   es PostgreSQL und die Toolchain, baut die OTP-Release, migriert die Datenbank
   und richtet systemd ein.
2. Der Installer legt `fahrgastrechte-update` und den kurzen Alias `update` unter
   `/usr/local/bin` an. Derselbe Installer übernimmt danach idempotent alle
   Aktualisierungen.
3. [`ct/fahrgastrechte.sh`](../../ct/fahrgastrechte.sh) bleibt als kompatibler
   Bootstrap erhalten, erstellt aber keinen LXC mehr und startet ebenfalls den
   Installer im aktuellen Container.

Für lokale Repository-Checkouts steht
[`scripts/deploy/provision-lxc.sh`](../../scripts/deploy/provision-lxc.sh) als
Wrapper zur Verfügung.

## Voraussetzungen

- bereits erstellter Debian-LXC (Debian 12 oder 13) mit systemd
- Ausführung als `root` innerhalb des Containers
- `curl` und Internetzugriff auf Debian-, GitHub-, Hex- und Toolchain-Quellen
- mindestens 2 GiB RAM, 2 vCPU und 8 GiB Speicherplatz für Installation und
  spätere Updates
- vom Reverse-Proxy erreichbares LXC-Netzwerk

Die erste Installation kompiliert die in `.tool-versions` festgelegte
Erlang-/Elixir-Version und kann deshalb einige Zeit dauern. Die Mindestwerte
berücksichtigen diesen Build; für den reinen App-Betrieb wäre weniger möglich,
würde aber spätere Updates unnötig störanfällig machen.

## Was im Container eingerichtet wird

- lokales PostgreSQL mit eigener Datenbank und eigenem Benutzer
- zufälliges Datenbankpasswort, `SECRET_KEY_BASE` und
  `FIELD_ENCRYPTION_KEY`
- persistenter Dokumentenspeicher unter `/var/lib/fahrgastrechte/documents`
- App-Quellcode unter `/opt/fahrgastrechte/source`
- versionierte Releases unter `/opt/fahrgastrechte/releases`
- systemd-Dienst `fahrgastrechte.service` unter einem eingeschränkten
  Service-Benutzer
- täglicher `fahrgastrechte-backup.timer` für gemeinsame, Age-verschlüsselte
  Backups von PostgreSQL, Dokumenten, Runtime-Secrets und Formulartemplate
- root-only Kommandos `fahrgastrechte-backup`, `fahrgastrechte-restore` und
  `fahrgastrechte-rollback`

Secrets liegen nur in
`/etc/fahrgastrechte/fahrgastrechte.env` (Gruppe `fahrgastrechte`,
Modus `0640`). Sie werden weder in Git geschrieben noch in der
Installer-Ausgabe offengelegt.

## Updates

Innerhalb des Containers installiert ein argumentloser `update`-Aufruf erneut
den zuletzt verwendeten Stand: ein gepinnter Commit bleibt gepinnt (echtes
No-Op), ein bewusst verfolgter Branch wie `main` aktualisiert sich auf dessen
neuesten Commit:

```bash
update
```

Ein anderer Commit kann explizit angegeben werden:

```bash
update <commit-sha>
```

Repository, externer Hostname, Datenbankzugang und Verschlüsselungs-Secrets werden
bei Updates beibehalten. Das Script baut zunächst eine neue Release, führt die
Migrationen aus und schaltet dann den `current`-Symlink um. Schlägt der
Healthcheck fehl, wird die vorherige App-Release wieder aktiviert. Bereits
ausgeführte Datenbankmigrationen können dabei nicht automatisch zurückgerollt
werden. Vor jeder Migration wird automatisch ein verschlüsseltes Backup
erstellt; ein manueller Rollback erzeugt ebenfalls zuerst ein Backup.

Für Releases ausschließlich einen geprüften, vollständigen Commit-SHA
verwenden (Release-Tags gibt es aktuell nicht im Repository). Proxmox-Snapshot
und extern repliziertes Backup bleiben zusätzliche Schutzschichten.

## Netzwerk und TLS

Phoenix lauscht im Container auf `4000/tcp`. Ein TLS-Reverse-Proxy muss
`https://<PHX_HOST>` auf `http://<LXC-IP>:4000` weiterleiten und mindestens
diese Header setzen:

```text
Host: fahrgastrechte.example.org
X-Forwarded-Proto: https
X-Forwarded-For: <Client-IP>
```

Port 4000 sollte über die Firewall der Virtualisierungsumgebung oder über
Netzsegmentierung nur für den Reverse-Proxy erreichbar sein.

Host-/Forwarded-Header, Firewall und LiveView-WebSocket werden nach
[`zoraxy.md`](zoraxy.md) konfiguriert und mit
`scripts/deploy/smoke-test.sh` praktisch geprüft.

## Betrieb und Diagnose

```bash
systemctl status fahrgastrechte
journalctl -u fahrgastrechte -n 100 --no-pager
curl \
  -H 'Host: fahrgastrechte.example.org' \
  -H 'X-Forwarded-Proto: https' \
  http://127.0.0.1:4000/readyz
fahrgastrechte-backup
```

Die verschlüsselten Backup-Dateien müssen regelmäßig auf ein getrenntes System
repliziert und per isoliertem Restore-Test geprüft werden. Vollständige Abläufe
und Aufbewahrung stehen im [`Betriebshandbuch`](operations.md).
