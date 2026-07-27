#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_NAME="fahrgastrechte"
readonly APP_ROOT="/opt/fahrgastrechte"
readonly DEFAULT_APP_REPOSITORY="https://github.com/c4kingpin/Fahrgastrechte.git"
readonly DEFAULT_INSTALLER_BASE_URL="https://raw.githubusercontent.com/c4kingpin/Fahrgastrechte"
readonly DEPLOYMENT_FILE="/etc/fahrgastrechte/deployment.env"
readonly ENV_FILE="/etc/fahrgastrechte/fahrgastrechte.env"
readonly SERVICE_FILE="/etc/systemd/system/fahrgastrechte.service"
readonly SOURCE_DIR="${APP_ROOT}/source"
readonly UPDATE_COMMAND="/usr/local/bin/fahrgastrechte-update"

APP_REF="${APP_REF:-main}"
APP_REPOSITORY="${APP_REPOSITORY:-}"
INSTALLER_BASE_URL="${INSTALLER_BASE_URL:-$DEFAULT_INSTALLER_BASE_URL}"
INSTALLER_REF="${INSTALLER_REF:-main}"
PHX_HOST="${PHX_HOST:-}"

log() {
  printf '[fahrgastrechte-install] %s\n' "$*"
}

die() {
  printf '[fahrgastrechte-install] Fehler: %s\n' "$*" >&2
  exit 1
}

