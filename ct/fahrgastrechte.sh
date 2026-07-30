#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_INSTALLER_BASE_URL="https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte"

INSTALLER_BASE_URL="${INSTALLER_BASE_URL:-$DEFAULT_INSTALLER_BASE_URL}"
INSTALLER_REF="${INSTALLER_REF:-main}"
TEMPORARY_INSTALLER=""

die() {
  printf "[fahrgastrechte-bootstrap] Fehler: %s\n" "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMPORARY_INSTALLER" ]]; then
    rm -f "$TEMPORARY_INSTALLER"
  fi
}

trap cleanup EXIT

[[ "$INSTALLER_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:+-]*$ ]] ||
  die "INSTALLER_REF enthält ungültige Zeichen"
[[ "$INSTALLER_BASE_URL" =~ ^https://[A-Za-z0-9._:/@+-]+$ ]] ||
  die "INSTALLER_BASE_URL muss eine HTTPS-Adresse sein"

if [[ -n "${INSTALL_SCRIPT_PATH:-}" ]]; then
  [[ -f "$INSTALL_SCRIPT_PATH" ]] ||
    die "Lokales Installationsscript fehlt: $INSTALL_SCRIPT_PATH"
  exec /usr/bin/bash "$INSTALL_SCRIPT_PATH" "$@"
fi

command -v curl >/dev/null 2>&1 ||
  die "Benötigtes Kommando fehlt: curl"

printf "%s\n" \
  "Hinweis: ct/fahrgastrechte.sh erstellt keinen Container mehr." \
  "Der Installer wird direkt im bestehenden LXC ausgeführt."

TEMPORARY_INSTALLER="$(mktemp /tmp/fahrgastrechte-install.XXXXXX)"
curl --fail --location --silent --show-error \
  "${INSTALLER_BASE_URL}/${INSTALLER_REF}/install/fahrgastrechte-install.sh" \
  --output "$TEMPORARY_INSTALLER"
bash -n "$TEMPORARY_INSTALLER"
/usr/bin/bash "$TEMPORARY_INSTALLER" "$@"
