# Fahrgastrechte

Webanwendung zur Unterstützung bei Ansprüchen aus Fahrgastrechten. Das Repository
enthält die startbereite technische Basis; die Fachfunktionen werden darauf
schrittweise aufgebaut.

## Technischer Stack

- Elixir 1.20.2 und Erlang/OTP 28.3
- Phoenix 1.8 mit LiveView
- PostgreSQL
- Tailwind CSS 4 und esbuild (über Mix verwaltet)

Die verbindlichen Laufzeitversionen stehen in [`.tool-versions`](.tool-versions).
Sie können beispielsweise mit `asdf` oder `mise` installiert werden.

## Lokale Einrichtung

Vorausgesetzt werden Elixir/Erlang in den angegebenen Versionen und ein laufendes
PostgreSQL. Die Standardkonfiguration erwartet den Benutzer `postgres` mit dem
Passwort `postgres` auf `localhost:5432`.

```bash
git clone https://github.com/c4kingpin/Fahrgastrechte.git
cd fahrgastrechte
mix setup
mix phx.server
```

Danach ist die Anwendung unter <http://localhost:4000> erreichbar.

### Zugriff aus dem lokalen Netz

Der Entwicklungsserver lauscht auf allen IPv4-Interfaces (`0.0.0.0`). Geräte im
Subnetz `192.168.1.0/24` erreichen ihn über die LAN-Adresse des Entwicklungsrechners:

```text
http://192.168.1.X:4000
```

`192.168.1.X` muss dabei durch die tatsächliche Host-Adresse ersetzt werden. Unter
Linux zeigt beispielsweise `ip -4 address` die verfügbaren IPv4-Adressen an.

Die Bindung an `0.0.0.0` allein beschränkt den Zugriff nicht auf ein bestimmtes
Subnetz. Auf einem Ubuntu-System kann Port 4000 mit UFW gezielt für das lokale Netz
freigegeben werden:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 4000 proto tcp
sudo ufw status numbered
```

Es sollte keine allgemeinere Firewall-Regel existieren, die Port 4000 auch für
andere Netze freigibt. Diese Konfiguration ist nur für die Entwicklung vorgesehen.

### Datenbankkonfiguration

Die lokalen Standardwerte können über Umgebungsvariablen überschrieben werden:

| Variable | Standardwert (Entwicklung) |
| --- | --- |
| `DATABASE_HOST` | `localhost` |
| `DATABASE_PORT` | `5432` |
| `DATABASE_USER` | `postgres` |
| `DATABASE_PASSWORD` | `postgres` |
| `DATABASE_NAME` | `fahrgastrechte_dev` |
| `DATABASE_TEMPLATE` | `template0` |

Beispiel:

```bash
export DATABASE_USER=mein_benutzer
export DATABASE_PASSWORD=mein_passwort
mix setup
```

## Entwicklung

```bash
mix phx.server        # Entwicklungsserver starten
iex -S mix phx.server # Server mit interaktiver Elixir-Shell
mix test              # Tests ausführen
mix format            # Elixir-Code formatieren
mix precommit         # vollständige Prüfung vor einem Commit
```

GitHub Actions prüft bei Pull Requests und Änderungen an `main` Formatierung,
Kompilierung ohne Warnungen und Tests gegen PostgreSQL.

## Umsetzungsplan

Das abgestimmte Produktkonzept und die in getrennte Agenten-Aufträge zerlegte
Umsetzungsplanung stehen unter
[`docs/implementation-plan/`](docs/implementation-plan/README.md).
Der auf den aktuellen Implementierungsstand ausgerichtete Ausbau ist dort als
[`Wellenplan`](docs/implementation-plan/waves.md) mit reproduzierbarer
[`Baseline`](docs/implementation-plan/baseline-2026-07-30.md) dokumentiert.

Die Ergebnisse der technischen Voruntersuchung C00 stehen unter
[`docs/spikes/c00/`](docs/spikes/c00/README.md); verbindliche technische
Entscheidungen werden als
[`Architecture Decision Records`](docs/decisions/README.md) geführt.

Die produktive Authentik-Anbindung, der lokale Entwicklungs-Scope und die
benötigten Provider- sowie Runtime-Einstellungen sind unter
[`docs/integrations/authentik.md`](docs/integrations/authentik.md).

## Bereitstellung

Für Proxmox VE steht eine automatisierte Bereitstellung in einem unprivilegierten
Debian-LXC zur Verfügung. Voraussetzungen, Erstinstallation, Updates und
Betriebshinweise stehen unter
[`docs/deployment/proxmox-lxc.md`](docs/deployment/proxmox-lxc.md). Zoraxy/TLS,
verschlüsselte Backups, Restore, Rollback und die Betriebsabnahme sind im selben
Dokumentationsbereich verlinkt.

Die Community-Scripts-artige Installation wird direkt als `root` auf dem
Proxmox-Host gestartet:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/main/ct/fahrgastrechte.sh)"
```

Danach lässt sich die Instanz innerhalb des Containers mit optionalem Git-Ref
aktualisieren:

```bash
update v0.2.0
```

## Nützliche Dokumentation

- [Phoenix Guides](https://hexdocs.pm/phoenix/overview.html)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Ecto](https://hexdocs.pm/ecto/)