existing_value() {
  local file="$1"
  local key="$2"

  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

wait_for_http() {
  local attempt

  for ((attempt = 1; attempt <= 30; attempt++)); do
    if curl --fail --silent --show-error --header 'Host: localhost' http://127.0.0.1:4000/ >/dev/null; then
      return
    fi
    sleep 2
  done

  journalctl --unit fahrgastrechte --no-pager --lines 80 >&2 || true
  return 1
}

write_runtime_environment() {
  local database_password="$1"
  local secret_key_base="$2"
  local field_encryption_key="$3"
  local temporary_env

  umask 027
  temporary_env="$(mktemp "/etc/${APP_NAME}/fahrgastrechte.env.XXXXXX")"
  trap 'rm -f "$temporary_env"' RETURN

  cat >"$temporary_env" <<EOF
DATABASE_PASSWORD=${database_password}
DATABASE_URL=ecto://${APP_NAME}:${database_password}@127.0.0.1/${APP_NAME}_prod
FIELD_ENCRYPTION_KEY=${field_encryption_key}
FIELD_ENCRYPTION_KEY_VERSION=1
LANG=C.UTF-8
PHX_HOST=${PHX_HOST}
PHX_SERVER=true
POOL_SIZE=10
PORT=4000
SECRET_KEY_BASE=${secret_key_base}
EOF

  chown root:"$APP_NAME" "$temporary_env"
  chmod 0640 "$temporary_env"
  mv --force "$temporary_env" "$ENV_FILE"
  trap - RETURN
}

write_deployment_environment() {
  local temporary_deployment

  temporary_deployment="$(mktemp "/etc/${APP_NAME}/deployment.env.XXXXXX")"
  trap 'rm -f "$temporary_deployment"' RETURN

  cat >"$temporary_deployment" <<EOF
APP_REPOSITORY=${APP_REPOSITORY}
INSTALLER_BASE_URL=${INSTALLER_BASE_URL}
INSTALLER_REF=${INSTALLER_REF}
EOF

  chown root:root "$temporary_deployment"
  chmod 0600 "$temporary_deployment"
  mv --force "$temporary_deployment" "$DEPLOYMENT_FILE"
  trap - RETURN
}

write_update_command() {
  cat >"$UPDATE_COMMAND" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_REPOSITORY="${APP_REPOSITORY}"
readonly INSTALLER_BASE_URL="${INSTALLER_BASE_URL}"
readonly INSTALLER_REF="${INSTALLER_REF}"

desired_ref="\${1:-main}"
[[ "\$desired_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:+-]*\$ ]] || {
  printf 'Ungültiger Git-Ref: %s\\n' "\$desired_ref" >&2
  exit 1
}

temporary_installer="\$(mktemp /tmp/fahrgastrechte-update.XXXXXX)"
trap 'rm -f "\$temporary_installer"' EXIT
curl --fail --location --silent --show-error \
  "\${INSTALLER_BASE_URL}/\${INSTALLER_REF}/install/fahrgastrechte-install.sh" \
  --output "\$temporary_installer"
bash -n "\$temporary_installer"
env APP_REF="\$desired_ref" \
  APP_REPOSITORY="\$APP_REPOSITORY" \
  INSTALLER_BASE_URL="\$INSTALLER_BASE_URL" \
  INSTALLER_REF="\$INSTALLER_REF" \
  /usr/bin/bash "\$temporary_installer"
EOF

  chmod 0755 "$UPDATE_COMMAND"
  ln --symbolic --force --no-dereference "$UPDATE_COMMAND" /usr/local/bin/update
}

write_systemd_service() {
  cat >"$SERVICE_FILE" <<'UNIT'
[Unit]
Description=Fahrgastrechte Phoenix application
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=fahrgastrechte
Group=fahrgastrechte
EnvironmentFile=/etc/fahrgastrechte/fahrgastrechte.env
Environment=HOME=/var/lib/fahrgastrechte
Environment=ERL_CRASH_DUMP=/var/lib/fahrgastrechte/erl_crash.dump
WorkingDirectory=/opt/fahrgastrechte/current
ExecStart=/opt/fahrgastrechte/current/bin/fahrgastrechte start
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0027

CapabilityBoundingSet=
LockPersonality=true
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectClock=true
ProtectControlGroups=true
ProtectHome=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=strict
ReadWritePaths=/var/lib/fahrgastrechte
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
UNIT

  systemd-analyze verify "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable fahrgastrechte
}

[[ $EUID -eq 0 ]] || die "Das Script muss im LXC als root laufen"

if [[ -z "$PHX_HOST" ]]; then
  PHX_HOST="$(existing_value "$ENV_FILE" PHX_HOST)"
fi
if [[ -z "$APP_REPOSITORY" ]]; then
  APP_REPOSITORY="$(existing_value "$DEPLOYMENT_FILE" APP_REPOSITORY)"
fi
if [[ -z "$APP_REPOSITORY" && -d "${SOURCE_DIR}/.git" ]]; then
  APP_REPOSITORY="$(git -C "$SOURCE_DIR" remote get-url origin)"
fi

PHX_HOST="${PHX_HOST:-fahrgastrechte.local}"
APP_REPOSITORY="${APP_REPOSITORY:-$DEFAULT_APP_REPOSITORY}"

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

export DEBIAN_FRONTEND=noninteractive

log "Installiere bzw. aktualisiere Systempakete"
apt-get update
apt-get install --yes --no-install-recommends autoconf build-essential ca-certificates curl extrepo git libncurses-dev libssl-dev libstdc++6 locales m4 openssl pkg-config postgresql postgresql-contrib sed zlib1g-dev

if ! command -v mise >/dev/null 2>&1; then
  log "Aktiviere das mise-APT-Repository"
  extrepo enable mise
  apt-get update
  apt-get install --yes --no-install-recommends mise
fi

systemctl enable --now postgresql

if ! id "$APP_NAME" >/dev/null 2>&1; then
  useradd --comment "Fahrgastrechte service account" --create-home --home-dir "/var/lib/${APP_NAME}" --shell /usr/sbin/nologin --system --user-group "$APP_NAME"
fi

install --directory --mode 0750 --owner root --group "$APP_NAME" "$APP_ROOT" "${APP_ROOT}/releases" "/etc/${APP_NAME}"
install --directory --mode 0750 --owner "$APP_NAME" --group "$APP_NAME" "/var/lib/${APP_NAME}"

database_password="$(existing_value "$ENV_FILE" DATABASE_PASSWORD)"
secret_key_base="$(existing_value "$ENV_FILE" SECRET_KEY_BASE)"
field_encryption_key="$(existing_value "$ENV_FILE" FIELD_ENCRYPTION_KEY)"

database_password="${database_password:-$(openssl rand -hex 32)}"
secret_key_base="${secret_key_base:-$(openssl rand -base64 64 | tr -d '\n')}"
field_encryption_key="${field_encryption_key:-$(openssl rand -base64 32 | tr -d '\n')}"

[[ "$database_password" =~ ^[a-f0-9]{64}$ ]] ||
  die "Gespeichertes DATABASE_PASSWORD hat ein unerwartetes Format"

log "Konfiguriere die lokale PostgreSQL-Datenbank"
if ! runuser -u postgres -- psql --tuples-only --command "SELECT 1 FROM pg_roles WHERE rolname = '${APP_NAME}'" |
  grep --quiet 1; then
  runuser -u postgres -- psql --set ON_ERROR_STOP=1 --command "CREATE ROLE ${APP_NAME} LOGIN PASSWORD '${database_password}'"
else
  runuser -u postgres -- psql --set ON_ERROR_STOP=1 --command "ALTER ROLE ${APP_NAME} WITH LOGIN PASSWORD '${database_password}'"
fi

if ! runuser -u postgres -- psql --tuples-only --command "SELECT 1 FROM pg_database WHERE datname = '${APP_NAME}_prod'" |
  grep --quiet 1; then
  runuser -u postgres -- createdb --encoding UTF8 --owner "$APP_NAME" --template template0 "${APP_NAME}_prod"
fi

write_runtime_environment "$database_password" "$secret_key_base" "$field_encryption_key"
write_deployment_environment

log "Hole den App-Quellcode (${APP_REF})"
if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
  git clone --no-checkout "$APP_REPOSITORY" "$SOURCE_DIR"
else
  git -C "$SOURCE_DIR" remote set-url origin "$APP_REPOSITORY"
fi

git -C "$SOURCE_DIR" fetch --depth 1 origin "$APP_REF"
git -C "$SOURCE_DIR" checkout --detach --force FETCH_HEAD
source_revision="$(git -C "$SOURCE_DIR" rev-parse --short=12 HEAD)"
release_dir="$(mktemp -d "${APP_ROOT}/releases/${source_revision}-$(date --utc +%Y%m%d%H%M%S)-XXXX")"

export KERL_CONFIGURE_OPTIONS="--without-javac --without-odbc --without-wx"
export MISE_CACHE_DIR="/var/cache/fahrgastrechte-mise"
export MISE_DATA_DIR="${APP_ROOT}/toolchains"
export MISE_JOBS="${MISE_JOBS:-2}"
export MISE_YES=1

install --directory --mode 0755 "$MISE_CACHE_DIR" "$MISE_DATA_DIR"

log "Baue eine neue OTP-Release"
(
  cd "$SOURCE_DIR"
  mise install
  mise exec -- mix local.hex --force
  mise exec -- mix local.rebar --force
  MIX_ENV=prod mise exec -- mix deps.get --only prod
  MIX_ENV=prod mise exec -- mix compile
  MIX_ENV=prod mise exec -- mix assets.deploy
  MIX_ENV=prod mise exec -- mix release --overwrite --path "$release_dir"
)

chown --recursive root:"$APP_NAME" "$release_dir"
chmod --recursive g=rX,o= "$release_dir"

log "Führe Datenbankmigrationen aus"
(
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  "$release_dir/bin/fahrgastrechte" eval "Fahrgastrechte.Release.migrate"
)

previous_release=""
if [[ -L "${APP_ROOT}/current" ]]; then
  previous_release="$(readlink --canonicalize "${APP_ROOT}/current")"
fi

ln --symbolic --force --no-dereference "$release_dir" "${APP_ROOT}/current"
write_systemd_service
write_update_command
systemctl restart fahrgastrechte

log "Prüfe den App-Start"
if ! wait_for_http; then
  if [[ -n "$previous_release" && -d "$previous_release" ]]; then
    log "Healthcheck fehlgeschlagen; aktiviere die vorherige Release"
    ln --symbolic --force --no-dereference "$previous_release" "${APP_ROOT}/current"
    systemctl restart fahrgastrechte
  fi
  die "App antwortet nach 60 Sekunden nicht auf Port 4000"
fi

log "Release $(basename "$release_dir") läuft erfolgreich"
printf '\nUpdate künftig mit: update [GIT-REF]\n'
