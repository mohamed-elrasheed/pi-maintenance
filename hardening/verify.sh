#!/usr/bin/env bash
# verify.sh - show the Pi's hardening state. Read-only; changes nothing.
# Run from a checkout of this repo on the Pi:  sudo hardening/verify.sh
#
# Prints ufw status, the fail2ban sshd jail, the effective sshd settings, the
# healthchecks.io dead-man switch (including its DNS check) and the OpenCanary
# honeypot, then a summary of OK/FAIL checks. Exits 1 if any check failed. Never
# prints the ping URLs or the ntfy topic.

set -uo pipefail   # no -e: keep going and report everything

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./verify.sh" >&2; exit 1; }

ROLLBACK=pi-hardening-ufw-rollback
CONF=/etc/pi-maintenance.conf
HB_STATUS=/run/pi-heartbeat.status
CANARY_UNIT=/etc/systemd/system/opencanary.service
CANARY_CRED=/etc/opencanaryd/ntfy-url
CANARY_PORTS=(21 23 2222 3306 8080)   # keep in sync with canary/install.sh
failures=0

section() { printf '\n==> %s\n' "$*"; }

# check <description> <command...>
check() {
    local what=$1; shift
    if "$@" >/dev/null 2>&1; then
        echo "OK    $what"
    else
        echo "FAIL  $what"
        failures=$((failures + 1))
    fi
}

has_line() { grep -qx "$1" <<<"$2"; }

# conf_has KEY: KEY has a non-empty value in $CONF. Greps rather than sources,
# so nothing in the config is executed or printed.
conf_has() { grep -Eq "^$1=[\"']?[^\"' ]" "$CONF" 2>/dev/null; }

listening() { [[ -n $(ss -Hltn "sport = :$1") ]]; }

# ufw_scoped PORT: PORT is allowed from the LAN and over tailscale0, and not
# from Anywhere on every interface.
ufw_scoped() {
    grep -Eq "^$1/tcp +ALLOW IN .*from LAN" <<<"$ufw_status"         && grep -Eq "^$1/tcp on tailscale0 +ALLOW IN" <<<"$ufw_status"         && ! grep -Eq "^$1/tcp +ALLOW IN +Anywhere" <<<"$ufw_status"
}

heartbeat_recent() { [[ -n $(find "$HB_STATUS" -mmin -10 2>/dev/null) ]]; }

section "ufw status"
ufw_status=$(ufw status verbose 2>&1)
echo "$ufw_status"

section "fail2ban: sshd jail"
fail2ban-client status sshd
echo "Never banned: $(fail2ban-client get sshd ignoreip 2>/dev/null | sed -n 's/^[|`]- //p' | tr '\n' ' ')"

section "Effective sshd settings (sshd -T)"
sshd_T=$(sshd -T 2>&1)
grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication) ' <<<"$sshd_T"

section "IP forwarding (the exit node needs 1)"
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding

section "Dead-man switch (healthchecks.io)"
for key in HC_HEARTBEAT_URL HC_MAINT_URL; do
    if conf_has "$key"; then echo "$key is set"; else echo "$key is not set (pings skipped)"; fi
done
echo "Last heartbeat: $(cat "$HB_STATUS" 2>/dev/null || echo 'none since boot')"

section "Honeypot (OpenCanary)"
if [[ -f $CANARY_UNIT ]]; then
    echo "Service: $(systemctl is-active opencanary)"
    ss -Hltn "( $(printf 'sport = :%s or ' "${CANARY_PORTS[@]}") sport = :0 )"
    events=$(journalctl -u opencanary --since -24h -o cat 2>/dev/null         | grep -Ec '"logtype": ([2-9][0-9]{3}|[0-9]{5})')
    echo "Events in the last 24 h: $events (details: journalctl -u opencanary)"
else
    echo "Not installed (canary/install.sh)"
fi

section "Summary"
check "ufw is active"                       has_line "Status: active" "$ufw_status"
check "ufw denies incoming by default"      grep -q "Default: deny (incoming)" <<<"$ufw_status"
check "ufw safety timer is not pending"     bash -c "! systemctl is-active --quiet $ROLLBACK.timer"
check "fail2ban is running"                 systemctl is-active --quiet fail2ban
check "sshd jail is active"                 fail2ban-client status sshd
check "password login is off"               has_line "passwordauthentication no" "$sshd_T"
check "keyboard-interactive login is off"   has_line "kbdinteractiveauthentication no" "$sshd_T"
check "root login is off"                   has_line "permitrootlogin no" "$sshd_T"
check "key login is on"                     has_line "pubkeyauthentication yes" "$sshd_T"
check "IPv4 forwarding is on"               has_line "1" "$(sysctl -n net.ipv4.ip_forward)"
check "IPv6 forwarding is on"               has_line "1" "$(sysctl -n net.ipv6.conf.all.forwarding)"
check "heartbeat cron job is installed"     test -f /etc/cron.d/pi-heartbeat
if conf_has HC_HEARTBEAT_URL; then
    check "dig is installed (heartbeat DNS check)" command -v dig
    check "last heartbeat succeeded"        grep -q '^OK' "$HB_STATUS"
    check "last heartbeat: DNS resolved"    grep -Eq 'dns (NOERROR|NXDOMAIN) for ' "$HB_STATUS"
    check "last heartbeat is < 10 min old"  heartbeat_recent
else
    echo "SKIP  heartbeat checks (HC_HEARTBEAT_URL not set)"
fi
if conf_has HC_MAINT_URL; then
    echo "OK    maintenance check URL is set"
else
    echo "SKIP  maintenance pings (HC_MAINT_URL not set)"
fi

if [[ -f $CANARY_UNIT ]]; then
    check "honeypot is running"             systemctl is-active --quiet opencanary
    for p in "${CANARY_PORTS[@]}"; do
        check "honeypot listens on $p"      listening "$p"
        check "ufw: $p only from LAN/tailnet" ufw_scoped "$p"
    done
    check "ntfy credential is root-only"    test "$(stat -c '%U %a' "$CANARY_CRED" 2>/dev/null)" = "root 600"
else
    echo "SKIP  honeypot checks (OpenCanary not installed)"
fi

if ((failures)); then
    echo "$failures check(s) failed."
    exit 1
fi
echo "All checks passed."
