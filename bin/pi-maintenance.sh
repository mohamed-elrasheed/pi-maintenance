#!/usr/bin/env bash
# pi-maintenance.sh - unattended monthly maintenance for a Pi-hole + Unbound host.
#
# Steps, in order:
#   1. backup         Pi-hole Teleporter export. Critical: if it fails, nothing
#                     else runs, so the Pi is never upgraded without a restore point.
#   2. prune          Delete all but the newest $KEEP_BACKUPS exports.
#   3. taildrop       Copy the newest export to a PC over Tailscale. Optional:
#                     a failure is a warning (the PC may just be asleep).
#   4. apt-update     Refresh package lists.
#   5. apt-upgrade    Full OS upgrade. Skipped if apt-update failed.
#   6. pihole-update  Update Pi-hole core, web UI and FTL.
#   7. services       Confirm pihole-FTL and unbound are still running.
#   8. reboot         Only if the OS asks for one AND every step succeeded.
#
# Every step's outcome is logged with its exit code. If anything fails, an
# alert is sent to ntfy at the end of the run.
#
# Usage: pi-maintenance.sh               run maintenance (cron does this)
#        pi-maintenance.sh --test-alert  send a test notification and exit

set -uo pipefail   # no -e: each step's failure is handled explicitly
umask 077          # backups and log stay readable by root only

# cron.d jobs start with PATH=/usr/bin:/bin, which misses pihole and reboot.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONFIG=${PI_MAINT_CONFIG:-/etc/pi-maintenance.conf}
LOG=/var/log/pi-maintenance.log
LOCK=/run/pi-maintenance.lock

# Defaults; override any of these in $CONFIG.
BACKUP_DIR=/var/backups/pi-maintenance
KEEP_BACKUPS=6
TAILDROP_TARGET=""            # Tailscale device name; empty = skip the copy
NTFY_SERVER=https://ntfy.sh
NTFY_TOPIC=""                 # long random string; treat it like a password
NTFY_ON_SUCCESS=false         # true = also send a quiet "all good" message
STEP_TIMEOUT=45m              # upper bound for apt and pihole -up

FAILED=()
WARNINGS=()
LATEST=""

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

die() { log "FATAL $*"; exit 1; }

# notify <priority> <tags> <title> <message>
# Deliberately sends no log content: the ntfy server is a third party.
notify() {
    if [[ -z $NTFY_TOPIC ]]; then
        log "WARN  NTFY_TOPIC is not set; alert not sent"
        return 1
    fi
    curl -fsS --max-time 20 --retry 3 \
        -H "Priority: $1" -H "Tags: $2" -H "Title: $3" \
        -d "$4" "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null \
        || { log "WARN  ntfy alert failed (curl exit $?)"; return 1; }
}

# run_step <name> <command...>: run one step, log the result, record failures.
run_step() {
    local name=$1 rc=0
    shift
    log "START $name"
    "$@" || rc=$?
    if (( rc == 0 )); then
        log "OK    $name"
    elif (( rc == 124 )); then
        log "FAIL  $name (timed out after $STEP_TIMEOUT)"
        FAILED+=("$name")
    else
        log "FAIL  $name (exit $rc)"
        FAILED+=("$name")
    fi
    return "$rc"
}

