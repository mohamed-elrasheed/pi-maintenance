#!/usr/bin/env bash
# monitoring/install.sh - install or upgrade Uptime Kuma (native Node + systemd).
# Run from a checkout of this repo on the Pi:  sudo monitoring/install.sh
#
# 1. Checks the platform and takes a Teleporter backup.
# 2. Installs nodejs, npm and git from Debian (Uptime Kuma needs Node >= 20.4).
# 3. Creates the uptime-kuma system user; its data lives in /var/lib/uptime-kuma.
# 4. Builds Uptime Kuma $KUMA_VERSION in a staging folder as that user, then
#    swaps it into /opt/uptime-kuma. Skipped if that version is already there.
#    On upgrade the data is backed up first and the old app kept in
#    /opt/uptime-kuma.prev.
# 5. Installs and starts the systemd service.
#
# Safe to re-run. To upgrade, change KUMA_VERSION and re-run.

set -euo pipefail
umask 022   # app files must be readable by the uptime-kuma user

KUMA_VERSION=2.5.5
KUMA_REPO=https://github.com/louislam/uptime-kuma.git
APP=/opt/uptime-kuma
STAGING=$APP.new
DATA=/var/lib/uptime-kuma
SVC=uptime-kuma
UNIT=/etc/systemd/system/uptime-kuma.service
CONF=/etc/pi-maintenance.conf
PORT=3001

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo monitoring/install.sh"
cd "$(dirname "$0")"

backup_root=/var/backups/uptime-kuma/$(date +%Y%m%d-%H%M%S)

# backup <path>...: copy existing files/dirs into $backup_root (root-only).
backup() {
    local p
    for p; do
        [[ -e $p ]] || continue
        install -d -m 700 /var/backups/uptime-kuma "$backup_root"
        cp -a --parents "$p" "$backup_root"
        echo "    backed up $p -> $backup_root$p"
    done
}

# as_kuma <command...>: run as the service user, with npm's cache kept out of $DATA.
as_kuma() {
    runuser -u "$SVC" -- env HOME="$DATA" npm_config_cache="$STAGING.npm-cache" "$@"
}

# --- 1. Platform and backup -------------------------------------------------

arch=$(dpkg --print-architecture)
case $arch in
    arm64|amd64) ;;
    *) die "Untested architecture: $arch (prebuilt SQLite bindings may be missing)" ;;
esac

if [[ -f $CONF ]]; then
    backup_dir=$(. "$CONF"; echo "${BACKUP_DIR:-/var/backups/pi-maintenance}")
elif [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    backup_dir=$(getent passwd "$SUDO_USER" | cut -d: -f6)/backups
else
    backup_dir=/var/backups/pi-maintenance
fi
echo "==> Teleporter backup into $backup_dir before changing anything"
mkdir -p "$backup_dir"
start=$(( $(date +%s) - 1 ))
(cd "$backup_dir" && umask 077 && pihole-FTL --teleporter)
zip=$(find "$backup_dir" -maxdepth 1 -name '*teleporter*.zip' -size +0 -newermt "@$start" | head -n1)
[[ -n $zip ]] || die "No new Teleporter zip in $backup_dir; stopping before any change"
echo "    $zip"

# --- 2. Packages ------------------------------------------------------------

missing=()
for pkg in nodejs npm git; do
    dpkg-query -W -f '${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
done
if ((${#missing[@]})); then
    echo "==> Installing ${missing[*]} from Debian"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
else
    echo "==> nodejs, npm and git already installed"
fi
node -e 'const [a, b] = process.versions.node.split(".").map(Number);
         process.exit(a > 20 || (a === 20 && b >= 4) ? 0 : 1)' \
    || die "Node $(node -v) is too old; Uptime Kuma $KUMA_VERSION needs >= 20.4"
echo "    node $(node -v), npm $(npm -v)"

# --- 3. Service user --------------------------------------------------------

if ! id -u "$SVC" >/dev/null 2>&1; then
    echo "==> Creating system user $SVC"
    useradd --system --home-dir "$DATA" --no-create-home --shell /usr/sbin/nologin "$SVC"
fi
install -d -o "$SVC" -g "$SVC" -m 700 "$DATA"

# --- 4. Uptime Kuma ---------------------------------------------------------

installed=""
[[ -f $APP/package.json ]] && installed=$(node -p "require('$APP/package.json').version")
app_changed=0

if [[ $installed == "$KUMA_VERSION" ]]; then
    echo "==> Uptime Kuma $KUMA_VERSION already installed"
else
    echo "==> Building Uptime Kuma $KUMA_VERSION in $STAGING (was: ${installed:-not installed})"
    rm -rf "$STAGING" "$STAGING.npm-cache"
    install -d -o "$SVC" -g "$SVC" "$STAGING" "$STAGING.npm-cache"
    # npm packages run their own install scripts, so never build as root.
    # Work from inside $STAGING: the service user can't read this repo's folder.
    (cd "$STAGING" && as_kuma git clone --quiet --depth 1 --branch "$KUMA_VERSION" "$KUMA_REPO" .)
    (cd "$STAGING" && as_kuma npm ci --omit dev --no-audit --no-fund) \
        || die "npm ci failed; $APP is untouched. If sqlite3 tried to compile, see README (Monitoring)."
    (cd "$STAGING" && as_kuma npm run download-dist) \
        || die "Downloading the prebuilt web UI failed; $APP is untouched"
    rm -rf "$STAGING.npm-cache"
    # The service reads the app but must not be able to change it.
    chown -R root:root "$STAGING"

    if [[ -d $APP ]]; then
        echo "==> Stopping Uptime Kuma to back up its data and swap versions"
        systemctl stop "$SVC" 2>/dev/null || true
        backup "$DATA"
        rm -rf "$APP.prev"
        mv "$APP" "$APP.prev"
        echo "    previous version kept in $APP.prev"
    fi
    mv "$STAGING" "$APP"
    app_changed=1
    echo "    installed $APP"
fi

# --- 5. systemd service -----------------------------------------------------

echo "==> Installing systemd unit"
unit_changed=0
if [[ -f $UNIT ]] && cmp -s uptime-kuma.service "$UNIT"; then
    echo "    $UNIT already up to date"
else
    backup "$UNIT"
    install -o root -g root -m 644 uptime-kuma.service "$UNIT"
    systemctl daemon-reload
    unit_changed=1
    echo "    installed $UNIT"
fi

systemctl enable --quiet "$SVC"
if ((app_changed || unit_changed)); then
    systemctl restart "$SVC"
else
    systemctl start "$SVC"    # no-op if already running
fi

echo "==> Waiting for Uptime Kuma on port $PORT (can take a minute on a Pi 3)"
for _ in $(seq 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 2
done
curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" \
    || die "Uptime Kuma isn't answering; check: journalctl -u $SVC -n 50"

cat <<EOF

==> Uptime Kuma $KUMA_VERSION is running.

    DO THIS NOW: open http://<pi-address>:$PORT from your PC. The FIRST visitor
    creates the admin account, so claim it before anyone else on the LAN can.
    If asked which database to use, choose SQLite.

    The firewall only allows port $PORT from the LAN and Tailscale once you
    re-run: sudo hardening/harden.sh
    Monitors and ntfy setup: see "Monitoring" in the README.
EOF
