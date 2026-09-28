"""pi_canary_ntfy - send OpenCanary events to ntfy.

Installed by canary/install.sh to /usr/local/lib/opencanary-ntfy/ and loaded by
the "ntfy" handler in /etc/opencanaryd/opencanary.conf.

- The ntfy URL (server + topic) comes from the systemd credential "ntfy-url"
  (LoadCredential= in opencanary.service). It is never logged.
- Alerts carry the source IP, the fake service and the kind of event. They never
  carry usernames, passwords or other attacker input: ntfy.sh is a third party.
  The full event is in the journal (journalctl -u opencanary).
- The first event from a source IP on a service is sent at once. Repeats within
  WINDOW seconds are counted and sent as one summary when the window closes.
- Sending happens on a background thread with a timeout, so a slow or
  unreachable ntfy server never blocks the honeypot.

Standard library only.
"""

import json
import logging
import os
import queue
import sys
import threading
import time
import urllib.error
import urllib.request

# logtype -> (service, event). Numbers from opencanary/logger.py.
EVENTS = {
    2000: ("FTP", "login attempt"),
    2001: ("FTP", "login started"),
    3000: ("HTTP", "page request"),
    3001: ("HTTP", "login attempt"),
    3002: ("HTTP", "unusual request method"),
    3003: ("HTTP", "redirect"),
    4000: ("SSH", "connection"),
    4001: ("SSH", "client version sent"),
    4002: ("SSH", "login attempt"),
    6001: ("Telnet", "login attempt"),
    6002: ("Telnet", "connection"),
    8001: ("MySQL", "login attempt"),
    9003: ("MySQL", "connection"),
}

# Below this, logtypes are OpenCanary's own boot/debug/error messages.
FIRST_ATTACK_LOGTYPE = 2000


def _err(msg):
    print("pi_canary_ntfy: " + msg, file=sys.stderr, flush=True)


def _read_url():
    creds = os.environ.get("CREDENTIALS_DIRECTORY")
    if not creds:
        return None
    try:
        with open(os.path.join(creds, "ntfy-url")) as f:
            url = f.read().strip()
    except OSError:
        return None
    return url if url.startswith(("https://", "http://")) else None


class _Window:
    __slots__ = ("start", "port", "count", "events")

    def __init__(self, start, port):
        self.start = start
        self.port = port
        self.count = 0          # repeats after the first, already-sent event
        self.events = set()


class NtfyHandler(logging.Handler):
    def __init__(self, window=60, queue_size=500, timeout=10):
        logging.Handler.__init__(self)
        self.window = float(window)
        self.timeout = timeout
        self.url = _read_url()
        if self.url is None:
            _err("no ntfy-url credential; events are logged but no alerts are sent")
        self.queue = queue.Queue(maxsize=queue_size)
        self.windows = {}       # (src_host, service) -> _Window
        self.dropped = 0
        threading.Thread(target=self._run, name="ntfy", daemon=True).start()

    # Runs on OpenCanary's thread: parse, filter and hand off. Never blocks.
    def emit(self, record):
        if self.url is None:
            return
        try:
            data = json.loads(record.getMessage())
            logtype = int(data.get("logtype", 0))
        except (ValueError, TypeError):
            return
        if logtype < FIRST_ATTACK_LOGTYPE:
            return
        port = data.get("dst_port", -1)
        service, event = EVENTS.get(logtype, ("port %s" % port, "event %d" % logtype))
        src = str(data.get("src_host") or "unknown")
        try:
            self.queue.put_nowait((time.monotonic(), src, service, port, event))
        except queue.Full:
            self.dropped += 1

    def _run(self):
        while True:
            try:
                item = self.queue.get(timeout=1)
            except queue.Empty:
                item = None
            now = time.monotonic()
            self._flush(now)
            if item is not None:
                self._handle(*item)
            if self.dropped:
                _err("queue full; dropped %d event(s) without alerting" % self.dropped)
                self.dropped = 0

    def _handle(self, t, src, service, port, event):
        key = (src, service)
        w = self.windows.get(key)
        if w is not None and t - w.start < self.window:
            w.count += 1
            w.events.add(event)
            return
        if w is not None:
            self._summary(key, w)
        self.windows[key] = _Window(t, port)
        self._send(
            "Honeypot: %s (%s) touched" % (service, port),
            "From: %s\nService: %s on port %s\nEvent: %s" % (src, service, port, event),
            "high",
        )

    def _flush(self, now):
        for key, w in list(self.windows.items()):
            if now - w.start >= self.window:
                self._summary(key, w)
                del self.windows[key]

    def _summary(self, key, w):
        if not w.count:
            return
        src, service = key
        self._send(
            "Honeypot: %s (%s) touched again" % (service, w.port),
            "From: %s\n%d more event(s) in %d s after the first alert\nEvents: %s"
            % (src, w.count, self.window, ", ".join(sorted(w.events))),
            "default",
        )

    def _send(self, title, body, priority):
        req = urllib.request.Request(
            self.url,
            data=body.encode("utf-8"),
            headers={"Title": title, "Priority": priority, "Tags": "rotating_light"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                resp.read()
        except urllib.error.HTTPError as e:
            # e.g. 429 when ntfy.sh rate-limits. Never print the URL: it holds the topic.
            _err("ntfy alert failed: HTTP %d" % e.code)
        except (urllib.error.URLError, OSError) as e:
            _err("ntfy alert failed: %s" % type(e).__name__)
