#!/usr/bin/env bash
# pi-heartbeat.sh - dead-man switch: ping the healthchecks.io heartbeat check.
#
# Run every 5 minutes by /etc/cron.d/pi-heartbeat. healthchecks.io expects these
# pings; if they stop (Pi off, offline, frozen, cron not running), it sends the
# alert itself. Nothing on the Pi has to work for that alert to go out.
#
# Does nothing if HC_HEARTBEAT_URL is not set in /etc/pi-maintenance.conf.
# Records the last result in /run/pi-heartbeat.status for verify.sh.

set -uo pipefail

CONFIG=${PI_MAINT_CONFIG:-/etc/pi-maintenance.conf}
STATUS=/run/pi-heartbeat.status
HC_HEARTBEAT_URL=""

status() { echo "$* ($(date '+%F %T'))" >"$STATUS"; }

[[ -f $CONFIG ]] || exit 0
# Same rule as pi-maintenance.sh: only source a config that only root can change.
if [[ $(stat -c %u "$CONFIG") != 0 ]] || (( 8#$(stat -c %a "$CONFIG") & 8#022 )); then
    status "FAIL unsafe permissions on $CONFIG"
    exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG"
[[ -n $HC_HEARTBEAT_URL ]] || exit 0

if curl -fsS -m 10 --retry 5 -o /dev/null "$HC_HEARTBEAT_URL" 2>/dev/null; then
    status "OK"
else
    status "FAIL curl exit $?"
fi
