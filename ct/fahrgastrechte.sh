#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP="Fahrgastrechte"
readonly DEFAULT_APP_REPOSITORY="https://github.com/c4kingpin/Fahrgastrechte.git"
readonly DEFAULT_INSTALLER_BASE_URL="https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte"

APP_REF="${APP_REF:-main}"
APP_REPOSITORY="${APP_REPOSITORY:-$DEFAULT_APP_REPOSITORY}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-4}"
CT_HOSTNAME="${CT_HOSTNAME:-fahrgastrechte}"
DISK_GB="${DISK_GB:-16}"
INSTALLER_BASE_URL="${INSTALLER_BASE_URL:-$DEFAULT_INSTALLER_BASE_URL}"
INSTALLER_REF="${INSTALLER_REF:-main}"
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

MODE="menu"
DRY_RUN=0
TEMP_DIR=""

readonly BOLD="\033[1m"
readonly BLUE="\033[36m"
readonly GREEN="\033[32m"
readonly RED="\033[31m"
readonly YELLOW="\033[33m"
readonly RESET="\033[0m"

usage() {
  cat <<'USAGE'
Fahrgastrechte als Proxmox-LXC installieren (Community-Scripts-Stil).

Direkt auf einem Proxmox-VE-Host als root:

  bash -c "$(curl -fsSL https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte/main/ct/fahrgastrechte.sh)"

Optionen:
  --defaults    Ohne Rückfragen mit den Standardwerten installieren
  --advanced    Erweiterte Konfiguration interaktiv abfragen
  --reuse       Vorhandenen Container aus einer Teilinstallation weiterverwenden
  --dry-run     Konfiguration anzeigen, aber nichts verändern
  -h, --help    Hilfe anzeigen

Alle Werte können auch per Umgebungsvariable gesetzt werden:
  VMID, CT_HOSTNAME, PHX_HOST, APP_REPOSITORY, APP_REF, INSTALLER_REF,
  REUSE_EXISTING,
  TEMPLATE, TEMPLATE_STORAGE, ROOTFS_STORAGE, BRIDGE, IP_CONFIG,
  CORES, MEMORY_MB, SWAP_MB, DISK_GB und ONBOOT.

Beispiele:
  PHX_HOST=rechte.example.org bash -c "$(curl -fsSL URL)"
  VMID=240 PHX_HOST=rechte.example.org bash -c "$(curl -fsSL URL)" -- --defaults
USAGE
}

header_info() {
  clear 2>/dev/null || true
  printf "\n%b%s%b\n" "$BOLD$BLUE" "  Fahrgastrechte LXC" "$RESET"
  printf "%b%s%b\n\n" "$BLUE" "  Proxmox Community-Scripts-artige Installation" "$RESET"
}

msg_info() {
  printf "%b[INFO]%b %s\n" "$BLUE" "$RESET" "$*"
}

msg_ok() {
  printf "%b[OK]%b   %s\n" "$GREEN" "$RESET" "$*"
}

msg_warn() {
  printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$*"
}

die() {
  printf "%b[FEHLER]%b %s\n" "$RED" "$RESET" "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -f "${TEMP_DIR}/fahrgastrechte-install.sh"
    rmdir "$TEMP_DIR" 2>/dev/null || true
  fi
}

trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Benötigtes Kommando fehlt: $1"
}

prompt() {
  local label="$1"
  local current="$2"
  local answer

  read -r -p "${label} [${current}]: " answer
  printf '%s\n' "${answer:-$current}"
}

validate_integer() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+$ ]] || die "${name} muss eine nichtnegative Ganzzahl sein"
}

