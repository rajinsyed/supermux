#!/usr/bin/env python3
"""End-to-end test: another Mac's ports are forwarded to this Mac.

A server started in a workspace on the owning Mac opens at `localhost` on the
viewing Mac (for browsers, the iOS Simulator and every other app), at the same
port when it is free here and otherwise at the next free one; a port in use
here is never taken. The mirror's sidebar row shows the owner's port chips, a
pill says where a moved port landed, and a terminal link opened in the default
browser goes to the forward's local port.

Runs against one tagged DEBUG build with the loopback device ("Loopback Mac" =
this same app's own mobile host), so every remote port is also busy here: each
forward must land on another local port.

  0. setup                              auto-mirror and auto-forward on; source S and its mirror M
  1. auto_forward_busy_port_lands_elsewhere   a server on R in S -> forward R active at L != R;
                                        127.0.0.1:L and [::1]:L serve the owner's page
  2. dual_stack_busy_not_stolen         the suite's own [::]:R2 listener + an injected host port R2
                                        -> the forward lands elsewhere; 127.0.0.1:R2 still reaches
                                        the suite's listener
  3. pill_names_local_port              M carries the pill `supermux.ports.R` naming L
  4. mirror_chip_lists_remote_port      M's sidebar port chips list R
  5. manual_forward_and_stop            Forward a Port Q (in no workspace) -> active, serves the
                                        suite's page; Stop -> its local port refuses within 2 s
  6. paused_auto_stays_paused           Stop R -> stopped and refused, still stopped after a port
                                        rescan; Resume -> active again
  7. port_disappears_forward_stops      the server on R exits -> the forward goes and L refuses;
                                        restarted -> forwarded again
  8. disconnect_stops_listeners         link down -> waiting, L refuses, M's chips empty;
                                        link back -> active on the same L
  9. auto_off_keeps_manual              auto-forward off -> automatic forwards go, a manual one stays
 10. external_link_uses_local_port      a localhost:R link in M's terminal opened in the default
                                        browser -> http://localhost:L/... (C's `mirror.link_open`)
 11. old_host_disables                  a host without `supermux.port_forward.v1` -> `needs_update`,
                                        nothing forwarded; then back
 12. capability_failure_retried         every capability request after a relink fails (`timed_out`,
                                        tunnel.fail_requests); once the host answers again R is
                                        forwarded with no port change and no relink
 13. listing_failure_retried            every ports.list after a relink fails until the reconnect's own
                                        pokes are over; once the host answers again R is forwarded with
                                        no port change, poke or relink
 14. chip_default_browser_uses_local_port  M's sidebar chip for R clicked with "Open Sidebar Port Links
                                        in cmux Browser" off -> the default browser gets
                                        http://localhost:L, never this Mac's own localhost:R
                                        (`ports.chip_open`)
 15. pending_forward_offers_stop        a manual forward Q left waiting by a dropped link -> both
                                        port menus (M's "Ports on <Mac>", Settings' Ports…) offer
                                        Stop Forwarding (`ports.menus`); Stop -> it goes at once,
                                        and with the link back it never listens again

Writes a JSON report (default tests/supermux/artifacts/loopback_port_forward_e2e-<tag>.json)
and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_port_forward_e2e.py [--latency 8] [--timeout 30] [--report PATH]
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

LOOPBACK_DEVICE_ID = "5e1f10b0-0000-4000-8000-000000000001"
HOST_STATUS = "mobile.host.status"
PORTS_LIST = "mobile.supermux.ports.list"
# Armed failures that outlast the step (it disarms them itself).
UNTIL_DISARMED = 1000
# How long after the first failed listing the reconnect's own `ports.updated` pokes are over.
POKES_SETTLE_SECONDS = 5.0
REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = REPO_ROOT / "tests" / "supermux" / "artifacts"


class Failure(Exception):
    """A check failed; the message says which and why."""


class RateLimited(Exception):
    """The socket's polling limiter refused a read; retry after the hint."""

    def __init__(self, retry_after_s: float) -> None:
        super().__init__(f"rate limited for {retry_after_s}s")
        self.retry_after_s = max(0.05, retry_after_s)


