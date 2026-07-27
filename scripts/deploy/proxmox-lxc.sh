#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PROVISION_SCRIPT="${SCRIPT_DIR}/provision-lxc.sh"

APP_REPOSITORY="${APP_REPOSITORY:-https://github.com/c4kingpin/Fahrgastrechte.git}"
APP_REF="${APP_REF:-main}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-4}"
CT_HOSTNAME="${CT_HOSTNAME:-fahrgastrechte}"
DISK_GB="${DISK_GB:-16}"
IP_CONFIG="${IP_CONFIG:-ip=dhcp}"
MEMORY_MB="${MEMORY_MB:-4096}"
ONBOOT="${ONBOOT:-1}"
PHX_HOST="${PHX_HOST:-fahrgastrechte.local}"
REUSE_EXISTING="${REUSE_EXISTING:-0}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"
SWAP_MB="${SWAP_MB:-1024}"
TEMPLATE="${TEMPLATE:-}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
VMID="${VMID:-}"

usage() {
  cat <<'USAGE'
Fahrgastrechte in einem Proxmox-LXC bereitstellen.

Das Script wird als root auf einem Proxmox-VE-Knoten ausgeführt:

  PHX_HOST=fahrgastrechte.example.org \
    scripts/deploy/proxmox-lxc.sh

Konfiguration über Umgebungsvariablen:

  VMID                Container-ID; Standard: nächste freie Cluster-ID
  CT_HOSTNAME         LXC-Hostname                 (fahrgastrechte)
  PHX_HOST            Externer Phoenix-Hostname   (fahrgastrechte.local)
  APP_REPOSITORY      Git-Repository der App
  APP_REF             Git-Branch, -Tag oder Ref    (main)
  TEMPLATE            Explizites Debian-Template; sonst automatische Auswahl
  TEMPLATE_STORAGE    Storage für Templates        (local)
  ROOTFS_STORAGE      Storage für das Root-Dateisystem (local-lvm)
  BRIDGE              Proxmox-Netzwerk-Bridge      (vmbr0)
  IP_CONFIG           pct-Netzwerkkonfiguration    (ip=dhcp)
  CORES               vCPU-Anzahl                  (4)
  MEMORY_MB           Arbeitsspeicher in MiB       (4096)
  SWAP_MB             Swap in MiB                  (1024)
  DISK_GB             Root-Disk in GiB             (16)
  ONBOOT              Beim Hoststart starten       (1)
  REUSE_EXISTING      Bestehenden VMID aktualisieren (0)

Beispiele:

  VMID=240 PHX_HOST=rechte.example.org \
    scripts/deploy/proxmox-lxc.sh

  VMID=240 REUSE_EXISTING=1 APP_REF=v0.2.0 \
    PHX_HOST=rechte.example.org scripts/deploy/proxmox-lxc.sh
USAGE
}

log() {
  printf '[proxmox-lxc] %s\n' "$*"
}

die() {
  printf '[proxmox-lxc] Fehler: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Benötigtes Kommando fehlt: $1"
}

validate_integer() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+$ ]] || die "${name} muss eine nichtnegative Ganzzahl sein"
}

container_exists() {
  pct config "$VMID" >/dev/null 2>&1
}

select_template() {
  local candidate

  if [[ -n "$TEMPLATE" ]]; then
    printf '%s\n' "$TEMPLATE"
    return
  fi

  candidate="$(
    pveam available --section system |
      awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.(zst|gz)$/ {print $2; exit}'
  )"

  if [[ -z "$candidate" ]]; then
    candidate="$(
      pveam available --section system |
        awk '$2 ~ /^debian-12-standard_.*_amd64\.tar\.(zst|gz)$/ {print $2; exit}'
    )"
  fi

  [[ -n "$candidate" ]] ||
    die "Kein Debian-12/13-Template für amd64 in 'pveam available' gefunden"

  printf '%s\n' "$candidate"
}

