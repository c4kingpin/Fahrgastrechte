#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_NAME="fahrgastrechte"
readonly APP_ROOT="/opt/fahrgastrechte"
readonly ENV_FILE="/etc/fahrgastrechte/fahrgastrechte.env"
readonly SERVICE_FILE="/etc/systemd/system/fahrgastrechte.service"
readonly SOURCE_DIR="${APP_ROOT}/source"

APP_REPOSITORY="${APP_REPOSITORY:-https://github.com/c4kingpin/Fahrgastrechte.git}"
APP_REF="${APP_REF:-main}"
PHX_HOST="${PHX_HOST:-fahrgastrechte.local}"

log() {
  printf '[provision-lxc] %s\n' "$*"
}

die() {
  printf '[provision-lxc] Fehler: %s\n' "$*" >&2
  exit 1
}

existing_env_value() {
  local key="$1"

  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
}

wait_for_http() {
  local _attempt

  for _attempt in {1..30}; do
    if curl --fail --silent --show-error \
      --header 'Host: localhost' \
      http://127.0.0.1:4000/ >/dev/null; then
      return
    fi

    sleep 2
  done

  journalctl --unit fahrgastrechte --no-pager --lines 80 >&2 || true
  die "App antwortet nach 60 Sekunden nicht auf Port 4000"
}

[[ $EUID -eq 0 ]] || die "Das Script muss im LXC als root laufen"
[[ "$PHX_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "PHX_HOST enthält ungültige Zeichen"

export DEBIAN_FRONTEND=noninteractive

log "Installiere Systempakete"
apt-get update
apt-get install --yes --no-install-recommends \
  autoconf \
  build-essential \
  ca-certificates \
  curl \
  extrepo \
  git \
  libncurses-dev \
  libssl-dev \
  libstdc++6 \
  locales \
  m4 \
  openssl \
  pkg-config \
  postgresql \
  postgresql-contrib \
  sed \
  zlib1g-dev

if ! command -v mise >/dev/null 2>&1; then
  log "Aktiviere das offizielle mise-APT-Repository"
  extrepo enable mise
  apt-get update
  apt-get install --yes --no-install-recommends mise
fi

systemctl enable --now postgresql

if ! id "$APP_NAME" >/dev/null 2>&1; then
  useradd \
    --comment "Fahrgastrechte service account" \
    --create-home \
    --home-dir "/var/lib/${APP_NAME}" \
    --shell /usr/sbin/nologin \
    --system \
    --user-group \
    "$APP_NAME"
fi

install --directory --mode 0750 --owner root --group "$APP_NAME" \
  "$APP_ROOT" \
  "${APP_ROOT}/releases" \
  "/etc/${APP_NAME}"
install --directory --mode 0750 --owner "$APP_NAME" --group "$APP_NAME" \
  "/var/lib/${APP_NAME}"

database_password="$(existing_env_value DATABASE_PASSWORD)"
secret_key_base="$(existing_env_value SECRET_KEY_BASE)"
field_encryption_key="$(existing_env_value FIELD_ENCRYPTION_KEY)"

if [[ -z "$database_password" ]]; then
  database_password="$(openssl rand -hex 32)"
fi

if [[ -z "$secret_key_base" ]]; then
  secret_key_base="$(openssl rand -base64 64 | tr -d '\n')"
fi

if [[ -z "$field_encryption_key" ]]; then
  field_encryption_key="$(openssl rand -base64 32 | tr -d '\n')"
fi

[[ "$database_password" =~ ^[a-f0-9]{64}$ ]] ||
  die "Gespeichertes DATABASE_PASSWORD hat ein unerwartetes Format"

log "Konfiguriere lokale PostgreSQL-Datenbank"
if ! runuser -u postgres -- psql --tuples-only --command \
  "SELECT 1 FROM pg_roles WHERE rolname = '${APP_NAME}'" |
  grep --quiet 1; then
  runuser -u postgres -- psql --set ON_ERROR_STOP=1 --command \
    "CREATE ROLE ${APP_NAME} LOGIN PASSWORD '${database_password}'"
else
  runuser -u postgres -- psql --set ON_ERROR_STOP=1 --command \
    "ALTER ROLE ${APP_NAME} WITH LOGIN PASSWORD '${database_password}'"
fi

if ! runuser -u postgres -- psql --tuples-only --command \
  "SELECT 1 FROM pg_database WHERE datname = '${APP_NAME}_prod'" |
  grep --quiet 1; then
  runuser -u postgres -- createdb \
    --encoding UTF8 \
    --owner "$APP_NAME" \
    --template template0 \
    "${APP_NAME}_prod"
fi

umask 027
temporary_env="$(mktemp "/etc/${APP_NAME}/fahrgastrechte.env.XXXXXX")"
trap 'rm -f "$temporary_env"' EXIT

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
trap - EXIT

log "Hole App-Quellcode (${APP_REF})"
if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
  git clone --no-checkout "$APP_REPOSITORY" "$SOURCE_DIR"
else
  git -C "$SOURCE_DIR" remote set-url origin "$APP_REPOSITORY"
fi

git -C "$SOURCE_DIR" fetch --depth 1 origin "$APP_REF"
git -C "$SOURCE_DIR" checkout --detach --force FETCH_HEAD
source_revision="$(git -C "$SOURCE_DIR" rev-parse --short=12 HEAD)"
release_id="${source_revision}-$(date --utc +%Y%m%d%H%M%S)"
release_dir="${APP_ROOT}/releases/${release_id}"

export KERL_CONFIGURE_OPTIONS="--without-javac --without-odbc --without-wx"
export MISE_CACHE_DIR="/var/cache/fahrgastrechte-mise"
export MISE_DATA_DIR="${APP_ROOT}/toolchains"
export MISE_JOBS="${MISE_JOBS:-4}"
export MISE_YES=1

install --directory --mode 0755 "$MISE_CACHE_DIR" "$MISE_DATA_DIR"

log "Installiere die im Repository festgelegte Erlang-/Elixir-Toolchain"
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

ln --symbolic --force --no-dereference "$release_dir" "${APP_ROOT}/current"

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
systemctl restart fahrgastrechte

log "Prüfe App-Start"
wait_for_http
log "Release ${release_id} läuft erfolgreich"