# Teleporter file names contain no spaces, so parsing ls output is safe here.
newest_backup() { ls -1t "$BACKUP_DIR"/*.zip 2>/dev/null | head -n 1; }

backup() {
    mkdir -p "$BACKUP_DIR" || return
    local before
    before=$(newest_backup)
    (cd "$BACKUP_DIR" && timeout 10m pihole-FTL --teleporter) || return
    LATEST=$(newest_backup)
    # pihole-FTL can exit 0 without writing a file; verify one actually appeared.
    if [[ -z $LATEST || $LATEST == "$before" || ! -s $LATEST ]]; then
        log "no new, non-empty backup appeared in $BACKUP_DIR"
        return 1
    fi
    log "backup: $LATEST"
}

prune_backups() {
    local old=()
    mapfile -t old < <(ls -1t "$BACKUP_DIR"/*.zip 2>/dev/null | tail -n +"$((KEEP_BACKUPS + 1))")
    (( ${#old[@]} == 0 )) && return 0
    rm -f -- "${old[@]}" && log "pruned ${#old[@]} old backup(s)"
}

send_to_pc() {
    if [[ -z $TAILDROP_TARGET ]]; then
        log "SKIP  taildrop (TAILDROP_TARGET not set)"
        return 0
    fi
    log "START taildrop"
    if timeout 5m tailscale file cp "$LATEST" "$TAILDROP_TARGET:"; then
        log "OK    taildrop"
    else
        log "WARN  taildrop to $TAILDROP_TARGET failed; backup kept on the Pi"
        WARNINGS+=("Taildrop to $TAILDROP_TARGET failed (PC offline?); backup kept on the Pi")
    fi
}

apt_upgrade() {
    DEBIAN_FRONTEND=noninteractive timeout "$STEP_TIMEOUT" apt-get -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        full-upgrade
}

check_services() {
    local svc rc=0
    for svc in pihole-FTL unbound; do
        if systemctl is-active --quiet "$svc"; then
            log "$svc is active"
        else
            log "$svc is NOT active"
            rc=1
        fi
    done
    return "$rc"
}

summarize() {
    local host
    host=$(hostname)
    if (( ${#FAILED[@]} )); then
        log "=== finished with failures: ${FAILED[*]} ==="
        notify high "warning" "$host maintenance failed" \
            "Failed: ${FAILED[*]}${WARNINGS:+. Warnings: ${WARNINGS[*]}}. See $LOG on $host."
    elif (( ${#WARNINGS[@]} )); then
        log "=== finished with warnings ==="
        notify default "information_source" "$host maintenance: warnings" "${WARNINGS[*]}"
    else
        log "=== finished OK ==="
        [[ $NTFY_ON_SUCCESS == true ]] && notify low "white_check_mark" "$host maintenance OK" "All steps succeeded."
    fi
}

on_signal() {
    log "FAIL  interrupted by signal"
    FAILED+=("interrupted")
    summarize
    exit 130
}

main() {
    log "=== pi-maintenance start (pid $$) ==="

    if ! run_step backup backup; then
        log "SKIP  everything else: no upgrades without a fresh backup"
        return
    fi
    run_step prune prune_backups
    send_to_pc

    if run_step apt-update timeout "$STEP_TIMEOUT" apt-get update; then
        run_step apt-upgrade apt_upgrade
    else
        log "SKIP  apt-upgrade (apt-update failed)"
    fi

    run_step pihole-update timeout "$STEP_TIMEOUT" pihole -up
    run_step services check_services

    if [[ -f /var/run/reboot-required ]]; then
        if (( ${#FAILED[@]} )); then
            log "SKIP  reboot: required, but steps failed; leaving the Pi up for inspection"
            WARNINGS+=("Reboot pending (skipped because steps failed)")
        else
            REBOOT=1
        fi
    fi
}

# ---- entry point ----

[[ $EUID -eq 0 ]] || { echo "pi-maintenance: must run as root" >&2; exit 1; }

# Everything from here on goes to the log (and to the terminal when run by hand).
if [[ -t 1 ]]; then
    exec > >(tee -a "$LOG") 2>&1
else
    exec >>"$LOG" 2>&1
fi

# The config is sourced as root, so refuse it unless only root can change it.
if [[ -f $CONFIG ]]; then
    [[ $(stat -c %u "$CONFIG") == 0 ]] || die "$CONFIG must be owned by root"
    (( 8#$(stat -c %a "$CONFIG") & 8#022 )) && die "$CONFIG must not be group/world-writable"
    # shellcheck source=/dev/null
    . "$CONFIG"
else
    log "WARN  $CONFIG not found; using defaults (no alerts will be sent)"
fi
[[ $KEEP_BACKUPS =~ ^[1-9][0-9]*$ ]] || die "KEEP_BACKUPS must be a positive integer"

if [[ ${1:-} == --test-alert ]]; then
    notify default "test_tube" "$(hostname) test alert" "pi-maintenance alerts are working." \
        && log "test alert sent"
    exit
fi

exec 9>"$LOCK"
flock -n 9 || die "another run is already in progress"

trap on_signal INT TERM
REBOOT=0
main
summarize

if (( REBOOT )); then
    log "rebooting (reboot-required was set)"
    systemctl reboot
fi
(( ${#FAILED[@]} == 0 ))