validate_settings() {
  local setting

  for setting in CORES MEMORY_MB SWAP_MB DISK_GB ONBOOT; do
    validate_integer "$setting" "${!setting}"
  done

  [[ "$REUSE_EXISTING" =~ ^[01]$ ]] ||
    die "REUSE_EXISTING muss 0 oder 1 sein"

  [[ -z "$VMID" || "$VMID" =~ ^[1-9][0-9]{2,8}$ ]] ||
    die "VMID muss eine gültige numerische Container-ID sein"
  [[ "$CT_HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
    die "CT_HOSTNAME enthält ungültige Zeichen"
  [[ "$PHX_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
    die "PHX_HOST enthält ungültige Zeichen"
  [[ "$APP_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:+-]*$ ]] ||
    die "APP_REF enthält ungültige Zeichen"
  [[ "$INSTALLER_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:+-]*$ ]] ||
    die "INSTALLER_REF enthält ungültige Zeichen"
  [[ "$APP_REPOSITORY" =~ ^[A-Za-z0-9._:/@+-]+$ ]] ||
    die "APP_REPOSITORY enthält ungültige Zeichen"
  [[ "$INSTALLER_BASE_URL" =~ ^https://[A-Za-z0-9._:/@+-]+$ ]] ||
    die "INSTALLER_BASE_URL muss eine HTTPS-Adresse sein"
}

select_mode() {
  local answer

  if [[ "$MODE" != "menu" ]]; then
    return
  fi

  if [[ ! -t 0 ]]; then
    MODE="defaults"
    msg_warn "Kein interaktives Terminal erkannt; Standardwerte werden verwendet."
    return
  fi

  printf "  1) Standardinstallation\n"
  printf "  2) Erweiterte Einstellungen\n"
  printf "  q) Abbrechen\n\n"
  read -r -p "Auswahl [1]: " answer

  case "${answer:-1}" in
  1) MODE="defaults" ;;
  2) MODE="advanced" ;;
  q | Q) exit 0 ;;
  *) die "Ungültige Auswahl: $answer" ;;
  esac
}

advanced_settings() {
  if [[ "$MODE" != "advanced" ]]; then
    return 0
  fi

  VMID="$(prompt "Container-ID (leer = nächste freie ID)" "$VMID")"
  CT_HOSTNAME="$(prompt "Container-Hostname" "$CT_HOSTNAME")"
  PHX_HOST="$(prompt "Öffentlicher Phoenix-Hostname" "$PHX_HOST")"
  APP_REF="$(prompt "Zu installierender Git-Ref" "$APP_REF")"
  TEMPLATE_STORAGE="$(prompt "Template-Storage" "$TEMPLATE_STORAGE")"
  ROOTFS_STORAGE="$(prompt "RootFS-Storage" "$ROOTFS_STORAGE")"
  BRIDGE="$(prompt "Netzwerk-Bridge" "$BRIDGE")"
  IP_CONFIG="$(prompt "IP-Konfiguration für pct (z. B. ip=dhcp)" "$IP_CONFIG")"
  CORES="$(prompt "vCPU" "$CORES")"
  MEMORY_MB="$(prompt "RAM in MiB" "$MEMORY_MB")"
  SWAP_MB="$(prompt "Swap in MiB" "$SWAP_MB")"
  DISK_GB="$(prompt "Root-Disk in GiB" "$DISK_GB")"
}

print_summary() {
  printf "\n%bKonfiguration%b\n" "$BOLD" "$RESET"
  printf "  VMID:             %s\n" "${VMID:-automatisch}"
  printf "  Aktion:           %s\n" "$([[ "$REUSE_EXISTING" == "1" ]] && printf 'Teilinstallation fortsetzen' || printf 'Container neu erstellen')"
  printf "  Hostname:         %s\n" "$CT_HOSTNAME"
  printf "  Phoenix-Host:     %s\n" "$PHX_HOST"
  printf "  App-Ref:          %s\n" "$APP_REF"
  printf "  Debian-Template:  %s\n" "${TEMPLATE:-automatisch (13, Fallback 12)}"
  printf "  Storage:          %s (Template), %s (RootFS)\n" "$TEMPLATE_STORAGE" "$ROOTFS_STORAGE"
  printf "  Netzwerk:         %s / %s\n" "$BRIDGE" "$IP_CONFIG"
  printf "  Ressourcen:       %s vCPU, %s MiB RAM, %s MiB Swap, %s GiB Disk\n\n" "$CORES" "$MEMORY_MB" "$SWAP_MB" "$DISK_GB"
}

confirm_install() {
  local answer

  if [[ "$MODE" != "advanced" || ! -t 0 ]]; then
    return
  fi

  read -r -p "Container jetzt erstellen? [J/n]: " answer
  case "${answer:-j}" in
  j | J | y | Y) ;;
  *) die "Installation abgebrochen" ;;
  esac
}

select_template() {
  local candidate

  if [[ -n "$TEMPLATE" ]]; then
    printf '%s\n' "$TEMPLATE"
    return
  fi

  candidate="$(
    pveam available --section system |
      awk '$2 ~ /^debian-13-standard_.*_(amd64|arm64)\.tar\.(zst|gz)$/ {print $2; exit}'
  )"

  if [[ -z "$candidate" ]]; then
    candidate="$(
      pveam available --section system |
        awk '$2 ~ /^debian-12-standard_.*_(amd64|arm64)\.tar\.(zst|gz)$/ {print $2; exit}'
    )"
  fi

  [[ -n "$candidate" ]] ||
    die "Kein Debian-12/13-Standardtemplate in 'pveam available' gefunden"
  printf '%s\n' "$candidate"
}

ensure_template() {
  local template_name="$1"
  local volume="${TEMPLATE_STORAGE}:vztmpl/${template_name}"

  if pveam list "$TEMPLATE_STORAGE" |
    awk -v volume="$volume" '$1 == volume {found=1} END {exit !found}'; then
    msg_ok "Verwende vorhandenes Template ${volume}"
  else
    msg_info "Lade Template ${template_name}"
    pveam download "$TEMPLATE_STORAGE" "$template_name"
  fi
}

wait_for_network() {
  local attempt

  for ((attempt = 1; attempt <= 30; attempt++)); do
    if pct exec "$VMID" -- getent hosts github.com >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done

  die "Container ${VMID} hat nach 60 Sekunden keine funktionierende Namensauflösung"
}

obtain_install_script() {
  local destination="$1"
  local url="${INSTALLER_BASE_URL}/${INSTALLER_REF}/install/fahrgastrechte-install.sh"

  if [[ -n "${INSTALL_SCRIPT_PATH:-}" ]]; then
    [[ -f "$INSTALL_SCRIPT_PATH" ]] ||
      die "Lokales Container-Installationsscript fehlt: $INSTALL_SCRIPT_PATH"
    cp "$INSTALL_SCRIPT_PATH" "$destination"
  else
    msg_info "Lade Container-Installationsscript von GitHub"
    curl --fail --location --silent --show-error "$url" --output "$destination"
  fi

  bash -n "$destination"
}

run_install() {
  local installer_path="$1"

  pct push "$VMID" "$installer_path" /root/fahrgastrechte-install.sh --group 0 --perms 0700 --user 0
  pct exec "$VMID" -- env "APP_REF=${APP_REF}" "APP_REPOSITORY=${APP_REPOSITORY}" "INSTALLER_BASE_URL=${INSTALLER_BASE_URL}" "INSTALLER_REF=${INSTALLER_REF}" "PHX_HOST=${PHX_HOST}" /usr/bin/bash /root/fahrgastrechte-install.sh
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --defaults) MODE="defaults" ;;
  --advanced) MODE="advanced" ;;
  --reuse) REUSE_EXISTING=1 ;;
  --dry-run) DRY_RUN=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    die "Unbekannte Option: $1"
    ;;
  esac
  shift
