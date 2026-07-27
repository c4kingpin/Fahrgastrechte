#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly REPOSITORY_ROOT

# Kompatibler Einstieg für bestehende Automatisierung aus einem Checkout.
exec "${REPOSITORY_ROOT}/install/fahrgastrechte-install.sh" "$@"
