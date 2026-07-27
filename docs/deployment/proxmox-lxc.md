# Bereitstellung auf Proxmox LXC

Die Anwendung kann mit
[`scripts/deploy/proxmox-lxc.sh`](../../scripts/deploy/proxmox-lxc.sh)
direkt von einem Proxmox-VE-Knoten aus in einem unprivilegierten Debian-LXC
bereitgestellt werden. Das Script erstellt Container, Datenbank, OTP-Release und
systemd-Dienst. Bei einem Update bleibt die bestehende Secret- und
Datenbankkonfiguration erhalten.

## Voraussetzungen

- Proxmox VE mit `pct`, `pveam` und Zugriff auf ein Debian-12- oder
  Debian-13-Template
- ein Storage für Container-Templates (standardmäßig `local`)
- ein Storage für das Root-Dateisystem (standardmäßig `local-lvm`)
- eine Netzwerk-Bridge (standardmäßig `vmbr0`) mit DHCP oder einer expliziten
  IP-Konfiguration
- Internetzugriff aus dem LXC auf Debian-, GitHub-, Hex- und Toolchain-Quellen
- mindestens 4 GiB RAM, 4 vCPU und 16 GiB Speicherplatz; die erste
  Bereitstellung kompiliert Erlang/OTP und kann einige Zeit dauern

Der Proxmox-Host benötigt weder Elixir noch PostgreSQL.

## Erstbereitstellung

Das Script muss als `root` auf dem Proxmox-Knoten aus einem Checkout dieses
Repositories gestartet werden:

```bash
PHX_HOST=fahrgastrechte.example.org \
  scripts/deploy/proxmox-lxc.sh
```

Ohne `VMID` verwendet das Script die nächste freie Proxmox-Cluster-ID. Ein
vollständiges Beispiel mit statischer IP:

```bash
VMID=240 \
CT_HOSTNAME=fahrgastrechte \
PHX_HOST=fahrgastrechte.example.org \
IP_CONFIG='ip=192.168.1.40/24,gw=192.168.1.1' \
ROOTFS_STORAGE=local-lvm \
scripts/deploy/proxmox-lxc.sh
```

Alle Optionen zeigt:

```bash
scripts/deploy/proxmox-lxc.sh --help
```

Das Script:

1. lädt bei Bedarf ein aktuelles Debian-Template,
2. erstellt einen unprivilegierten LXC ohne Nesting,
3. installiert PostgreSQL und die in `.tool-versions` festgelegte Toolchain,
4. erzeugt Datenbankzugang, `SECRET_KEY_BASE` und
   `FIELD_ENCRYPTION_KEY` direkt im LXC,
5. baut eine OTP-Release, führt Ecto-Migrationen aus und
6. startet die App als eingeschränkten Benutzer über systemd.

Secrets liegen nur unter
`/etc/fahrgastrechte/fahrgastrechte.env` (Gruppe `fahrgastrechte`, Modus `0640`).
Sie werden weder in Git geschrieben noch auf dem Proxmox-Host ausgegeben.

## Netzwerk und TLS

Phoenix lauscht im Container auf `4000/tcp`. In Produktion erzwingt die App HTTPS,
terminiert TLS aber nicht selbst. Ein Reverse-Proxy muss daher
`https://<PHX_HOST>` auf `http://<LXC-IP>:4000` weiterleiten und mindestens diese
Header setzen:

```text
Host: fahrgastrechte.example.org
X-Forwarded-Proto: https
X-Forwarded-For: <Client-IP>
```

Port 4000 sollte über Proxmox-Firewall oder Netzsegmentierung ausschließlich für
den Reverse-Proxy erreichbar sein. Zertifikate und DNS müssen vor dem öffentlichen
Betrieb eingerichtet werden.

## Update

Die aktuelle Instanz kann mit Container-ID und gewünschtem Git-Ref aktualisiert
werden:

```bash
scripts/deploy/update-proxmox-lxc.sh 240 v0.2.0
```

Ohne zweiten Parameter wird der aktuelle Stand von `main` installiert:

```bash
scripts/deploy/update-proxmox-lxc.sh 240
```

Der optionale `APP_REF` kann ein Branch, Tag oder anderer von Git abrufbarer Ref
sein. Repository, externer Hostname, Datenbankzugang und Verschlüsselungs-Secrets
werden aus der bestehenden Installation übernommen. Das Script baut eine neue
Release unter `/opt/fahrgastrechte/releases/<commit>-<zeitstempel>`, migriert
die Datenbank und schaltet anschließend den `current`-Symlink um. Ältere
Releases bleiben zunächst für eine manuelle Rückkehr erhalten.

Vor einem Produktionsupdate sollte ein Proxmox-Snapshot oder ein geprüftes
PostgreSQL-Backup erstellt werden. Datenbankmigrationen werden nicht automatisch
zurückgerollt.

## Betrieb und Fehlerdiagnose

Die wichtigsten Befehle auf dem Proxmox-Host:

```bash
pct exec 240 -- systemctl status fahrgastrechte
pct exec 240 -- journalctl -u fahrgastrechte -n 100 --no-pager
pct exec 240 -- curl -H 'Host: localhost' http://127.0.0.1:4000/
```

Die lokale Datenbank wird vom Script gemeinsam mit dem App-Dienst gestartet. Für
Backups kann beispielsweise `pg_dump` im Container verwendet und das Ergebnis auf
einen vom Proxmox-Backup erfassten Speicher übertragen werden.