class Socket:
    """Newline-delimited JSON client for the cmux v2 control socket."""

    def __init__(self, path: str, timeout_s: float = 30.0) -> None:
        self.path = path
        self.timeout_s = timeout_s
        self._sock: Optional[socket.socket] = None
        self._buffer = b""
        self._next_id = 1

    def connect(self) -> "Socket":
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout_s)
        sock.connect(self.path)
        self._sock = sock
        return self

    def close(self) -> None:
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    def call(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Any:
        """One request; waits out the socket's per-connection polling limit."""
        for _ in range(20):
            try:
                return self._call_once(method, params, timeout_s)
            except RateLimited as limited:
                time.sleep(limited.retry_after_s)
        return self._call_once(method, params, timeout_s)

    def _call_once(self, method: str, params: Optional[Dict[str, Any]], timeout_s: Optional[float]) -> Any:
        assert self._sock is not None, "not connected"
        request_id = self._next_id
        self._next_id += 1
        line = json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n"
        self._sock.sendall(line.encode("utf-8"))
        response = json.loads(self._read_line(timeout_s or self.timeout_s))
        if response.get("id") != request_id:
            raise Failure(f"{method}: mismatched response id")
        if response.get("ok") is True:
            return response.get("result")
        error = response.get("error") or {}
        if error.get("code") == "rate_limited":
            raise RateLimited(((error.get("data") or {}).get("retry_after_ms") or 100) / 1000.0)
        raise Failure(f"{method}: {error.get('code', 'error')}: {error.get('message', 'unknown error')}")

    def _read_line(self, timeout_s: float) -> str:
        assert self._sock is not None
        deadline = time.monotonic() + timeout_s
        while b"\n" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Failure("socket response timed out")
            self._sock.settimeout(remaining)
            chunk = self._sock.recv(65536)
            if not chunk:
                raise Failure("socket closed by the app")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        return line.decode("utf-8", errors="replace")


def socket_path_for_tag(tag: str) -> str:
    slug = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", tag.strip().lower())).strip("-")
    return f"/tmp/cmux-debug-{slug}.sock"


def up(identifier: Any) -> str:
    return str(identifier or "").strip().upper()


def wait_for(description: str, probe: Callable[[], Any], timeout_s: float, interval_s: float = 0.3) -> Any:
    deadline = time.monotonic() + timeout_s
    last: Optional[str] = None
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value:
                return value
        except Failure as error:
            last = str(error)
        time.sleep(interval_s)
    raise Failure(f"timed out after {timeout_s:.0f}s waiting for {description}" + (f" (last: {last})" if last else ""))


# -- local network helpers ----------------------------------------------------

def free_port() -> int:
    """A port no IPv4 or IPv6 loopback listener holds right now."""
    for _ in range(50):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        if not accepts("127.0.0.1", port) and not accepts("::1", port):
            return port
    raise Failure("no free local port")


def accepts(host: str, port: int, timeout_s: float = 0.5) -> bool:
    """Whether a TCP connect to host:port succeeds."""
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    with socket.socket(family, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout_s)
        try:
            sock.connect((host, port))
            return True
        except OSError:
            return False


def http_get(host: str, port: int, path: str, timeout_s: float = 5.0) -> str:
    """The body of `GET http://host:port/path`, or a Failure."""
    netloc = f"[{host}]" if ":" in host else host
    try:
        with urllib.request.urlopen(f"http://{netloc}:{port}{path}", timeout=timeout_s) as response:
            return response.read().decode("utf-8", errors="replace").strip()
    except Exception as error:  # noqa: BLE001 - every failure is a check failure
        raise Failure(f"GET http://{netloc}:{port}{path}: {error}") from error


def listener_pids(port: int) -> List[int]:
    """Pids listening on TCP `port` (lsof)."""
    out = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
                         capture_output=True, text=True, check=False).stdout
    return [int(pid) for pid in out.split() if pid.strip().isdigit()]