done

header_info
select_mode
advanced_settings
validate_settings
print_summary

if [[ "$DRY_RUN" == "1" ]]; then
  msg_ok "Dry-Run abgeschlossen; es wurden keine Änderungen vorgenommen."
  exit 0
fi

[[ $EUID -eq 0 ]] || die "Das Script muss als root auf dem Proxmox-Knoten laufen"
for command_name in awk curl getent pct pveam pvesh; do
  require_command "$command_name"
done
confirm_install

if [[ "$REUSE_EXISTING" == "1" && -z "$VMID" ]]; then
  die "Für --reuse muss VMID explizit gesetzt werden"
fi

if [[ -z "$VMID" ]]; then
  VMID="$(pvesh get /cluster/nextid)"
fi
validate_integer VMID "$VMID"

if pct config "$VMID" >/dev/null 2>&1; then
  [[ "$REUSE_EXISTING" == "1" ]] ||
    die "Container ${VMID} existiert bereits. Teilinstallation mit VMID=${VMID} und --reuse fortsetzen; reguläre Updates erfolgen im Container mit 'update'."
  msg_info "Setze die Installation im vorhandenen Container ${VMID} fort"
else
  [[ "$REUSE_EXISTING" == "0" ]] ||
    die "Container ${VMID} existiert nicht und kann nicht fortgesetzt werden"

  msg_info "Aktualisiere den Proxmox-Template-Katalog"
  pveam update
  selected_template="$(select_template)"
  ensure_template "$selected_template"

  msg_info "Erstelle unprivilegierten Container ${VMID}"
  pct create "$VMID" "${TEMPLATE_STORAGE}:vztmpl/${selected_template}" --cores "$CORES" --features nesting=1 --hostname "$CT_HOSTNAME" --memory "$MEMORY_MB" --net0 "name=eth0,bridge=${BRIDGE},${IP_CONFIG},firewall=1,type=veth" --onboot "$ONBOOT" --ostype debian --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" --swap "$SWAP_MB" --unprivileged 1
fi

if [[ "$(pct status "$VMID")" != "status: running" ]]; then
  msg_info "Starte Container ${VMID}"
  pct start "$VMID"
fi
msg_info "Warte auf das Netzwerk im Container"
wait_for_network

TEMP_DIR="$(mktemp -d /tmp/fahrgastrechte-lxc.XXXXXX)"
installer_path="${TEMP_DIR}/fahrgastrechte-install.sh"
obtain_install_script "$installer_path"

msg_info "Installiere ${APP} im Container"
run_install "$installer_path"

container_ip="$(pct exec "$VMID" -- hostname -I | awk '{print $1}')"
msg_ok "Fahrgastrechte wurde erfolgreich installiert."
printf "\n  Container:  %s\n" "$VMID"
printf "  IP-Adresse: %s\n" "${container_ip:-unbekannt}"
printf "  App:        http://%s:4000\n" "${container_ip:-CONTAINER-IP}"
printf "  Hostname:   %s\n\n" "$PHX_HOST"
printf "Für Updates im Container:  pct enter %s  →  update [GIT-REF]\n" "$VMID"
printf "Für TLS: Reverse-Proxy von https://%s auf http://%s:4000 konfigurieren.\n" "$PHX_HOST" "${container_ip:-CONTAINER-IP}"
