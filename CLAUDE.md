# pi-maintenance

Unattended monthly maintenance for a Raspberry Pi running **Pi-hole v6 + Unbound**
(Debian trixie), reached over **Tailscale**. See README.md for what the job does.

## The Pi

- SSH alias: `pihole` (key-based login as a non-root user; defined in `~/.ssh/config`).
  Real host details are in `CLAUDE.local.md`, which is gitignored.
- DNS stack: `pihole-FTL` (Pi-hole) forwarding to `unbound` (recursive resolver).
- Installed files:
  - `/usr/local/bin/pi-maintenance.sh`: the script (source: `bin/pi-maintenance.sh`)
  - `/etc/cron.d/pi-maintenance`: schedule, 04:00 on the 1st (source: `etc/cron.d/`)
  - `/usr/local/bin/pi-heartbeat.sh` + `/etc/cron.d/pi-heartbeat`: healthchecks.io
    heartbeat every 5 min (source: `bin/`, `etc/cron.d/`)
  - `/etc/logrotate.d/pi-maintenance`: log rotation (source: `etc/logrotate.d/`)
  - `/etc/pi-maintenance.conf`: local config incl. ntfy topic and healthchecks.io ping
    URLs. Root-only, **never read it out or commit it**
  - `/var/log/pi-maintenance.log`: run log
- `sudo` on the Pi needs a password, so Claude cannot run root commands. Give the user
  the exact command to run instead.

## Rules

1. **Explain every change before making it**: what, why, and how to undo it. Wait for
   an OK before touching the Pi or its config.
2. **Take a Teleporter backup before any config change on the Pi**
   (`cd ~/backups && sudo pihole-FTL --teleporter`) and confirm the new zip exists.
3. Run Pi commands with the Bash tool as `ssh pihole ...`, never the raw IP and never via
   PowerShell, so the permission rules in `.claude/settings.json` apply.
4. Keep published files free of the Pi's IP, usernames, device names, the ntfy topic,
   backups and logs. Use placeholders like `<pi-tailscale-ip>` and `<user>`.

## Working on the repo

- Syntax-check with `bash -n bin/pi-maintenance.sh install.sh` (and `shellcheck` if available).
- Deploy = user copies the repo to the Pi and runs `sudo ./install.sh`.
