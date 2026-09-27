#!/usr/bin/env bash
# verify.sh - show the Pi's hardening state. Read-only; changes nothing.
# Run from a checkout of this repo on the Pi:  sudo hardening/verify.sh
#
# Prints ufw status, the fail2ban sshd jail and the effective sshd settings,
# then a summary of OK/FAIL checks. Exits 1 if any check failed.

set -uo pipefail   # no -e: keep going and report everything

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./verify.sh" >&2; exit 1; }

ROLLBACK=pi-hardening-ufw-rollback
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

if ((failures)); then
    echo "$failures check(s) failed."
    exit 1
fi
echo "All checks passed."
