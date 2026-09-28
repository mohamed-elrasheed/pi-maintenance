#!/usr/bin/env bash
# pi-heartbeat.sh - dead-man switch: check that DNS resolves, then ping the
# healthchecks.io heartbeat check.
#
# Run every 5 minutes by /etc/cron.d/pi-heartbeat. healthchecks.io expects these
# pings; if they stop (Pi off, offline, frozen, cron not running), it sends the
# alert itself. Nothing on the Pi has to work for that alert to go out.
#
# Before pinging, asks Pi-hole (127.0.0.1:53) for a random name under example.com,
# new every run. Pi-hole has never seen that name, so it can't answer from its
# cache and has to ask Unbound; a cached answer would hide a dead Unbound.
#   NOERROR or NXDOMAIN          -> the resolver works: normal ping.
#   SERVFAIL, REFUSED, no answer -> broken: ping /fail, so healthchecks.io alerts
#                                   now instead of after the grace period.
#
# Does nothing if HC_HEARTBEAT_URL is not set in /etc/pi-maintenance.conf.
# Records the last result in /run/pi-heartbeat.status for verify.sh.

set -uo pipefail

CONFIG=${PI_MAINT_CONFIG:-/etc/pi-maintenance.conf}
STATUS=/run/pi-heartbeat.status
HC_HEARTBEAT_URL=""

status() { echo "$* ($(date '+%F %T'))" >"$STATUS"; }

# dns_check: print what Pi-hole answered for a fresh random name.
# Returns 1 if the answer means DNS is broken.
dns_check() {
    local name answer rcode
    command -v dig >/dev/null || { echo "check impossible: dig not installed (bind9-dnsutils)"; return 1; }
    name="hb-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n').example.com"
    # 3 s per try, 1 retry: at most ~6 s, so a hung resolver can't pile up cron runs.
    answer=$(dig @127.0.0.1 -p 53 "$name" A +time=3 +retry=1 +noall +comments 2>&1)
    rcode=$(sed -n 's/.*status: \([A-Z]*\).*/\1/p' <<<"$answer" | head -n 1)
    case $rcode in
        NOERROR|NXDOMAIN) echo "$rcode for $name"; return 0 ;;
        "")               echo "no answer for $name (timeout, or Pi-hole not listening)" ;;
        *)                echo "$rcode for $name" ;;
    esac
    return 1
}

[[ -f $CONFIG ]] || exit 0
# Same rule as pi-maintenance.sh: only source a config that only root can change.
if [[ $(stat -c %u "$CONFIG") != 0 ]] || (( 8#$(stat -c %a "$CONFIG") & 8#022 )); then
    status "FAIL unsafe permissions on $CONFIG"
    exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG"
[[ -n $HC_HEARTBEAT_URL ]] || exit 0

if dns=$(dns_check); then
    state=OK   url=$HC_HEARTBEAT_URL
else
    state=FAIL url=${HC_HEARTBEAT_URL%/}/fail
fi

# The body shows in the check's event log on healthchecks.io, so a /fail says why.
if curl -fsS -m 10 --retry 5 -o /dev/null --data-binary "dns $dns" "$url" 2>/dev/null; then
    status "$state dns $dns"
else
    status "FAIL ping: curl exit $?; dns $dns"
fi
