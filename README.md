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
git clone https://github.com/c4kingpin/fahrgastrechte.git
cd fahrgastrechte
mix setup
mix phx.server
```

Danach ist die Anwendung unter <http://localhost:4000> erreichbar.

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

## Nützliche Dokumentation

- [Phoenix Guides](https://hexdocs.pm/phoenix/overview.html)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Ecto](https://hexdocs.pm/ecto/)