ensure_template() {
  local template_name="$1"
  local volume="${TEMPLATE_STORAGE}:vztmpl/${template_name}"

  if pveam list "$TEMPLATE_STORAGE" | awk -v volume="$volume" '$1 == volume {found=1} END {exit !found}'; then
    log "Verwende vorhandenes Template ${volume}"
  else
    log "Lade Template ${template_name} nach ${TEMPLATE_STORAGE}"
    pveam download "$TEMPLATE_STORAGE" "$template_name"
  fi
}

wait_for_network() {
  local _attempt

  for _attempt in {1..30}; do
    if pct exec "$VMID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
      return
    fi

    sleep 2
  done

  die "Container ${VMID} hat nach 60 Sekunden noch keine funktionierende Namensauflösung"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

[[ $# -eq 0 ]] || die "Unbekannte Argumente. Mit --help wird die Hilfe angezeigt."
[[ $EUID -eq 0 ]] || die "Das Script muss als root auf dem Proxmox-Knoten laufen"
[[ -x "$PROVISION_SCRIPT" ]] || die "Provisionierungsscript fehlt oder ist nicht ausführbar: ${PROVISION_SCRIPT}"
[[ "$PHX_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "PHX_HOST enthält ungültige Zeichen"

for command_name in awk getent pct pveam pvesh; do
  require_command "$command_name"
done

for integer_setting in CORES MEMORY_MB SWAP_MB DISK_GB ONBOOT REUSE_EXISTING; do
  validate_integer "$integer_setting" "${!integer_setting}"
done

if [[ -z "$VMID" ]]; then
  VMID="$(pvesh get /cluster/nextid)"
fi

validate_integer VMID "$VMID"

if container_exists; then
  [[ "$REUSE_EXISTING" == "1" ]] ||
    die "Container ${VMID} existiert bereits. Für ein bewusstes Update REUSE_EXISTING=1 setzen."
  log "Aktualisiere bestehenden Container ${VMID}"
else
  log "Aktualisiere Proxmox-Template-Katalog"
  pveam update
  selected_template="$(select_template)"
  ensure_template "$selected_template"

  log "Erstelle unprivilegierten Container ${VMID}"
  pct create "$VMID" "${TEMPLATE_STORAGE}:vztmpl/${selected_template}" \
    --arch amd64 \
    --cores "$CORES" \
    --hostname "$CT_HOSTNAME" \
    --memory "$MEMORY_MB" \
    --net0 "name=eth0,bridge=${BRIDGE},${IP_CONFIG},firewall=1,type=veth" \
    --onboot "$ONBOOT" \
    --ostype debian \
    --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
    --swap "$SWAP_MB" \
    --unprivileged 1
fi

if [[ "$(pct status "$VMID")" != "status: running" ]]; then
  log "Starte Container ${VMID}"
  pct start "$VMID"
fi

log "Warte auf Netzwerk im Container"
wait_for_network

log "Übertrage Provisionierungsscript"
pct push "$VMID" "$PROVISION_SCRIPT" /root/provision-fahrgastrechte \
  --group 0 \
  --mode 0700 \
  --user 0

log "Installiere und starte Fahrgastrechte"
pct exec "$VMID" -- env \
  "APP_REF=${APP_REF}" \
  "APP_REPOSITORY=${APP_REPOSITORY}" \
  "PHX_HOST=${PHX_HOST}" \
  /usr/bin/bash /root/provision-fahrgastrechte

container_ip="$(
  pct exec "$VMID" -- hostname -I |
    awk '{print $1}'
)"

log "Bereitstellung abgeschlossen"
printf 'Container: %s\n' "$VMID"
printf 'IP-Adresse: %s\n' "${container_ip:-unbekannt}"
printf 'App-Port: 4000/tcp\n'
printf 'Externer Hostname: %s\n' "$PHX_HOST"
printf '\nEin TLS-Reverse-Proxy muss %s an %s:4000 weiterleiten.\n' \
  "$PHX_HOST" "${container_ip:-CONTAINER-IP}"
