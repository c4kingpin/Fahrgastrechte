#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_NAME="fahrgastrechte"
readonly DATABASE_NAME="fahrgastrechte_prod"
readonly DEFAULT_AGE_IDENTITY="/etc/fahrgastrechte/backup.agekey"
readonly ENV_FILE="/etc/fahrgastrechte/fahrgastrechte.env"
readonly SERVICE_NAME="fahrgastrechte.service"

usage() {
  cat <<'USAGE'
Verschlüsseltes Fahrgastrechte-Backup wiederherstellen.

  fahrgastrechte-restore BACKUP.tar.gz.age --confirm [--skip-safety-backup]

Die Wiederherstellung ersetzt PostgreSQL, Dokumente, Runtime-Secrets und das
gesicherte Formulartemplate. Ohne --confirm werden keine Daten verändert.
USAGE
}

die() {
  printf '[fahrgastrechte-restore] Fehler: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[fahrgastrechte-restore] %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Benötigtes Kommando fehlt: $1"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ $EUID -eq 0 ]] || die "Der Restore muss als root ausgeführt werden"

backup_file="${1:-}"
confirm=0
skip_safety_backup=0

if [[ $# -gt 0 ]]; then
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
  --confirm) confirm=1 ;;
  --skip-safety-backup) skip_safety_backup=1 ;;
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

[[ -n "$backup_file" && -f "$backup_file" ]] || {
  usage >&2
  die "Backup-Datei fehlt"
}
[[ "$confirm" == "1" ]] || {
  usage >&2
  die "Explizite Bestätigung mit --confirm erforderlich"
}

for command_name in age pg_restore psql sha256sum systemctl tar; do
  require_command "$command_name"
done

identity_file="${BACKUP_AGE_IDENTITY_FILE:-$DEFAULT_AGE_IDENTITY}"
[[ -f "$identity_file" ]] || die "Age-Identität fehlt: $identity_file"

if [[ "$skip_safety_backup" == "0" ]]; then
  command -v fahrgastrechte-backup >/dev/null 2>&1 ||
    die "fahrgastrechte-backup fehlt; alternativ bewusst --skip-safety-backup verwenden"
  log "Erzeuge vor dem Restore ein Sicherheitsbackup"
  fahrgastrechte-backup >/dev/null
fi

umask 077
staging_dir="$(mktemp -d /var/tmp/fahrgastrechte-restore.XXXXXX)"
plain_archive="$(mktemp /var/tmp/fahrgastrechte-restore.XXXXXX.tar.gz)"
service_was_active=0

# shellcheck disable=SC2317
cleanup() {
  local status=$?

  rm -rf -- "$staging_dir"
  rm -f -- "$plain_archive"

  if [[ "$service_was_active" == "1" ]]; then
    systemctl start "$SERVICE_NAME" || true
  fi

  return "$status"
}

trap cleanup EXIT

log "Entschlüssele und prüfe das Backup"
age --decrypt --identity "$identity_file" --output "$plain_archive" "$backup_file"
tar --extract --gzip --file="$plain_archive" --directory="$staging_dir"

for required_file in database.dump documents.tar runtime.env MANIFEST.sha256; do
  [[ -f "${staging_dir}/${required_file}" ]] ||
    die "Backup ist unvollständig: $required_file"
done

(
  cd "$staging_dir"
  sha256sum --check --strict MANIFEST.sha256
)

database_password="$(sed -n 's/^DATABASE_PASSWORD=//p' "${staging_dir}/runtime.env" | tail -n 1)"
document_path="$(sed -n 's/^DOCUMENT_STORAGE_PATH=//p' "${staging_dir}/runtime.env" | tail -n 1)"
form_template_path="$(sed -n 's/^FORM_TEMPLATE_PATH=//p' "${staging_dir}/runtime.env" | tail -n 1)"
phx_host="$(sed -n 's/^PHX_HOST=//p' "${staging_dir}/runtime.env" | tail -n 1)"

[[ "$database_password" =~ ^[a-f0-9]{64}$ ]] ||
  die "Gesichertes Datenbankpasswort hat ein unerwartetes Format"
[[ "$document_path" == /var/lib/fahrgastrechte/* ]] ||
  die "Gesicherter Dokumentenpfad liegt außerhalb des App-Datenverzeichnisses"
[[ "$form_template_path" == /var/lib/fahrgastrechte/* ]] ||
  die "Gesicherter Formularpfad liegt außerhalb des App-Datenverzeichnisses"
[[ "$phx_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
  die "Gesicherter PHX_HOST ist ungültig"

if systemctl is-active --quiet "$SERVICE_NAME"; then
  service_was_active=1
  systemctl stop "$SERVICE_NAME"
fi

log "Stelle PostgreSQL wieder her"
runuser -u postgres -- pg_restore \
  --clean \
  --if-exists \
  --no-owner \
  --role="$APP_NAME" \
  --dbname="$DATABASE_NAME" \
  "${staging_dir}/database.dump"
runuser -u postgres -- psql \
  --set ON_ERROR_STOP=1 \
  --command "ALTER ROLE ${APP_NAME} WITH LOGIN PASSWORD '${database_password}'"

log "Stelle Dokumente und Runtime-Konfiguration wieder her"
install --directory --mode 0750 --owner "$APP_NAME" --group "$APP_NAME" "$document_path"
find "$document_path" -mindepth 1 -delete
tar --extract --file="${staging_dir}/documents.tar" --directory="$document_path" --no-same-owner
chown --recursive "$APP_NAME:$APP_NAME" "$document_path"
chmod 0750 "$document_path"

install --mode 0640 --owner root --group "$APP_NAME" "${staging_dir}/runtime.env" "$ENV_FILE"

if [[ -f "${staging_dir}/form-template.pdf" ]]; then
  install --mode 0640 --owner root --group "$APP_NAME" \
    "${staging_dir}/form-template.pdf" "$form_template_path"
fi

systemctl start "$SERVICE_NAME"

for _attempt in {1..30}; do
  if curl --fail --silent --show-error \
    --header "Host: ${phx_host}" \
    --header 'X-Forwarded-Proto: https' \
    http://127.0.0.1:4000/readyz >/dev/null; then
    service_was_active=0
    log "Restore abgeschlossen und Readiness bestätigt"
    exit 0
  fi
  sleep 2
done

die "Restore wurde eingespielt, aber die Anwendung ist nicht bereit"
