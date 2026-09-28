#!/usr/bin/env bash
# canary/install.sh - install or upgrade the OpenCanary honeypot (Python venv + systemd).
# Run from a checkout of this repo on the Pi:  sudo canary/install.sh
#
# 1. Checks the platform and free memory, reads the ntfy settings from
#    /etc/pi-maintenance.conf, and takes a Teleporter backup.
# 2. Installs python3-venv from Debian.
# 3. Creates the opencanary system user; its state (SSH host keys) lives in
#    /var/lib/opencanary.
# 4. Builds OpenCanary $OC_VERSION in a venv in a staging folder as that user,
#    then swaps it into /opt/opencanary. Skipped if that version is already
#    there. On upgrade the old venv is kept in /opt/opencanary.prev.
# 5. Installs the config, the ntfy handler, the ntfy credential and the systemd
#    unit, starts the service and checks that all fake services are listening.
#
# Safe to re-run. Re-run after changing the ntfy topic. To upgrade, change
# OC_VERSION and re-run.

set -euo pipefail
umask 022   # venv and handler must be readable by the opencanary user

OC_VERSION=0.9.10
VENV=/opt/opencanary
STAGING=$VENV.new
STATE=/var/lib/opencanary
SVC=opencanary
ETC=/etc/opencanaryd
OC_CONF=$ETC/opencanary.conf
CRED=$ETC/ntfy-url
HANDLER_DIR=/usr/local/lib/opencanary-ntfy
UNIT=/etc/systemd/system/opencanary.service
CONF=/etc/pi-maintenance.conf
PORTS=(21 23 2222 3306 8080)   # keep in sync with opencanary.conf and hardening/harden.sh
MIN_AVAIL_MB=150

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo canary/install.sh"
cd "$(dirname "$0")"

backup_root=/var/backups/opencanary/$(date +%Y%m%d-%H%M%S)

# backup <path>...: copy existing files/dirs into $backup_root (root-only).
backup() {
    local p
    for p; do
        [[ -e $p ]] || continue
        install -d -m 700 /var/backups/opencanary "$backup_root"
        cp -a --parents "$p" "$backup_root"
        echo "    backed up $p -> $backup_root$p"
    done
}

# put_file <src> <dest> <owner:group> <mode>: install src as dest unless identical.
# Sets CHANGED=1 if dest was written. Never prints file contents.
put_file() {
    CHANGED=0
    if [[ -f $2 ]] && cmp -s "$1" "$2" \
        && [[ $(stat -c '%U:%G %a' "$2") == "$3 $4" ]]; then
        echo "    $2 already up to date"
        return
    fi
    backup "$2"
    install -D -o "${3%%:*}" -g "${3##*:}" -m "$4" "$1" "$2"
    CHANGED=1
    echo "    installed $2"
}

# conf_get KEY: value of KEY in $CONF. Greps rather than sources, so nothing in
# the config is executed.
conf_get() {
    sed -n "s/^$1=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*\$/\1/p" "$CONF" | tail -n1
}

# listening <port>: something is listening on TCP <port>.
listening() { [[ -n $(ss -Hltn "sport = :$1") ]]; }

# --- 1. Checks and backup ---------------------------------------------------

arch=$(dpkg --print-architecture)
case $arch in
    arm64|amd64) ;;
    *) die "Untested architecture: $arch" ;;
esac

avail_mb=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
((avail_mb >= MIN_AVAIL_MB)) \
    || die "Only ${avail_mb} MB available (need $MIN_AVAIL_MB); OpenCanary would compete with Pi-hole for memory"
echo "==> ${avail_mb} MB memory available"

