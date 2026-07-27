# Bereitstellung auf Proxmox LXC

Die Bereitstellung folgt dem Bedienmodell der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/):
Ein einzelner Befehl auf dem Proxmox-Host öffnet einen Standard-/Erweitert-Dialog,
erstellt einen unprivilegierten Debian-LXC und installiert die Anwendung darin.
Ein Repository-Checkout auf dem Proxmox-Host ist nicht erforderlich.

## Schnellinstallation

Als `root` in der Shell eines Proxmox-VE-Knotens:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/main/ct/fahrgastrechte.sh)"
```

Im Dialog stehen zwei Modi zur Auswahl:

- **Standard** verwendet die nächste freie VMID, Debian 13, DHCP, `vmbr0`,
  `local`/`local-lvm`, 4 vCPU, 4 GiB RAM und 16 GiB Disk.
- **Erweitert** fragt VMID, Hostnamen, Git-Ref, Storages, Bridge,
  IP-Konfiguration und Ressourcen ab.

Der öffentliche Phoenix-Hostname ist standardmäßig
`fahrgastrechte.local`. Er kann schon beim Start gesetzt werden:

```bash
PHX_HOST=fahrgastrechte.example.org \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/main/ct/fahrgastrechte.sh)"
```

Eine Installation ohne Dialog ist ebenfalls möglich:

```bash
VMID=240 \
PHX_HOST=fahrgastrechte.example.org \
IP_CONFIG='ip=192.168.1.40/24,gw=192.168.1.1' \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/main/ct/fahrgastrechte.sh)" -- --defaults
```

Mit `--advanced` wird direkt der erweiterte Dialog geöffnet. `--dry-run`
zeigt nur die resultierende Konfiguration an.

Wurde eine Erstinstallation nach der Container-Erstellung unterbrochen, kann
derselbe Container gezielt weiterverwendet werden:

```bash
VMID=104 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/main/ct/fahrgastrechte.sh)" -- --defaults --reuse
```

`--reuse` verlangt immer eine explizite VMID und erstellt keinen neuen
Container. Für eine bereits vollständig installierte Instanz ist stattdessen
das unten beschriebene `update`-Kommando vorgesehen.

> Ein `curl | bash`-Einzeiler führt den aktuellen Stand des angegebenen
> Branches als `root` aus. Für reproduzierbare Produktionsinstallationen
> sollte ein geprüfter Release-Tag oder Commit-SHA für Einstieg, Installer und
> App verwendet und das Script vor der Ausführung kontrolliert werden:
>
> ```bash
> INSTALLER_REF=v0.2.0 APP_REF=v0.2.0 \
>   bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/v0.2.0/ct/fahrgastrechte.sh)" -- --defaults
> ```

## Aufbau des Deployments

Die Trennung entspricht dem Community-Scripts-Muster:

1. [`ct/fahrgastrechte.sh`](../../ct/fahrgastrechte.sh) läuft ausschließlich
   auf dem Proxmox-Host. Es sammelt die Einstellungen, lädt ein Debian-Template
   und erstellt den LXC.
2. [`install/fahrgastrechte-install.sh`](../../install/fahrgastrechte-install.sh)
   wird in den Container übertragen. Es installiert PostgreSQL und die
   Toolchain, baut die OTP-Release, migriert die Datenbank und richtet systemd
   ein.
3. Der Container-Installer legt `fahrgastrechte-update` und den kurzen Alias
   `update` unter `/usr/local/bin` an. Derselbe Installer übernimmt danach
   idempotent alle Aktualisierungen.

Die vorhandenen Scripte unter `scripts/deploy/` bleiben als Wrapper für lokale
Checkouts und bestehende Automatisierung erhalten.

## Voraussetzungen

- Proxmox VE mit `pct`, `pveam`, `pvesh` und `curl`
- Storage für Container-Templates (Standard: `local`)
- Storage für das Root-Dateisystem (Standard: `local-lvm`)
- Netzwerk-Bridge (Standard: `vmbr0`) mit DHCP oder statischer Konfiguration
- Internetzugriff aus dem LXC auf Debian-, GitHub-, Hex- und Toolchain-Quellen
- mindestens 4 GiB RAM, 4 vCPU und 16 GiB Speicherplatz

Die erste Installation kompiliert die in `.tool-versions` festgelegte
Erlang-/Elixir-Version und kann deshalb einige Zeit dauern. Auf dem
Proxmox-Host selbst werden Elixir und PostgreSQL nicht installiert.

## Was im Container eingerichtet wird

- lokales PostgreSQL mit eigener Datenbank und eigenem Benutzer
- zufälliges Datenbankpasswort, `SECRET_KEY_BASE` und
  `FIELD_ENCRYPTION_KEY`
- App-Quellcode unter `/opt/fahrgastrechte/source`
- versionierte Releases unter `/opt/fahrgastrechte/releases`
- systemd-Dienst `fahrgastrechte.service` unter einem eingeschränkten
  Service-Benutzer

Secrets liegen nur in
`/etc/fahrgastrechte/fahrgastrechte.env` (Gruppe `fahrgastrechte`,
Modus `0640`). Sie werden weder in Git geschrieben noch auf dem
Proxmox-Host ausgegeben.

## Updates

Am einfachsten wird innerhalb des Containers aktualisiert:

```bash
pct enter 240
update
```

`update` installiert den aktuellen Stand von `main`. Ein Branch, Tag oder
Commit kann explizit angegeben werden:

```bash
update v0.2.0
```

Alternativ direkt vom Proxmox-Host:

```bash
pct exec 240 -- update v0.2.0
```

Für einen lokalen Repository-Checkout steht weiterhin ein Wrapper zur Verfügung:

```bash
scripts/deploy/update-proxmox-lxc.sh 240 v0.2.0
```

Repository, externer Hostname, Datenbankzugang und Verschlüsselungs-Secrets werden
bei Updates beibehalten. Das Script baut zunächst eine neue Release, führt die
Migrationen aus und schaltet dann den `current`-Symlink um. Schlägt der
Healthcheck fehl, wird die vorherige App-Release wieder aktiviert. Bereits
ausgeführte Datenbankmigrationen können dabei nicht automatisch zurückgerollt
werden.

Vor einem Produktionsupdate sollte deshalb ein Proxmox-Snapshot oder ein
geprüftes PostgreSQL-Backup erstellt werden.

## Netzwerk und TLS

Phoenix lauscht im Container auf `4000/tcp`. Ein TLS-Reverse-Proxy muss
`https://<PHX_HOST>` auf `http://<LXC-IP>:4000` weiterleiten und mindestens
diese Header setzen:

```text
Host: fahrgastrechte.example.org
X-Forwarded-Proto: https
X-Forwarded-For: <Client-IP>
```

Port 4000 sollte über Proxmox-Firewall oder Netzsegmentierung nur für den
Reverse-Proxy erreichbar sein.

## Betrieb und Diagnose

```bash
pct exec 240 -- systemctl status fahrgastrechte
pct exec 240 -- journalctl -u fahrgastrechte -n 100 --no-pager
pct exec 240 -- curl -H 'Host: localhost' http://127.0.0.1:4000/
```

Für Backups kann `pg_dump` im Container verwendet und das Ergebnis auf einen
vom Proxmox-Backup erfassten Speicher übertragen werden.
