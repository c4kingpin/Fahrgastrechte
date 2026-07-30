# Zoraxy, TLS und Netzgrenze

Die Produktionsinstanz hat genau einen öffentlichen Einstieg:
`https://<PHX_HOST>` auf Zoraxy. PostgreSQL lauscht nur im LXC auf Loopback;
Port 4000 des LXC darf ausschließlich aus dem Proxy-Netz erreichbar sein. Das
ist eine Netz-/Firewall-Grenze, keine Authentifizierungsfunktion von Zoraxy.

```text
Internet/LAN-Clients
       │ HTTPS :443
       ▼
    Zoraxy
       │ HTTP :4000, nur Proxy-Netz
       ▼
Phoenix-LXC ── 127.0.0.1:5432 PostgreSQL
       │
       └── /var/lib/fahrgastrechte/documents
```

## Proxy-Regel

In Zoraxy eine HTTP-Reverse-Proxy-Regel mit diesen Werten anlegen:

- Hostname: exakt der Wert von `PHX_HOST`, ohne Schema oder Pfad
- Upstream: `http://<LXC-IP>:4000`
- TLS/ACME: auf Zoraxy terminieren und HTTP auf HTTPS umleiten
- Host-Header: den öffentlichen Hostnamen unverändert weitergeben
- `X-Forwarded-Proto`: `https`
- `X-Forwarded-For`: die bestehende Kette um die Client-IP ergänzen
- WebSocket-Proxy: aktiviert lassen; Zoraxy unterstützt ihn bei HTTP-Regeln
  automatisch

Phoenix erzwingt in Produktion HTTPS anhand von `X-Forwarded-Proto` und
akzeptiert LiveView-WebSockets nur für den konfigurierten `PHX_HOST`. Ein
fehlender Forwarded-Proto-Header zeigt sich als Redirect-Schleife; ein falscher
Host/Origin als abgelehnter WebSocket.

Die Zoraxy-Projektseite dokumentiert automatische WebSocket-Unterstützung und
Custom Headers:
<https://github.com/tobychui/zoraxy>. Für den internen Upstream ist HTTP
beabsichtigt; TLS endet am Proxy innerhalb des kontrollierten Netzes.

## Firewall

Die LXC-Netzkarte wird bereits mit `firewall=1` erstellt. Vor dem öffentlichen
DNS-Umschalten müssen auf Datacenter-/Node- und Container-Ebene Firewalling
aktiv und die eingehenden Regeln überprüft sein. Eine minimale Container-Regel
erlaubt TCP/4000 nur von der statischen Zoraxy-IP bzw. ihrem dedizierten
Proxy-CIDR; die Input-Policy ist ansonsten `DROP`. Es gibt keine Freigabe für
5432 und keine Portweiterleitung direkt zum LXC.

Beispiel über die Proxmox-API-Shell (Werte ersetzen und bestehende Regeln vorher
prüfen):

```bash
pvesh set /nodes/PVE_NODE/lxc/VMID/firewall/options \
  --enable 1 --policy_in DROP --policy_out ACCEPT

pvesh create /nodes/PVE_NODE/lxc/VMID/firewall/rules \
  --type in --action ACCEPT --enable 1 \
  --source ZORAXY_IP/32 --proto tcp --dport 4000 \
  --comment 'Fahrgastrechte via Zoraxy'
```

Je nach DHCP-/IPv6-Konfiguration sind zusätzlich die dafür erforderlichen
Infrastrukturregeln nötig. Die verbindliche Referenz ist die
[Proxmox-VE-Firewall-Dokumentation](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#chapter_pve_firewall).

Prüfung von einem beliebigen anderen Netzteilnehmer:

```bash
nc -vz LXC_IP 4000
nc -vz LXC_IP 5432
```

Beide Zugriffe müssen scheitern. Vom Zoraxy-System muss nur TCP/4000 gelingen.

## Externer Smoke-Test

Nach TLS- und Proxy-Konfiguration aus einem Client-Netz ausführen:

```bash
scripts/deploy/smoke-test.sh https://fahrgastrechte.example.org
```

Das Script prüft Liveness, Readiness, die Startseite und einen echten
HTTP-101-Upgrade für `/live/websocket`. Zusätzlich im Browser prüfen:

1. keine Mixed-Content- oder Origin-Fehler in der Entwicklerkonsole,
2. eine LiveView-Navigation bleibt nach mindestens 60 Sekunden verbunden,
3. Login, Logout und erneuter Login führen über den kanonischen HTTPS-Host,
4. Session-Cookies tragen `Secure`, `HttpOnly` und `SameSite=Lax`.

Der dritte Punkt kann erst abgenommen werden, wenn der in
[`../integrations/authentik.md`](../integrations/authentik.md) beschriebene
OIDC-Adapter implementiert ist. Der aktuelle C01-Stand deaktiviert Anmeldung in
Produktion bewusst; Zoraxy Forward-Auth darf diese fachliche Lücke nicht
verdecken.
