#!/usr/bin/env bash
# harden.sh - firewall, fail2ban and key-only SSH for the Pi.
# Run from a checkout of this repo on the Pi:  sudo hardening/harden.sh [--user NAME]
#
# 0. Refuses to start unless NAME's authorized_keys holds a valid SSH key, so
#    turning off passwords can't lock you out. NAME defaults to $SUDO_USER.
# 1. Takes a Teleporter backup before changing anything.
# 2. Installs ufw, fail2ban and python3-systemd if missing.
# 3. ufw: deny incoming, allow outgoing; SSH, DNS, the web UI and Uptime Kuma
#    only from the LAN and tailscale0; Tailscale's UDP port; forwarding for the
#    exit node.
#    First enable arms a 5-minute timer that turns ufw off again unless you
#    confirm a new SSH session works.
# 4. fail2ban sshd jail (5 failures -> 1 hour ban).
# 5. Key-only SSH drop-in, checked with sshd -t before reloading.
#
# Safe to re-run. Every file it replaces is copied to
# /var/backups/pi-hardening/<timestamp>/ first.

set -euo pipefail
umask 077

LAN=192.168.0.0/24    # keep in sync with ignoreip in etc/fail2ban/jail.d/sshd.local
CONF=/etc/pi-maintenance.conf
SSH_DROPIN=/etc/ssh/sshd_config.d/00-hardening.conf
F2B_JAIL=/etc/fail2ban/jail.d/sshd.local
ROLLBACK=pi-hardening-ufw-rollback     # transient systemd unit name

# port proto description
SERVICES=(
    "22 tcp SSH"
    "53 tcp DNS"
    "53 udp DNS"
    "80 tcp Pi-hole web UI"
    "443 tcp Pi-hole web UI"
    "3001 tcp Uptime Kuma"
)

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo ./harden.sh"
cd "$(dirname "$0")"

