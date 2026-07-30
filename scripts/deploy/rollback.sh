#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_ROOT="/opt/fahrgastrechte"
readonly CURRENT_LINK="${APP_ROOT}/current"
readonly ENV_FILE="/etc/fahrgastrechte/fahrgastrechte.env"
readonly RELEASES_DIR="${APP_ROOT}/releases"
readonly SERVICE_NAME="fahrgastrechte.service"

usage() {
  cat <<'USAGE'
Vorherige Fahrgastrechte-App-Release aktivieren.

  fahrgastrechte-rollback [RELEASE-VERZEICHNIS]

Ohne Argument wird die neueste andere Release gewählt. Datenbankmigrationen
werden nicht zurückgerollt; vor dem Wechsel wird automatisch ein Backup erzeugt.
USAGE
}

die() {
  printf '[fahrgastrechte-rollback] Fehler: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[fahrgastrechte-rollback] %s\n' "$*"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ $# -le 1 ]] || {
  usage >&2
  exit 1
}
[[ $EUID -eq 0 ]] || die "Der Rollback muss als root ausgeführt werden"
[[ -L "$CURRENT_LINK" ]] || die "Aktuelle Release-Verknüpfung fehlt"
[[ -f "$ENV_FILE" ]] || die "Runtime-Konfiguration fehlt: $ENV_FILE"
command -v fahrgastrechte-backup >/dev/null 2>&1 || die "fahrgastrechte-backup fehlt"

current_release="$(readlink --canonicalize "$CURRENT_LINK")"
requested_release="${1:-}"

if [[ -n "$requested_release" ]]; then
  [[ "$requested_release" =~ ^[A-Za-z0-9._-]+$ ]] || die "Ungültiger Release-Name"
  target_release="${RELEASES_DIR}/${requested_release}"
else
  target_release=""
  while IFS= read -r candidate; do
    if [[ "$candidate" != "$current_release" ]]; then
      target_release="$candidate"
      break
    fi
  done < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' |
    sort --numeric-sort --reverse | cut --delimiter=' ' --fields=2-)
fi

[[ -n "$target_release" && -d "$target_release" ]] || die "Keine frühere Release gefunden"
[[ -x "${target_release}/bin/fahrgastrechte" ]] || die "Ziel ist keine gültige Release"

log "Erzeuge Sicherheitsbackup"
fahrgastrechte-backup >/dev/null

restore_previous() {
  log "Rollback-Healthcheck fehlgeschlagen; aktiviere wieder die Ausgangs-Release"
  ln --symbolic --force --no-dereference "$current_release" "$CURRENT_LINK"
  systemctl restart "$SERVICE_NAME"
}

trap restore_previous ERR
ln --symbolic --force --no-dereference "$target_release" "$CURRENT_LINK"
systemctl restart "$SERVICE_NAME"

phx_host="$(sed -n 's/^PHX_HOST=//p' "$ENV_FILE" | tail -n 1)"
[[ "$phx_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
  die "PHX_HOST in der Runtime-Konfiguration ist ungültig"

for _attempt in {1..30}; do
  if curl --fail --silent --show-error \
    --header "Host: ${phx_host}" \
    --header 'X-Forwarded-Proto: https' \
    http://127.0.0.1:4000/readyz >/dev/null; then
    trap - ERR
    log "Release $(basename "$target_release") ist aktiv"
    exit 0
  fi
  sleep 2
done

false
