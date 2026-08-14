# Fahrgastrechte

Private Webanwendung zum Erstellen und Verwalten von Fahrgastrechte-Anträgen für
deutsche DB-Flexpreis-Reisen. Der geführte Ablauf übernimmt Daten aus Ticket und
Rechnung, dokumentiert geplante und tatsächliche Reise, erzeugt ein
druckfertiges Gesamt-PDF und verfolgt den Bearbeitungsstatus.

## Funktionsumfang

- Anmeldung über Authentik/OIDC mit strikt benutzerbezogenen Daten
- Reisendenprofil mit verschlüsselt gespeicherter IBAN und BIC
- sechs fortsetzbare Schritte vom PDF-Upload über die Übernahme erkannter Falldaten bis zur Prüfung
- nachvollziehbare Datenvorschläge mit manueller Prüfung und Korrektur
- geplante und tatsächliche Reise mit Verspätungs- und Ausfallerfassung
- versionierte Ausgabe aus Deckblatt, offiziellem Formular, Ticket und Rechnung
- geprüfte Aktualisierung von Formular und Bahn-Vorhersage-CSV im Browser
- Statusverlauf von Entwurf über Versand bis zum Abschluss

Bewusst außerhalb der ersten Produktstufe liegen unter anderem
Anspruchsberechnung, Zusatzkosten, OCR, mehrere Reisende und eine direkte
digitale Übermittlung an die Deutsche Bahn.

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

## Dokumentation

| Thema | Einstieg |
| --- | --- |
| Vollständige Navigation und Dokumentstatus | [Dokumentationsindex](docs/README.md) |
| Architektur, Fachgrenzen und Produktumfang | [Technische Übersicht](docs/architecture.md) |
| Claims, Dokumente, Rail, Referenzdaten und Exports | [Kontextschnittstellen](docs/interfaces/README.md) |
| Authentik/OIDC und Feldverschlüsselung | [Authentik-Integration](docs/integrations/authentik.md) |
| Installation im Debian-LXC | [Deployment-Einstieg](docs/deployment/proxmox-lxc.md) |
| Backup, Restore, Updates und Diagnose | [Betriebshandbuch](docs/deployment/operations.md) |
| Getroffene Architekturentscheidungen | [Architecture Decision Records](docs/decisions/README.md) |
| Erkannte technische Schulden und Reihenfolge | [Refactoring-Roadmap](docs/refactoring-roadmap.md) |
| Historischer Ausbau- und Abnahmeplan | [Umsetzungsplan](docs/implementation-plan/README.md) |

### Planung und technische Voruntersuchungen

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

Die Anwendung wird direkt in einem bereits vorhandenen Debian-LXC installiert.
Der Installer benötigt keinen Zugriff auf den Proxmox-Host und erstellt oder
verändert keine Container-Konfiguration. Voraussetzungen, Erstinstallation,
Updates und Betriebshinweise stehen unter
[`docs/deployment/proxmox-lxc.md`](docs/deployment/proxmox-lxc.md). Zoraxy/TLS,
verschlüsselte Backups, Restore, Rollback und die Betriebsabnahme sind im selben
Dokumentationsbereich verlinkt.

Die Installation wird als `root` innerhalb des LXC gestartet:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/main/install/fahrgastrechte-install.sh)"
```

Der öffentliche Hostname kann beim Start gesetzt werden:

```bash
PHX_HOST=fahrgastrechte.example.org \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/main/install/fahrgastrechte-install.sh)"
```

Danach lässt sich die Instanz im Container mit optionalem Git-Ref aktualisieren:

```bash
update v0.2.0
```

## Externe Referenzen

- [Phoenix Guides](https://hexdocs.pm/phoenix/overview.html)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Ecto](https://hexdocs.pm/ecto/)