class MarkerServer:
    """An HTTP server of the suite's own (in no cmux workspace) serving one marker."""

    def __init__(self, body: str, host: str = "127.0.0.1", family: int = socket.AF_INET, dual_stack: bool = False) -> None:
        payload = body.encode("utf-8")

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - stdlib name
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args: Any) -> None:
                pass

        class Server(http.server.ThreadingHTTPServer):
            address_family = family

            def server_bind(self) -> None:
                if dual_stack:
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                super().server_bind()

        self.server = Server((host, 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


class PortForwardE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.timeout = args.timeout
        self.latency_limit = args.latency
        self.keep = args.keep
        self.nonce = uuid.uuid4().hex[:8]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "latency_limit_seconds": self.latency_limit}
        self.machine = ""
        self.source_id = ""
        self.mirror_id = ""
        self.source_terminal = ""
        self.www = Path(tempfile.mkdtemp(prefix="supermux-port-forward-"))
        (self.www / "marker.html").write_text(f"owner-{self.nonce}\n", encoding="utf-8")
        self.remote_port = 0
        self.local_port = 0
        self.servers: List[MarkerServer] = []
        self.manual_port = 0

    # -- reads ----------------------------------------------------------------

    def device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device in supermux.devices.list (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def ports(self) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.ports.list", {"machine": self.machine}) or {}

    def availability(self) -> Optional[str]:
        return (self.ports().get("availability") or {}).get(self.machine)

    def forward(self, port: int) -> Optional[Dict[str, Any]]:
        for row in self.ports().get("forwards") or []:
            if row.get("machine") == self.machine and row.get("remote_port") == port:
                return row
        return None

    def active_forward(self, port: int) -> Optional[Dict[str, Any]]:
        row = self.forward(port)
        if row and row.get("state") == "active" and row.get("local_port"):
            return row
        raise Failure(f"forward of {port}: {row}")

    def mirror_row(self) -> Dict[str, Any]:
        for row in self.ports().get("mirrors") or []:
            if up(row.get("workspace_id")) == up(self.mirror_id):
                return row
        raise Failure(f"no mirror row for {self.mirror_id} in supermux.devices.ports.list")

    def mirrors_of_source(self) -> List[Dict[str, Any]]:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        return [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(self.source_id)]

    def terminals(self, workspace_id: str) -> List[str]:
        surfaces = (self.sock.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        return [up(s.get("id")) for s in surfaces if s.get("type") == "terminal"]

    # -- actions --------------------------------------------------------------

    def ports_call(self, action: str, **params: Any) -> Dict[str, Any]:
        return self.sock.call(f"supermux.devices.ports.{action}", {"machine": self.machine, **params}) or {}

    def tunnel(self, action: str, **params: Any) -> Any:
        return self.sock.call(f"supermux.devices.tunnel.{action}", params)

    def kick(self) -> None:
        self.sock.call("surface.ports_kick", {"workspace_id": self.source_id, "surface_id": self.source_terminal})

    def start_owner_server(self, port: int) -> None:
        """Runs `python3 -m http.server` in S's terminal (the owner's process tree)."""
        command = f"python3 -m http.server {port} --bind 127.0.0.1 --directory {shlex.quote(str(self.www))}\n"
        self.sock.call("surface.send_text", {"workspace_id": self.source_id, "surface_id": self.source_terminal, "text": command})
        wait_for(f"the owner's server on {port}", lambda: accepts("127.0.0.1", port), self.timeout)

    def stop_owner_server(self, port: int) -> None:
        for pid in listener_pids(port):
            try:
                os.kill(pid, 15)
            except OSError:
                pass
        wait_for(f"the owner's server on {port} to exit", lambda: not accepts("127.0.0.1", port), self.timeout)

    def link(self, action: str) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.link", {"machine": self.machine, "action": action}) or {}

    def relink(self) -> None:
        """Drops the link, waits for the drop, and redials it."""
        self.link("stop")
        wait_for("the link to drop", lambda: self.device().get("link_state") != "connected", self.timeout)
        self.link("restore")
        self.wait_linked()

    def fail_requests(self, method: str, count: Optional[int] = None) -> Dict[str, Any]:
        """The loopback host answers the next `count` `method` requests `timed_out` (0 disarms);
        without `count`, how many it failed so far."""
        params: Dict[str, Any] = {"method": method}
        if count is not None:
            params["count"] = count
        return self.tunnel("fail_requests", **params) or {}

    def wait_linked(self) -> None:
        def ready() -> bool:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return True

        wait_for("the loopback device to connect", ready, self.timeout)

    def require_forwarded(self) -> None:
        """Steps after the first need R forwarded; say so instead of probing port 0."""
        if not self.remote_port or not self.local_port:
            raise Failure("precondition: the owner's port was never forwarded (auto_forward_busy_port_lands_elsewhere failed)")

    def wait_refused(self, port: int, seconds: float, description: str) -> None:
        wait_for(description, lambda: not accepts("127.0.0.1", port) and not accepts("::1", port), seconds, interval_s=0.1)

    # -- steps ----------------------------------------------------------------

    def step(self, name: str, action: Callable[[], Optional[Dict[str, Any]]]) -> bool:
        started = time.monotonic()
        record: Dict[str, Any] = {"name": name}
        try:
            record.update(action() or {})
            record["ok"] = True
        except Failure as error:
            record["ok"] = False
            record["error"] = str(error)
        record["seconds"] = round(time.monotonic() - started, 2)
        self.steps.append(record)
        print(f"{'PASS' if record['ok'] else 'FAIL'} {name} ({record['seconds']}s)"
              + ("" if record["ok"] else ": " + record["error"]), file=sys.stderr)
        return record["ok"]

    def setup(self) -> Dict[str, Any]:
        self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True})
        self.machine = wait_for("the loopback device", lambda: self.device().get("machine"), self.timeout)
        self.wait_linked()
        self.ports_call("set_auto", enabled=True)
        title = f"port-forward-{self.nonce}"
        created = self.sock.call("workspace.create", {"title": title, "focus": False}) or {}
        self.source_id = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not self.source_id:
            raise Failure(f"workspace.create returned no id: {created}")
        self.sock.call("workspace.rename", {"workspace_id": self.source_id, "title": title})
        self.source_terminal = wait_for("S's terminal", lambda: (self.terminals(self.source_id) or [None])[0], self.timeout)
        mirror = wait_for("the auto-mirror of S", lambda: (self.mirrors_of_source() or [None])[0], self.timeout)
        self.mirror_id = up(mirror["workspace_id"])
        time.sleep(1.5)  # let S's shell reach its prompt before typing into it
        self.facts.update(machine=self.machine, source_workspace_id=self.source_id, mirror_workspace_id=self.mirror_id)
        return {"machine": self.machine, "source": self.source_id, "mirror": self.mirror_id}

    def auto_forward_busy_port(self) -> Dict[str, Any]:
        self.remote_port = free_port()
        self.start_owner_server(self.remote_port)
        started = time.monotonic()
        self.kick()
        row = wait_for(f"an automatic forward of {self.remote_port}", lambda: self.active_forward(self.remote_port),
                       self.latency_limit, interval_s=0.2)
        latency = round(time.monotonic() - started, 2)
        self.local_port = int(row["local_port"])
        if row.get("origin") != "automatic":
            raise Failure(f"origin {row.get('origin')}, expected automatic: {row}")
        if self.local_port == self.remote_port:
            raise Failure(f"the forward took {self.remote_port}, which the owner's own server holds here")
        expected = f"owner-{self.nonce}"
        v4 = http_get("127.0.0.1", self.local_port, "/marker.html")
        v6 = http_get("::1", self.local_port, "/marker.html")
        if v4 != expected or v6 != expected:
            raise Failure(f"127.0.0.1:{self.local_port} -> {v4!r}, [::1]:{self.local_port} -> {v6!r}; expected {expected!r}")
        try:
            self.facts["host_journal_tail"] = (self.tunnel("journal") or {})
        except Failure as error:
            self.facts["host_journal_error"] = str(error)
        self.facts.update(remote_port=self.remote_port, local_port=self.local_port)
        return {"remote_port": self.remote_port, "local_port": self.local_port, "latency_seconds": latency}

    def dual_stack_busy(self) -> Dict[str, Any]:
        marker = f"dual-{self.nonce}"
        server = MarkerServer(marker, host="::", family=socket.AF_INET6, dual_stack=True)
        self.servers.append(server)
        port = server.port
        self.tunnel("inject_port", workspace_id=self.source_id, port=port)
        try:
            self.ports_call("refresh")
            row = wait_for(f"an automatic forward of the injected {port}", lambda: self.active_forward(port), self.timeout)
            if int(row["local_port"]) == port:
                raise Failure(f"the forward took {port} from the suite's dual-stack [::]:{port} listener")
            own = http_get("127.0.0.1", port, "/")
            if own != marker:
                raise Failure(f"127.0.0.1:{port} answered {own!r}, not the suite's own listener ({marker!r})")
            return {"port": port, "local_port": row["local_port"]}
        finally:
            self.tunnel("clear_injected")
            self.ports_call("refresh")

    def pill(self) -> Dict[str, Any]:
        self.require_forwarded()
        key = f"supermux.ports.{self.remote_port}"

        def named() -> str:
            value = (self.mirror_row().get("port_pills") or {}).get(key)
            if not value or f"localhost:{self.local_port}" not in value:
                raise Failure(f"pill {key} = {value!r}")
            return value

        return {"pill": wait_for(f"M's pill {key}", named, self.timeout)}

    def chips(self) -> Dict[str, Any]:
        if not self.remote_port:
            raise Failure("precondition: the owner's server never started")
        def listed() -> List[int]:
            ports = self.mirror_row().get("listening_ports") or []
            if self.remote_port not in ports:
                raise Failure(f"M's chips {ports}")
            return ports

        return {"listening_ports": wait_for(f"M's chip for {self.remote_port}", listed, self.timeout)}

    def manual_forward_and_stop(self) -> Dict[str, Any]:
        marker = f"manual-{self.nonce}"
        server = MarkerServer(marker)
        self.servers.append(server)
        port = server.port
        self.ports_call("forward", port=port)
        row = wait_for(f"a manual forward of {port}", lambda: self.active_forward(port), self.timeout)
        local = int(row["local_port"])
        if row.get("origin") != "manual":
            raise Failure(f"origin {row.get('origin')}, expected manual: {row}")
        body = http_get("127.0.0.1", local, "/")
        if body != marker:
            raise Failure(f"127.0.0.1:{local} -> {body!r}, expected {marker!r}")
        self.ports_call("stop", port=port)
        self.wait_refused(local, 2.0, f"127.0.0.1:{local} to refuse after Stop Forwarding")
        after = self.forward(port)
        if after and after.get("state") == "active":
            raise Failure(f"still active after stop: {after}")
        self.manual_port = port
        return {"port": port, "local_port": local}

    def paused_auto(self) -> Dict[str, Any]:
        self.require_forwarded()
        port, local = self.remote_port, self.local_port
        self.ports_call("stop", port=port)
        wait_for(f"forward of {port} to be stopped", lambda: (self.forward(port) or {}).get("state") == "stopped", 5.0)
        self.wait_refused(local, 2.0, f"127.0.0.1:{local} to refuse after Stop Forwarding")
        self.kick()
        time.sleep(3)
        state = (self.forward(port) or {}).get("state")
        if state != "stopped":
            raise Failure(f"a port rescan restarted the stopped forward: state {state}")
        self.ports_call("resume", port=port)
        row = wait_for(f"forward of {port} to resume", lambda: self.active_forward(port), self.timeout)
        self.local_port = int(row["local_port"])
        if http_get("127.0.0.1", self.local_port, "/marker.html") != f"owner-{self.nonce}":
            raise Failure("the resumed forward does not serve the owner's page")
        return {"local_port": self.local_port}

    def port_disappears(self) -> Dict[str, Any]:
        self.require_forwarded()
        port, local = self.remote_port, self.local_port
        self.stop_owner_server(port)
        self.kick()
        wait_for(f"the forward of {port} to go", lambda: self.forward(port) is None, self.timeout)
        self.wait_refused(local, 2.0, f"127.0.0.1:{local} to refuse once the owner's server is gone")
        self.start_owner_server(port)
        self.kick()
        row = wait_for(f"the restarted {port} to be forwarded", lambda: self.active_forward(port), self.timeout)
        self.local_port = int(row["local_port"])
        return {"local_port_before": local, "local_port_after": self.local_port}

    def disconnect(self) -> Dict[str, Any]:
        self.require_forwarded()
        port, local = self.remote_port, self.local_port
        if not self.manual_port:
            self.servers.append(MarkerServer(f"manual-{self.nonce}"))
            self.manual_port = self.servers[-1].port
        self.ports_call("forward", port=self.manual_port)  # for step 9: a manual forward across the drop
        wait_for(f"the manual forward of {self.manual_port}", lambda: self.active_forward(self.manual_port), self.timeout)
        self.link("stop")
        try:
            wait_for(f"forward of {port} to wait", lambda: (self.forward(port) or {}).get("state") == "waiting", self.timeout)
            self.wait_refused(local, 2.0, f"127.0.0.1:{local} to refuse while the link is down")
            wait_for("M's chips to empty", lambda: self.remote_port not in (self.mirror_row().get("listening_ports") or []), self.timeout)
        finally:
            self.link("restore")
        self.wait_linked()
        row = wait_for(f"forward of {port} to come back", lambda: self.active_forward(port), self.timeout)
        if int(row["local_port"]) != local:
            raise Failure(f"came back on {row['local_port']}, not the same free {local}")
        return {"local_port": local}

    def auto_off(self) -> Dict[str, Any]:
        self.require_forwarded()
        self.ports_call("set_auto", enabled=False)
        try:
            def only_manual() -> bool:
                rows = [r for r in self.ports().get("forwards") or [] if r.get("machine") == self.machine]
                automatic = [r for r in rows if r.get("origin") == "automatic"]
                if automatic:
                    raise Failure(f"automatic forwards remain: {automatic}")
                return any(r.get("remote_port") == self.manual_port and r.get("state") == "active" for r in rows)

            wait_for("only the manual forward to remain", only_manual, self.timeout)
            self.wait_refused(self.local_port, 2.0, f"127.0.0.1:{self.local_port} to refuse with auto-forward off")
        finally:
            self.ports_call("set_auto", enabled=True)
        row = wait_for(f"forward of {self.remote_port} back on", lambda: self.active_forward(self.remote_port), self.timeout)
        self.local_port = int(row["local_port"])
        self.ports_call("stop", port=self.manual_port)
        return {"local_port": self.local_port}

    def external_link(self) -> Dict[str, Any]:
        self.require_forwarded()
        terminal = wait_for("M's terminal", lambda: (self.terminals(self.mirror_id) or [None])[0], self.timeout)
        url = f"http://localhost:{self.remote_port}/marker.html"
        opened = self.sock.call("supermux.devices.mirror.link_open", {
            "workspace_id": self.mirror_id, "surface_id": terminal, "url": url, "destination": "system",
        }) or {}
        expected = f"http://localhost:{self.local_port}/marker.html"
        if opened.get("external_url") != expected:
            raise Failure(f"external_url {opened.get('external_url')!r}, expected {expected!r}")
        return {"external_url": opened.get("external_url")}

    def old_host(self) -> Dict[str, Any]:
        self.require_forwarded()
        self.tunnel("pretend_old_host", enabled=True)
        try:
            self.link("stop")
            self.link("restore")
            self.wait_linked()

            def disabled() -> bool:
                listing = self.ports()
                reason = (listing.get("availability") or {}).get(self.machine)
                if reason != "needs_update":
                    raise Failure(f"availability {reason!r}")
                rows = [r for r in listing.get("forwards") or [] if r.get("machine") == self.machine]
                if any(r.get("state") == "active" or r.get("origin") == "automatic" for r in rows):
                    raise Failure(f"forwards remain: {rows}")
                return True

            wait_for("an older host to disable forwarding", disabled, self.timeout)
            self.wait_refused(self.local_port, 2.0, f"127.0.0.1:{self.local_port} to refuse")
        finally:
            self.tunnel("pretend_old_host", enabled=False)
            self.link("stop")
            self.link("restore")
        self.wait_linked()
        wait_for(f"forward of {self.remote_port} back", lambda: self.active_forward(self.remote_port), self.timeout)
        return {}

    def capability_failure_retried(self) -> Dict[str, Any]:
        """The capability request fails after a reconnect (a Mac stalled past the reply deadline, or
        still busy after the link's retries): the capabilities are unknown, not absent, and the
        forwards ask again by themselves, so R comes back once the host answers."""
        self.require_forwarded()
        self.fail_requests(HOST_STATUS, UNTIL_DISARMED)
        try:
            self.relink()

            def checked() -> str:
                reason = self.availability()
                if not reason or reason == "available":
                    raise Failure(f"availability {reason!r}")
                return reason

            reason = wait_for("the forwards to check the Mac while it does not answer", checked, self.timeout)
        finally:
            self.fail_requests(HOST_STATUS, 0)
        row = wait_for(f"forward of {self.remote_port} back once the host answers (no port change, no relink)",
                       lambda: self.active_forward(self.remote_port), self.timeout)
        self.local_port = int(row["local_port"])
        return {"availability_while_failing": reason, "local_port": self.local_port}

    def listing_failure_retried(self) -> Dict[str, Any]:
        """The port listing fails after a reconnect: the forwards fetch it again by themselves (1 s,
        2 s, 4 s … while the Mac stays connected) instead of waiting for the owner's next
        `supermux.ports.updated`, so R comes back once the host answers."""
        self.require_forwarded()
        self.fail_requests(PORTS_LIST, UNTIL_DISARMED)
        try:
            self.relink()
            wait_for("the Mac to be available", lambda: self.availability() == "available", self.timeout)
            wait_for("a failed port listing", lambda: self.fail_requests(PORTS_LIST).get("failed"), self.timeout)
            # The reconnect's own pokes go by and fail too; afterwards only a retry of the
            # forwards' own fetches the listing.
            time.sleep(POKES_SETTLE_SECONDS)
            state = (self.forward(self.remote_port) or {}).get("state")
            failed = self.fail_requests(PORTS_LIST).get("failed")
            if state == "active":
                raise Failure(f"forward of {self.remote_port} is active although every listing failed ({failed})")
        finally:
            self.fail_requests(PORTS_LIST, 0)
        row = wait_for(f"forward of {self.remote_port} back once the host answers (no port change, no relink)",
                       lambda: self.active_forward(self.remote_port), self.timeout)
        self.local_port = int(row["local_port"])
        return {"state_while_failing": state, "failed_listings": failed, "local_port": self.local_port}

    def chip_default_browser(self) -> Dict[str, Any]:
        self.require_forwarded()
        row = wait_for(f"forward of {self.remote_port}", lambda: self.active_forward(self.remote_port), self.timeout)
        local = int(row["local_port"])
        # The owner's own server holds R here (one Mac is both ends), so the forward moved.
        if local == self.remote_port or not accepts("127.0.0.1", self.remote_port):
            raise Failure(f"precondition: R={self.remote_port} must be busy here and forwarded elsewhere (L={local})")
        opened = self.ports_call("chip_open", workspace_id=self.mirror_id, port=self.remote_port, cmux_browser=False)
        expected = f"http://localhost:{local}"
        got = str(opened.get("external_url") or "").rstrip("/")
        if got != expected:
            raise Failure(f"the chip opened {opened.get('external_url')!r} in the default browser, expected {expected!r} "
                          f"(localhost:{self.remote_port} here is another server): {opened}")
        if opened.get("new_browser_panel_id"):
            raise Failure(f"the chip opened a cmux browser with the setting off: {opened}")
        return {"external_url": got}

    def menu_items(self, port: int) -> Dict[str, Any]:
        """What both port menus offer for `port` of the loopback Mac right now."""
        menus = self.ports_call("menus", workspace_id=self.mirror_id)
        mirror = menus.get("mirror") or {}
        mirror_items = next((p.get("items") for p in mirror.get("ports") or [] if p.get("remote_port") == port), None)
        mac = next((m for m in menus.get("settings") or [] if m.get("machine") == self.machine), {})
        settings_items = next((p.get("items") for p in mac.get("ports") or [] if p.get("remote_port") == port), None)
        return {"mirror": mirror_items, "settings": settings_items, "reason": mirror.get("reason"),
                "settings_shown": mac.get("shown")}

    def pending_forward_stop(self) -> Dict[str, Any]:
        self.require_forwarded()
        server = MarkerServer(f"pending-{self.nonce}")
        self.servers.append(server)
        port = server.port
        self.ports_call("forward", port=port)
        local = int(wait_for(f"a manual forward of {port}", lambda: self.active_forward(port), self.timeout)["local_port"])
        stopped = False
        self.link("stop")
        try:
            wait_for(f"forward of {port} to wait", lambda: (self.forward(port) or {}).get("state") == "waiting", self.timeout)
            self.wait_refused(local, 2.0, f"127.0.0.1:{local} to refuse while the link is down")
            items = self.menu_items(port)
            if "stopForwarding" not in (items["mirror"] or []):
                raise Failure(f"M's Ports on <Mac> menu offers no Stop Forwarding for the waiting forward of {port}: {items}")
            if "stopForwarding" not in (items["settings"] or []):
                raise Failure(f"Settings' Ports… menu offers no Stop Forwarding for the waiting forward of {port}: {items}")
            self.ports_call("stop", port=port)
            stopped = True
            wait_for(f"the stopped forward of {port} to go", lambda: self.forward(port) is None, 5.0)
        finally:
            if not stopped:
                self.ports_call("stop", port=port)
            self.link("restore")
        self.wait_linked()
        wait_for(f"forward of {self.remote_port} back", lambda: self.active_forward(self.remote_port), self.timeout)
        self.ports_call("refresh")
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            row = self.forward(port)
            if row is not None or accepts("127.0.0.1", local):
                raise Failure(f"the stopped forward of {port} came back with the link: {row}")
            time.sleep(0.3)
        return {"port": port, "local_port": local, "menus": items}

    # -- run ------------------------------------------------------------------

    def cleanup(self) -> None:
        for server in self.servers:
            server.close()
        if self.remote_port:
            for pid in listener_pids(self.remote_port):
                try:
                    os.kill(pid, 15)
                except OSError:
                    pass
        for step in (lambda: self.tunnel("clear_injected"), lambda: self.tunnel("pretend_old_host", enabled=False),
                     lambda: self.fail_requests(HOST_STATUS, 0), lambda: self.fail_requests(PORTS_LIST, 0),
                     lambda: self.ports_call("set_auto", enabled=True)):
            try:
                step()
            except Failure:
                pass
        if self.keep:
            return
        for workspace_id in (self.mirror_id, self.source_id):
            if not workspace_id:
                continue
            try:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except Failure as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        # Every step runs (a later one fails its own precondition when an earlier one did).
        ok = self.step("setup", self.setup)
        if ok:
            for name, check in [
                ("auto_forward_busy_port_lands_elsewhere", self.auto_forward_busy_port),
                ("dual_stack_busy_not_stolen", self.dual_stack_busy),
                ("pill_names_local_port", self.pill),
                ("mirror_chip_lists_remote_port", self.chips),
                ("manual_forward_and_stop", self.manual_forward_and_stop),
                ("paused_auto_stays_paused", self.paused_auto),
                ("port_disappears_forward_stops", self.port_disappears),
                ("disconnect_stops_listeners", self.disconnect),
                ("auto_off_keeps_manual", self.auto_off),
                ("external_link_uses_local_port", self.external_link),
                ("old_host_disables", self.old_host),
                ("capability_failure_retried", self.capability_failure_retried),
                ("listing_failure_retried", self.listing_failure_retried),
                ("chip_default_browser_uses_local_port", self.chip_default_browser),
                ("pending_forward_offers_stop", self.pending_forward_stop),
            ]:
                ok = self.step(name, check) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait before a check gives up")
    parser.add_argument("--latency", type=float, default=8.0, help="max seconds from a port scan to an active forward")
    parser.add_argument("--keep", action="store_true", help="leave the source and mirror open")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = PortForwardE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-port-forward-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_port_forward_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
