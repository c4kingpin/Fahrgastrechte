# C07-Betriebsabnahme

Dieses Protokoll wird pro Produktionsumgebung ausgefüllt. Es enthält nur
Zeitpunkte, Versionen, Hashes und Ja/Nein-Ergebnisse, niemals Secrets,
personenbezogene Daten oder PDFs.

## Identifikation

- Datum / Prüfer:
- Proxmox-Version / Node:
- LXC-VMID / Debian-Version:
- App-Commit (vollständiger SHA):
- Zoraxy-Version / öffentlicher Host:
- synthetischer Referenzdatensatz:

## Reproduzierbare Release

- [ ] Installation aus festem Commit oder signiertem Tag erfolgreich
- [ ] `systemctl is-active fahrgastrechte` ist `active`
- [ ] `GET /healthz` lokal erfolgreich
- [ ] `GET /readyz` lokal erfolgreich
- [ ] Neustart des LXC erhält Datenbank und synthetisches Dokument
- [ ] Neuaufbau eines Test-LXC plus Restore erhält dieselben Referenzhashes

## Netz und Proxy

- [ ] Extern ist nur Zoraxy über 80/443 erreichbar
- [ ] TCP/4000 ist von Zoraxy erreichbar
- [ ] TCP/4000 ist aus anderem Client-Netz blockiert
- [ ] TCP/5432 ist aus Zoraxy- und Client-Netz blockiert
- [ ] TLS-Zertifikat und Weiterleitung HTTP → HTTPS sind korrekt
- [ ] `scripts/deploy/smoke-test.sh https://HOST` ist erfolgreich
- [ ] LiveView bleibt über WebSocket verbunden
- [ ] Host- und Origin-Abweichungen werden abgelehnt

## Identität

- [ ] Authentik-Issuer, Redirect-URI und Post-Logout-URI verwenden HTTPS
- [ ] Login, Logout und erneuter Login erfolgreich
- [ ] Session-Cookie ist `Secure`, `HttpOnly`, `SameSite=Lax`
- [ ] ungültiger Redirect-/Origin-Host wird nicht akzeptiert

Bis zur Implementierung des in `docs/integrations/authentik.md` beschriebenen
Adapters bleiben diese Punkte bewusst offen; eine Zoraxy-Anmeldung ersetzt sie
nicht.

## Backup und Restore

- [ ] manueller Backup-Lauf erfolgreich
- [ ] Backup ist ausschließlich als `.age` außerhalb des LXC gespeichert
- [ ] private Age-Identität liegt getrennt und zugriffsgeschützt vor
- [ ] Restore in isoliertem Test-LXC erfolgreich
- [ ] Datenbankanzahl und synthetische Dokumenthashes stimmen überein
- [ ] Readiness ist nach Restore erfolgreich
- [ ] Timer, Aufbewahrung und externes Replikationsziel geprüft

## Upgrade und Fehlerwege

- [ ] Update erzeugt vor Migration automatisch ein Backup
- [ ] Update auf geprüften Folgestand erfolgreich
- [ ] absichtlich fehlerhafte Readiness reaktiviert die vorige App-Release
- [ ] manueller `fahrgastrechte-rollback` erfolgreich
- [ ] DB-API-Ausfall führt zum manuellen fachlichen Ersatzweg
- [ ] PDF-Timeout/Ressourcenlimit beendet den Prozess ohne Dienstabsturz

## Datenschutz und Betrieb

- [ ] Journal enthält keine Tokens, Bankdaten, Dokumentpfade oder PDF-Inhalte
- [ ] Runtime-Environment ist `root:fahrgastrechte 0640`
- [ ] Dokumentverzeichnis ist nur für den Service-Benutzer zugänglich
- [ ] systemd-Ressourcenlimits sind aktiv
- [ ] A4- und DIN-lang-Druckprobe des Referenzexports bestanden

## Ergebnis

- Ergebnis: bestanden / nicht bestanden
- offene Punkte und Ticket-IDs:
- nächste Restore-Test-Fälligkeit:
