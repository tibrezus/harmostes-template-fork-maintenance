#!/usr/bin/env python3
"""conflict-subscriber.py — Dapr pub/sub consumer for fork-sync conflicts.

Always-on Deployment that exposes an HTTP ``/events`` endpoint and spawns
``resolve-conflict.sh <fork>`` for each ``fork.conflict.needs-resolution``
event it receives. The publisher is sync-fork.sh's emit_conflict_event, which
POSTs directly to this endpoint with retries (no Dapr pub/sub in the path —
see below). For each event it ACKs immediately (200 SUCCESS) and spawns the
resolver detached in the background — resolution is long-running (minutes:
pi + re-validation) and must not block the HTTP response.

Delivery history: this previously consumed via Dapr pub/sub (pubsub.redis),
but Redis pub/sub is fire-and-forget — it does NOT retain undelivered events,
so a subscriber restart silently lost any event published meanwhile. Worse,
the sync Job's daprd sidecar never terminated, so the Job hung and the
"re-emit every 30m" self-heal never ran. Direct HTTP POST (publisher retries)
fixes both. fork-sync still re-emits on every run for any conflict that
persists, so the path self-heals on top of per-request retries. A per-fork
in-flight guard prevents two concurrent resolutions of the same fork.

Mirrors the llm-wiki event-subscriber pattern. Standard library only.
"""
import http.server
import json
import os
import socket
import subprocess
import threading
from datetime import datetime, timezone

LISTEN_PORT = int(os.environ.get("PORT", "8080"))
NAMESPACE = os.environ.get("NAMESPACE", "fork-maintenance")
PUBSUB_NAME = os.environ.get("DAPR_PUBSUB", "pubsub")
TOPIC = "fork.conflict.needs-resolution"
RESOLVER = os.environ.get("RESOLVER_SCRIPT", "/workspace/scripts/resolve-conflict.sh")
LOG_DIR = os.environ.get("RESOLVER_LOG_DIR", "/tmp/resolver")

SUBSCRIPTIONS = [{"pubsubname": PUBSUB_NAME, "topic": TOPIC, "route": "/events"}]

# Per-fork in-flight guard: only one resolution per fork at a time.
_inflight = set()
_inflight_lock = threading.Lock()


def log(msg: str) -> None:
    print(f"[conflict-subscriber] {datetime.now(timezone.utc).isoformat()} {msg}", flush=True)


def spawn_resolution(fork: str, payload: dict) -> None:
    """Spawn resolve-conflict.sh detached, logging to a per-run file."""
    os.makedirs(LOG_DIR, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    log_path = os.path.join(LOG_DIR, f"{fork}-{ts}.log")
    try:
        with open(log_path, "wb") as lf:
            # start_new_session=True detaches the child from this handler so it
            # keeps running after the HTTP response is sent. Env (LITELLM_URL,
            # GITHUB_TOKEN, MAINT_DIR, SKILL_PATH, ...) is inherited from the pod.
            proc = subprocess.Popen(
                ["bash", RESOLVER, fork],
                stdout=lf, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
                cwd="/workspace",
                # Row context rides to the resolver (#637): mapping-mode events
                # carry row {theirs, ours} + the stable conflict branch; legacy
                # single-row events carry empty strings (def fallback).
                env=dict(os.environ, EVENT_PAYLOAD=json.dumps(payload)),
            )
        with _inflight_lock:
            _inflight.add(fork)   # mark in-flight ONLY after a successful spawn
        log(f"spawned resolve-conflict.sh {fork} (pid {proc.pid}) → {log_path}")
        # Clear the in-flight guard when the resolution process exits (success or
        # fail). Without this, a failed resolution permanently blocks the fork —
        # the next sync's event is ACKed + dropped as "already resolving" until a
        # pod restart. The resolution is detached (start_new_session), so a daemon
        # thread waits on it and discards the fork from _inflight on exit.
        def _reap(p=proc, f=fork):
            p.wait()
            with _inflight_lock:
                _inflight.discard(f)
            log(f"{f} resolution finished (rc={p.returncode}) — cleared in-flight")
        threading.Thread(target=_reap, daemon=True).start()
    except Exception as e:  # noqa: BLE001
        log(f"ERROR: could not spawn resolver for {fork}: {e}")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/dapr/subscribe":
            self._send(200, SUBSCRIPTIONS)
        elif self.path == "/healthz":
            self._send(200, {"status": "ok", "inflight": sorted(_inflight)})
        else:
            self._send(404, {"error": "not found"})

    def do_HEAD(self):
        self._send(200 if self.path == "/healthz" else 404, {})

    def do_POST(self):
        if self.path != "/events":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            envelope = json.loads(raw.decode() or "{}")
        except Exception:  # noqa: BLE001
            envelope = {}
        data = envelope.get("data", envelope) if isinstance(envelope, dict) else {}
        fork = data.get("fork", "unknown")
        log(f"event received: fork={fork} conflict_files={data.get('conflict_files')}")

        # In-flight guard: skip only if a resolution is ACTUALLY running. The
        # marker is added inside spawn_resolution AFTER a successful spawn (not
        # here), so a failed spawn never strands the fork. Direct HTTP delivery
        # (one event per sync per fork; CronJob is Forbid) removed the Dapr
        # redelivery this guard once deduped.
        with _inflight_lock:
            if fork in _inflight:
                log(f"  {fork} already resolving — skipping")
                self._send(200, {"status": "SUCCESS"})
                return
        spawn_resolution(fork, data)
        self._send(200, {"status": "SUCCESS"})

    def log_message(self, fmt, *args):  # noqa: A003
        pass


class DualStackServer(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        super().server_bind()


def ensure_yq():
    """Download yq if missing (the resolver image has git/jq/go/pi but not yq).
    resolve-conflict.sh + sync-fork.sh parse fork defs with yq."""
    import shutil
    import urllib.request
    if shutil.which("yq"):
        return
    dest = "/usr/local/bin/yq"
    url = "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
    try:
        urllib.request.urlretrieve(url, dest)
        os.chmod(dest, 0o755)
        log("installed yq → /usr/local/bin/yq")
    except Exception as e:  # noqa: BLE001
        log(f"WARN: could not install yq ({e}); resolve-conflict.sh will fail on fork defs")


def ensure_gh():
    """Download the GitHub CLI if missing so the agent has `gh`, authenticated via
    GH_TOKEN (= FORK_MAINTENANCE_GITHUB_TOKEN from BWS). gh reads GH_TOKEN
    automatically — no `gh auth login` needed."""
    import shutil
    import tarfile
    import urllib.request
    if shutil.which("gh"):
        return
    import json as _json
    try:
        with urllib.request.urlopen(
            "https://api.github.com/repos/cli/cli/releases/latest", timeout=15
        ) as r:
            ver = _json.load(r)["tag_name"].lstrip("v")
        url = f"https://github.com/cli/cli/releases/download/v{ver}/gh_{ver}_linux_amd64.tar.gz"
        tgz = "/tmp/gh.tar.gz"
        urllib.request.urlretrieve(url, tgz)
        with tarfile.open(tgz) as t:
            t.extract(f"gh_{ver}_linux_amd64/bin/gh", "/tmp")
        src = f"/tmp/gh_{ver}_linux_amd64/bin/gh"
        os.chmod(src, 0o755)
        os.replace(src, "/usr/local/bin/gh")
        log(f"installed gh v{ver} → /usr/local/bin/gh")
    except Exception as e:  # noqa: BLE001
        log(f"WARN: could not install gh ({e}); PR operations will be unavailable")


def ensure_harmostes():
    """Download harmostes (the shared pi RPC orchestrator, github.com/tibrezus/harmostes)
    if missing, so resolve-conflict.sh can call it. resolve-conflict.sh reads the
    HARMOSTES env (default 'harmostes'); the resolver Deployment sets it to this path."""
    import shutil
    import urllib.request
    dest = "/usr/local/bin/harmostes.py"
    if os.path.exists(dest):
        return
    url = "https://raw.githubusercontent.com/tibrezus/harmostes/main/harmostes.py"
    try:
        urllib.request.urlretrieve(url, dest)
        os.chmod(dest, 0o755)
        log("installed harmostes → /usr/local/bin/harmostes.py")
    except Exception as e:  # noqa: BLE001
        log(f"WARN: could not install harmostes ({e}); resolve-conflict.sh will fail")


def main():
    ensure_yq()
    ensure_gh()
    ensure_harmostes()
    log(f"starting on [::]:{LISTEN_PORT} (dual-stack, ns={NAMESPACE})")
    log(f"subscribed to pubsub={PUBSUB_NAME} topic={TOPIC} → spawns {RESOLVER}")
    httpd = DualStackServer(("::", LISTEN_PORT), Handler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