[[ -f $CONF ]] || die "$CONF not found; run ./install.sh first (it creates the ntfy topic)"
ntfy_server=$(conf_get NTFY_SERVER)
ntfy_server=${ntfy_server:-https://ntfy.sh}
ntfy_topic=$(conf_get NTFY_TOPIC)
[[ $ntfy_server =~ ^https?://[A-Za-z0-9.:-]+/?$ ]] || die "NTFY_SERVER in $CONF doesn't look like https://host"
[[ $ntfy_topic =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "NTFY_TOPIC in $CONF is missing or has unexpected characters"
echo "==> ntfy settings found in $CONF"

backup_dir=$(conf_get BACKUP_DIR)
backup_dir=${backup_dir:-/var/backups/pi-maintenance}
echo "==> Teleporter backup into $backup_dir before changing anything"
mkdir -p "$backup_dir"
start=$(( $(date +%s) - 1 ))
(cd "$backup_dir" && umask 077 && pihole-FTL --teleporter)
zip=$(find "$backup_dir" -maxdepth 1 -name '*teleporter*.zip' -size +0 -newermt "@$start" | head -n1)
[[ -n $zip ]] || die "No new Teleporter zip in $backup_dir; stopping before any change"
echo "    $zip"

# --- 2. Packages ------------------------------------------------------------

if dpkg-query -W -f '${Status}' python3-venv 2>/dev/null | grep -q 'install ok installed'; then
    echo "==> python3-venv already installed"
else
    echo "==> Installing python3-venv from Debian"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-venv
fi
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
    || die "Python $(python3 -V) is too old; OpenCanary needs >= 3.10"
echo "    $(python3 -V)"

# --- 3. Service user --------------------------------------------------------

if ! id -u "$SVC" >/dev/null 2>&1; then
    echo "==> Creating system user $SVC"
    useradd --system --home-dir "$STATE" --no-create-home --shell /usr/sbin/nologin "$SVC"
fi
install -d -o "$SVC" -g "$SVC" -m 700 "$STATE"

# --- 4. OpenCanary venv -----------------------------------------------------

installed=""
[[ -x $VENV/bin/python ]] && installed=$("$VENV/bin/python" -c \
    'from importlib.metadata import version; print(version("opencanary"))' 2>/dev/null || true)
venv_changed=0

if [[ $installed == "$OC_VERSION" ]]; then
    echo "==> OpenCanary $OC_VERSION already installed"
else
    echo "==> Building OpenCanary $OC_VERSION in $STAGING (was: ${installed:-not installed})"
    rm -rf "$STAGING"
    install -d -o "$SVC" -g "$SVC" "$STAGING"
    # pip runs package build scripts, so never build as root.
    # Work from inside $STAGING: the service user can't read this repo's folder.
    (cd "$STAGING" && runuser -u "$SVC" -- env HOME="$STATE" python3 -m venv "$STAGING")
    (cd "$STAGING" && runuser -u "$SVC" -- env HOME="$STATE" \
        "$STAGING/bin/pip" install --quiet --no-cache-dir "opencanary==$OC_VERSION") \
        || die "pip install failed; $VENV is untouched. If a package tried to compile, see README (Honeypot)."
    # The service reads the venv but must not be able to change it.
    chown -R root:root "$STAGING"
    # Twisted caches its plugin list next to its code. Write it now, as root,
    # so the read-only service doesn't try to on every start.
    "$STAGING/bin/python" -c 'from twisted.plugin import IPlugin, getPlugins; list(getPlugins(IPlugin))'

    if [[ -d $VENV ]]; then
        echo "==> Stopping OpenCanary to swap versions"
        systemctl stop "$SVC" 2>/dev/null || true
        rm -rf "$VENV.prev"
        mv "$VENV" "$VENV.prev"
        echo "    previous version kept in $VENV.prev"
    fi
    mv "$STAGING" "$VENV"
    venv_changed=1
    echo "    installed $VENV"
fi

# --- 5. Config, handler, credential, unit -----------------------------------

echo "==> Installing config, ntfy handler and systemd unit"
python3 -m json.tool opencanary.conf >/dev/null || die "canary/opencanary.conf is not valid JSON"
files_changed=0

install -d -o root -g "$SVC" -m 750 "$ETC"
put_file opencanary.conf "$OC_CONF" "root:$SVC" 640;              files_changed=$((files_changed | CHANGED))
put_file pi_canary_ntfy.py "$HANDLER_DIR/pi_canary_ntfy.py" root:root 644; files_changed=$((files_changed | CHANGED))

# The credential holds the topic: build it in a root-only temp file, never echo it.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s/%s\n' "${ntfy_server%/}" "$ntfy_topic" >"$tmp"
put_file "$tmp" "$CRED" root:root 600;                              files_changed=$((files_changed | CHANGED))

put_file opencanary.service "$UNIT" root:root 644
if ((CHANGED)); then
    systemctl daemon-reload
    files_changed=1
fi

if ! systemctl is-active --quiet "$SVC"; then
    busy=()
    for p in "${PORTS[@]}"; do listening "$p" && busy+=("$p"); done
    ((${#busy[@]} == 0)) || die "Port(s) ${busy[*]} already in use (see: sudo ss -ltnp); not starting OpenCanary"
fi

systemctl enable --quiet "$SVC"
if ((venv_changed || files_changed)); then
    systemctl restart "$SVC"
else
    systemctl start "$SVC"    # no-op if already running
fi

echo "==> Waiting for the fake services on ports ${PORTS[*]}"
missing=()
for _ in $(seq 30); do
    missing=()
    for p in "${PORTS[@]}"; do listening "$p" || missing+=("$p"); done
    ((${#missing[@]} == 0)) && break
    sleep 1
done
((${#missing[@]} == 0)) \
    || die "Not listening on ${missing[*]}; check: journalctl -u $SVC -n 50"

cat <<EOF

==> OpenCanary $OC_VERSION is running (ports ${PORTS[*]}).

    Alerts go to your pi-maintenance ntfy topic. Every event is also in:
        journalctl -u $SVC
    The firewall only allows these ports from the LAN and Tailscale once you
    re-run: sudo hardening/harden.sh
    Then test it from your laptop: see "Honeypot" in the README.
EOF
