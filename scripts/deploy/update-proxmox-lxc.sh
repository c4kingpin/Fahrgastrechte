#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_INSTALLER_URL="https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/main/install/fahrgastrechte-install.sh"

usage() {
  cat <<'USAGE'
Eine bestehende Fahrgastrechte-Instanz im Proxmox-LXC aktualisieren.

Auf dem Proxmox-Host:

  scripts/deploy/update-proxmox-lxc.sh VMID [APP_REF]

Im Container ist derselbe Vorgang kürzer:

  update [APP_REF]

Ohne APP_REF wird main installiert. Datenbank, Hostname und Secrets bleiben
erhalten. Bei älteren Installationen wird das neue Update-Kommando automatisch
nachgerüstet.
USAGE
}

die() {
  printf '[fahrgastrechte-update] Fehler: %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 1
fi

[[ $EUID -eq 0 ]] || die "Das Script muss als root auf dem Proxmox-Knoten laufen"
command -v pct >/dev/null 2>&1 || die "Benötigtes Kommando fehlt: pct"

vmid="$1"
app_ref="${2:-main}"
[[ "$vmid" =~ ^[1-9][0-9]{2,8}$ ]] || die "Ungültige Container-ID: $vmid"
[[ "$app_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:+-]*$ ]] || die "Ungültiger Git-Ref: $app_ref"
pct config "$vmid" >/dev/null 2>&1 || die "Container ${vmid} wurde nicht gefunden"

if [[ "$(pct status "$vmid")" != "status: running" ]]; then
  printf '[fahrgastrechte-update] Starte Container %s\n' "$vmid"
  pct start "$vmid"
fi

if pct exec "$vmid" -- test -x /usr/local/bin/fahrgastrechte-update; then
  exec pct exec "$vmid" -- /usr/local/bin/fahrgastrechte-update "$app_ref"
fi

printf '[fahrgastrechte-update] Rüste den Update-Helfer im Container nach\n'
exec pct exec "$vmid" -- env APP_REF="$app_ref" /usr/bin/bash -c "set -o pipefail; curl --fail --location --silent --show-error '${DEFAULT_INSTALLER_URL}' | /usr/bin/bash"
