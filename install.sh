#!/usr/bin/env bash
# install.sh - install or update pi-maintenance on the Pi.
# Run from a checkout of this repo on the Pi:  sudo ./install.sh
#
# 1. Takes a Teleporter backup before changing anything.
# 2. Creates /etc/pi-maintenance.conf on first install, with a random ntfy
#    topic that is printed once here and never leaves the Pi otherwise.
# 3. Installs the script, cron job and logrotate rule.
# 4. Sends a test alert.

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

echo "==> Installing files"
bash -n bin/pi-maintenance.sh
install -o root -g root -m 755 bin/pi-maintenance.sh /usr/local/bin/pi-maintenance.sh
install -o root -g root -m 644 etc/cron.d/pi-maintenance /etc/cron.d/pi-maintenance
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
echo "==> Done. Next scheduled run: 04:00 on the 1st of the month."
