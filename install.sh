#!/usr/bin/env bash
# install.sh - install or update pi-maintenance on the Pi.
# Run from a checkout of this repo on the Pi:  sudo ./install.sh
#
# 1. Takes a Teleporter backup before changing anything.
# 2. Creates /etc/pi-maintenance.conf on first install, with a random ntfy
#    topic that is printed once here and never leaves the Pi otherwise.
# 3. Asks for the healthchecks.io ping URLs if they're missing from the config.
# 4. Installs the scripts, cron jobs and logrotate rule.
# 5. Sends a test alert and a first heartbeat.

set -euo pipefail
umask 077

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./install.sh" >&2; exit 1; }
cd "$(dirname "$0")"

CONF=/etc/pi-maintenance.conf
new_topic=""

# Keep backups where the old script put them: the invoking user's ~/backups.
if [[ -f $CONF ]]; then
    backup_dir=$(. "$CONF"; echo "${BACKUP_DIR:-/var/backups/pi-maintenance}")
elif [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    backup_dir=$(getent passwd "$SUDO_USER" | cut -d: -f6)/backups
else
    backup_dir=/var/backups/pi-maintenance
fi

echo "==> Teleporter backup into $backup_dir before changing anything"
mkdir -p "$backup_dir"
(cd "$backup_dir" && pihole-FTL --teleporter)

if [[ ! -f $CONF ]]; then
    echo "==> Creating $CONF"
    new_topic="pimaint-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    read -rp "Tailscale device name to receive backup copies (blank to skip): " target
    cat >"$CONF" <<EOF
# /etc/pi-maintenance.conf - see pi-maintenance.conf.example in the repo.
BACKUP_DIR=$backup_dir
KEEP_BACKUPS=6
TAILDROP_TARGET=$target
NTFY_SERVER=https://ntfy.sh
NTFY_TOPIC=$new_topic
NTFY_ON_SUCCESS=false
STEP_TIMEOUT=45m
EOF
    chown root:root "$CONF"
    chmod 600 "$CONF"
else
    echo "==> Keeping existing $CONF"
fi

# conf_get KEY: print KEY's value from $CONF (empty if unset).
conf_get() { (. "$CONF"; printf '%s' "${!1:-}"); }

# conf_set KEY VALUE: replace KEY's line in $CONF, or append one.
# VALUE must not contain | or & (ask_hc_url only accepts URL-safe characters).
conf_set() {
    if grep -q "^$1=" "$CONF"; then
        sed -i "s|^$1=.*|$1=$2|" "$CONF"
    else
        echo "$1=$2" >>"$CONF"
    fi
}

# ask_hc_url KEY DESCRIPTION: prompt for a ping URL if KEY is missing or blank.
# $CONF is sourced as root, so only accept characters that are inert in a shell.
ask_hc_url() {
    local url
    [[ -z $(conf_get "$1") ]] || return 0
    while :; do
        read -rp "healthchecks.io ping URL for $2 (blank to skip): " url
        [[ -z $url || $url =~ ^https://[A-Za-z0-9._/:%+=,@-]+$ ]] && break
        echo "    That doesn't look like a ping URL (https://hc-ping.com/...). Try again." >&2
    done
    conf_set "$1" "$url"
}

echo "==> healthchecks.io dead-man switch (see README; blank skips it)"
ask_hc_url HC_HEARTBEAT_URL "the 5-minute heartbeat"
ask_hc_url HC_MAINT_URL "the monthly maintenance run"
if [[ -n $(conf_get HC_MAINT_URL) ]] && ! grep -q '^HC_SEND_LOG=' "$CONF"; then
    echo "    Failure pings can carry the last 20 log lines. They can include the"
    echo "    hostname, backup paths (with your username) and apt output."
    read -rp "Attach them? [y/N] " yn
    if [[ $yn == [yY]* ]]; then conf_set HC_SEND_LOG true; else conf_set HC_SEND_LOG false; fi
fi

echo "==> Installing files"
# One file per bash -n: extra arguments are passed to the script, not checked.
for f in bin/pi-maintenance.sh bin/pi-heartbeat.sh; do bash -n "$f"; done
command -v dig >/dev/null \
    || echo "    WARNING: dig not found; the heartbeat will report /fail until you run: apt install bind9-dnsutils" >&2
install -o root -g root -m 755 bin/pi-maintenance.sh /usr/local/bin/pi-maintenance.sh
install -o root -g root -m 755 bin/pi-heartbeat.sh /usr/local/bin/pi-heartbeat.sh
install -o root -g root -m 644 etc/cron.d/pi-maintenance /etc/cron.d/pi-maintenance
install -o root -g root -m 644 etc/cron.d/pi-heartbeat /etc/cron.d/pi-heartbeat
install -o root -g root -m 644 etc/logrotate.d/pi-maintenance /etc/logrotate.d/pi-maintenance

if [[ -n $new_topic ]]; then
    cat <<EOF

==> Subscribe to alerts in the ntfy app:
      server: https://ntfy.sh
      topic:  $new_topic
    This topic is stored only in $CONF (root-only). Don't share or commit it.

EOF
    read -rp "Press Enter once you've subscribed, to send a test alert... " _
fi

echo "==> Sending test alert"
/usr/local/bin/pi-maintenance.sh --test-alert

if [[ -n $(conf_get HC_HEARTBEAT_URL) ]]; then
    echo "==> Sending first heartbeat"
    /usr/local/bin/pi-heartbeat.sh || true
    echo "    $(cat /run/pi-heartbeat.status 2>/dev/null || echo 'no result recorded')"
fi
echo "==> Done. Next scheduled run: 04:00 on the 1st of the month."