user=${SUDO_USER:-}
while (($#)); do
    case $1 in
        --user) user=${2:?--user needs a name}; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done
[[ -n $user && $user != root ]] || die "Can't tell which account you log in with; pass --user NAME"
grep -qF " $LAN " etc/fail2ban/jail.d/sshd.local \
    || die "LAN=$LAN is not in ignoreip in etc/fail2ban/jail.d/sshd.local; keep them in sync"

backup_root=/var/backups/pi-hardening/$(date +%Y%m%d-%H%M%S)

# backup <path>...: copy existing files/dirs into $backup_root, keeping their path.
backup() {
    local p
    for p; do
        [[ -e $p ]] || continue
        mkdir -p "$backup_root"
        cp -a --parents "$p" "$backup_root"
        echo "    backed up $p -> $backup_root$p"
    done
}

# put_file <src> <dest>: install src as dest (root, 644) unless identical.
# Sets CHANGED=1 if dest was written.
put_file() {
    CHANGED=0
    if [[ -f $2 ]] && cmp -s "$1" "$2"; then
        echo "    $2 already up to date"
        return
    fi
    backup "$2"
    install -o root -g root -m 644 "$1" "$2"
    CHANGED=1
    echo "    installed $2"
}

# --- 0. Lockout safety ------------------------------------------------------

echo "==> Checking that $user can log in with an SSH key"
home=$(getent passwd "$user" | cut -d: -f6) || die "No such user: $user"
keys=$home/.ssh/authorized_keys
[[ -f $keys ]] || die "$keys does not exist. Add your public key first (ssh-copy-id from your PC)."
nkeys=$({ ssh-keygen -l -f "$keys" 2>/dev/null || true; } | wc -l)
((nkeys > 0)) || die "$keys has no valid keys. Refusing to turn off password login."
# sshd ignores keys if these are writable by group/others (StrictModes).
bad_perms=$(find "$home" "$home/.ssh" "$keys" -maxdepth 0 -perm /022)
[[ -z $bad_perms ]] || die "sshd would ignore your key; fix permissions with chmod go-w on: $bad_perms"
echo "    found $nkeys key(s) in $keys"

# --- 1. Teleporter backup ---------------------------------------------------

if [[ -f $CONF ]]; then
    backup_dir=$(. "$CONF"; echo "${BACKUP_DIR:-/var/backups/pi-maintenance}")
else
    backup_dir=$home/backups
fi
echo "==> Teleporter backup into $backup_dir before changing anything"
mkdir -p "$backup_dir"
start=$(( $(date +%s) - 1 ))
(cd "$backup_dir" && pihole-FTL --teleporter)
zip=$(find "$backup_dir" -maxdepth 1 -name '*teleporter*.zip' -size +0 -newermt "@$start" | head -n1)
[[ -n $zip ]] || die "No new Teleporter zip in $backup_dir; stopping before any change"
echo "    $zip"

# --- 2. Packages ------------------------------------------------------------

missing=()
for pkg in ufw fail2ban python3-systemd; do
    dpkg-query -W -f '${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
done
if ((${#missing[@]})); then
    echo "==> Installing ${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
else
    echo "==> ufw, fail2ban and python3-systemd already installed"
fi

# --- 3. ufw -----------------------------------------------------------------

wan_if=$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit }}')
[[ -n $wan_if ]] || die "No default route; can't tell which interface exit-node traffic leaves by"

echo "==> Configuring ufw (LAN $LAN, tailscale0, exit node out via $wan_if)"
backup /etc/ufw /etc/default/ufw
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
for s in "${SERVICES[@]}"; do
    read -r port proto name <<<"$s"
    ufw allow proto "$proto" from "$LAN" to any port "$port" comment "$name from LAN"
    ufw allow in on tailscale0 proto "$proto" to any port "$port" comment "$name over Tailscale"
done
ufw allow 41641/udp comment 'Tailscale direct connections'
ufw route allow in on tailscale0 out on "$wan_if" comment 'Tailscale exit node'

if ! grep -q '^Status: active' <<<"$(ufw status)"; then
    echo "==> Enabling ufw, with a timer that turns it off again in 5 minutes"
    systemctl stop "$ROLLBACK.timer" "$ROLLBACK.service" 2>/dev/null || true
    systemd-run --quiet --unit="$ROLLBACK" --on-active=5m /usr/sbin/ufw disable
    ufw --force enable
fi
if systemctl is-active --quiet "$ROLLBACK.timer"; then
    cat <<EOF

    The firewall is on. KEEP THIS SESSION OPEN. In a NEW terminal on your PC, run:
        ssh pihole true
    If that fails, do nothing: ufw turns itself off within 5 minutes.

EOF
    read -rp "Type 'yes' once the new SSH session worked: " ok
    [[ $ok == yes ]] || die "Leaving the timer running; ufw will turn itself off. Fix the rules and re-run."
    systemctl stop "$ROLLBACK.timer"
    echo "    timer cancelled; ufw stays on"
fi

# --- 4. fail2ban ------------------------------------------------------------

echo "==> Configuring fail2ban sshd jail"
put_file etc/fail2ban/jail.d/sshd.local "$F2B_JAIL"
fail2ban-client -t >/dev/null || die "fail2ban config test failed (fail2ban-client -t)"
systemctl enable --quiet fail2ban
systemctl restart fail2ban

# --- 5. Key-only SSH --------------------------------------------------------

echo "==> Installing key-only SSH drop-in"
put_file etc/ssh/sshd_config.d/00-hardening.conf "$SSH_DROPIN"
undo_ssh() {
    if ((CHANGED)); then
        if [[ -f $backup_root$SSH_DROPIN ]]; then cp -a "$backup_root$SSH_DROPIN" "$SSH_DROPIN"; else rm -f "$SSH_DROPIN"; fi
        echo "    restored the previous $SSH_DROPIN"
    fi
}
sshd -t || { undo_ssh; die "sshd -t rejected the config; SSH was NOT reloaded"; }
effective=$(sshd -T)
for want in 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitrootlogin no'; do
    grep -qx "$want" <<<"$effective" \
        || { undo_ssh; die "sshd -T does not show '$want' (another config file overrides it); SSH was NOT reloaded"; }
done
systemctl reload ssh
echo "    sshd reloaded; existing sessions stay connected"

cat <<EOF

==> Done. KEEP THIS SESSION OPEN and, in a NEW terminal on your PC, check:
      ssh pihole true
          should succeed (key login)
      ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password pihole
          should fail with "Permission denied (publickey)"
    Only close this session once both behave. If the key login fails, undo with:
      sudo rm $SSH_DROPIN && sudo systemctl reload ssh

    Full status: sudo hardening/verify.sh
EOF
