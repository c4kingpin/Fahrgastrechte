#!/usr/bin/env bash
set -Eeuo pipefail

readonly DATABASE_NAME="fahrgastrechte_prod"
readonly DEFAULT_BACKUP_PATH="/var/backups/fahrgastrechte"
readonly ENV_FILE="/etc/fahrgastrechte/fahrgastrechte.env"
readonly SERVICE_NAME="fahrgastrechte.service"

log() {
  printf '[fahrgastrechte-backup] %s\n' "$*"
}

die() {
  printf '[fahrgastrechte-backup] Fehler: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Benötigtes Kommando fehlt: $1"
}

environment_value() {
  local key="$1"

  sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
}

[[ $EUID -eq 0 ]] || die "Das Backup muss als root ausgeführt werden"
[[ -f "$ENV_FILE" ]] || die "Runtime-Konfiguration fehlt: $ENV_FILE"

for command_name in age pg_dump sha256sum systemctl tar; do
  require_command "$command_name"
done

document_path="$(environment_value DOCUMENT_STORAGE_PATH)"
backup_path="$(environment_value BACKUP_PATH)"
backup_recipient="$(environment_value BACKUP_AGE_RECIPIENT)"
retention_days="$(environment_value BACKUP_RETENTION_DAYS)"
form_template_path="$(environment_value FORM_TEMPLATE_PATH)"

backup_path="${backup_path:-$DEFAULT_BACKUP_PATH}"
retention_days="${retention_days:-30}"

[[ "$document_path" == /* && "$document_path" != "/" ]] ||
  die "DOCUMENT_STORAGE_PATH muss ein sicherer absoluter Pfad sein"
[[ "$backup_path" == /* && "$backup_path" != "/" ]] ||
  die "BACKUP_PATH muss ein sicherer absoluter Pfad sein"
[[ -n "$backup_recipient" ]] || die "BACKUP_AGE_RECIPIENT fehlt"
[[ "$retention_days" =~ ^[1-9][0-9]*$ ]] ||
  die "BACKUP_RETENTION_DAYS muss eine positive Ganzzahl sein"
[[ -d "$document_path" ]] || die "Dokumentenspeicher fehlt: $document_path"

umask 077
install --directory --mode 0700 --owner root --group root "$backup_path"
staging_dir="$(mktemp -d /var/tmp/fahrgastrechte-backup.XXXXXX)"
plain_archive="$(mktemp /var/tmp/fahrgastrechte-backup.XXXXXX.tar.gz)"
temporary_backup="$(mktemp "${backup_path}/.fahrgastrechte.XXXXXX.age")"
service_was_active=0

cleanup() {
  local status=$?

  rm -rf -- "$staging_dir"
  rm -f -- "$plain_archive" "$temporary_backup"

  if [[ "$service_was_active" == "1" ]]; then
    if ! systemctl start "$SERVICE_NAME"; then
      status=1
    fi
  fi

  return "$status"
}

trap cleanup EXIT

if systemctl is-active --quiet "$SERVICE_NAME"; then
  service_was_active=1
  log "Stoppe die Anwendung für einen konsistenten Datenstand"
  systemctl stop "$SERVICE_NAME"
fi

log "Sichere PostgreSQL"
runuser -u postgres -- pg_dump \
  --format=custom \
  --no-owner \
  "$DATABASE_NAME" >"${staging_dir}/database.dump"

log "Sichere Dokumente und Runtime-Secrets"
tar --create --file="${staging_dir}/documents.tar" --directory="$document_path" .
install --mode 0600 "$ENV_FILE" "${staging_dir}/runtime.env"

if [[ -n "$form_template_path" && -f "$form_template_path" ]]; then
  install --mode 0600 "$form_template_path" "${staging_dir}/form-template.pdf"
fi

(
  cd "$staging_dir"
  sha256sum database.dump documents.tar runtime.env >MANIFEST.sha256
  if [[ -f form-template.pdf ]]; then
    sha256sum form-template.pdf >>MANIFEST.sha256
  fi
)

tar --create --gzip --file="$plain_archive" --directory="$staging_dir" .

timestamp="$(date --utc +%Y%m%dT%H%M%SZ)"
final_backup="${backup_path}/fahrgastrechte-${timestamp}.tar.gz.age"

log "Verschlüssele das Backup"
age --encrypt --recipient "$backup_recipient" --output "$temporary_backup" "$plain_archive"
chmod 0600 "$temporary_backup"
mv --no-clobber "$temporary_backup" "$final_backup"

find "$backup_path" \
  -maxdepth 1 \
  -type f \
  -name 'fahrgastrechte-*.tar.gz.age' \
  -mtime "+${retention_days}" \
  -delete

log "Backup erfolgreich: $final_backup"
printf '%s\n' "$final_backup"
