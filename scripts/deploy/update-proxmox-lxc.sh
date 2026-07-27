#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

usage() {
  cat <<'USAGE'
Eine bestehende Fahrgastrechte-Instanz im Proxmox-LXC aktualisieren.

Aufruf:

  scripts/deploy/update-proxmox-lxc.sh VMID [APP_REF]

Beispiele:

  scripts/deploy/update-proxmox-lxc.sh 240
  scripts/deploy/update-proxmox-lxc.sh 240 v0.2.0

Ohne APP_REF wird der aktuelle Stand von main bereitgestellt. Hostname,
Datenbankzugang und Verschlüsselungs-Secrets bleiben aus der bestehenden
Installation erhalten.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 1
fi

export VMID="$1"
export APP_REF="${2:-${APP_REF:-main}}"
export REUSE_EXISTING=1

exec "${SCRIPT_DIR}/proxmox-lxc.sh"
