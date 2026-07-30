#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Externe HTTPS- und LiveView-WebSocket-Strecke prüfen.

  scripts/deploy/smoke-test.sh https://fahrgastrechte.example.org

Das Ziel muss eine HTTPS-Adresse ohne Pfad sein. Der WebSocket-Test erwartet
einen erfolgreichen HTTP-101-Upgrade über den Reverse-Proxy.
USAGE
}

die() {
  printf '[fahrgastrechte-smoke] Fehler: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[fahrgastrechte-smoke] %s\n' "$*"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

for command_name in curl grep openssl sed; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "Benötigtes Kommando fehlt: $command_name"
done

[[ $# -eq 1 ]] || {
  usage >&2
  exit 1
}

base_url="${1%/}"
[[ "$base_url" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
  die "Ziel muss eine HTTPS-Adresse ohne Port oder Pfad sein"

for path in /healthz /readyz /; do
  log "Prüfe ${base_url}${path}"
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --max-time 15 \
    --output /dev/null \
    "${base_url}${path}"
done

headers_file="$(mktemp /tmp/fahrgastrechte-websocket.XXXXXX)"
trap 'rm -f "$headers_file"' EXIT
websocket_key="$(openssl rand -base64 16)"

log "Prüfe LiveView-WebSocket-Upgrade"
curl \
  --silent \
  --show-error \
  --http1.1 \
  --max-time 3 \
  --dump-header "$headers_file" \
  --output /dev/null \
  --header 'Connection: Upgrade' \
  --header 'Upgrade: websocket' \
  --header "Origin: ${base_url}" \
  --header "Sec-WebSocket-Key: ${websocket_key}" \
  --header 'Sec-WebSocket-Version: 13' \
  "${base_url}/live/websocket?vsn=2.0.0" || true

if ! grep --quiet --extended-regexp '^HTTP/[0-9.]+ 101([[:space:]]|$)' "$headers_file"; then
  sed -n '1,20p' "$headers_file" >&2
  die "LiveView-WebSocket wurde nicht auf HTTP 101 hochgestuft"
fi

log "HTTPS, Readiness und WebSocket funktionieren"
