#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly REPOSITORY_ROOT

# Historischer, kompatibler Einstieg für einen lokalen Checkout. Der Installer
# läuft im bereits vorhandenen LXC und greift nicht auf den Proxmox-Host zu.
export INSTALL_SCRIPT_PATH="${REPOSITORY_ROOT}/install/fahrgastrechte-install.sh"
exec "${REPOSITORY_ROOT}/ct/fahrgastrechte.sh" "$@"
