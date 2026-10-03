#!/usr/bin/env python3
"""End-to-end test of the Mac-to-Mac tunnel host (port forwarding's transport)
against one tagged DEBUG build running the loopback device.

The owning Mac serves its loopback TCP to the user's other Macs over
`tcp_connect` lanes on the device link's connection. The loopback device has no
QUIC connection, so its lanes are in-memory, but the host behind them is the
real `IrxTunnelHost` with the Mac-peer factory (loopback-only policy, Mac-peer
limits, the loop guard, Network.framework connects), and the viewer side is the
real `SupermuxDeviceTunnelClient`. The DEBUG `supermux.devices.tunnel.*` drivers
open tunnels the way a forward does; this suite runs its own servers:

   1. setup                                the loopback linked; marker servers up; driver state reset
   2. capability_advertised                mobile.host.status lists supermux.port_forward.v1
   3. tunnel_reaches_owner_loopback        GET localhost:P through a tunnel returns the marker
   4. closing_server_ends_clean            30 GETs to a server that answers and closes each end clean:
                                           the whole page, then end of stream (host journal `closed clean`)
   5. ipv6_only_server                     a ::1-only server answers localhost:Q (v4 refused, then v6)
   6. journal_scoped                       the host journals `opened {scope: loopback, port: P}`, no host names
   7. policy_denies                        with "iOS Browser Reaches Other Hosts" on (`tunnel.allow_other_hosts`),
                                           169.254.169.254:80, example.com:80 and 192.0.2.1:80 are still
                                           denied (journal `refused {scope: policy}`, never resolved)
   8. closed_port                          a closed port answers `refused`
   9. loop_guard                           a port this app listens on for forwards is denied
  10. revoked                              a revoked peer's opens are denied (`unauthorized`)
  11. ports_list_attributes_workspace_port a server started in a workspace's terminal is listed with
                                           that workspace by mobile.supermux.ports.list
  12. other_ports_lists_unattributed       include_other lists live listeners in no workspace
  13. injected_port_listed_then_cleared    an injected (non-listening) port is listed, then gone
  14. link_drop_ends_tunnels               a held tunnel ends when the link drops
  15. old_host_hides_capability            a host that predates port forwarding: no capability, tunnels
                                           answer `needs_update`; back to normal afterwards
  16. unknown_capabilities_are_retryable   every capability request after a relink fails (`timed_out`,
                                           tunnel.fail_requests): tunnels answer `unreachable`, never
                                           `needs_update`; the browser page, the forwards' availability and
                                           the Settings note do not ask for an update; once the host answers
                                           again the forwards find it available with no relink
  17. stale_port_dropped                   step 11's terminal reports its live port and a dead one
                                           (`report_ports`, no port scan): ports.list keeps the live
                                           one and drops the dead one (the live-listener filter)

Writes a JSON report (default tests/supermux/artifacts/loopback_device_tunnel_e2e-<tag>.json)
and exits non-zero on any failure. Stdlib only; shares the socket client with
loopback_tab_sync_e2e.py.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_device_tunnel_e2e.py [--timeout 30] [--report PATH]
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import socket
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_tab_sync_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    LOOPBACK_DEVICE_ID,
    Failure,
    Socket,
    socket_path_for_tag,
    up,
    wait_for,
)

CAPABILITY = "supermux.port_forward.v1"
HOST_STATUS = "mobile.host.status"
PORTS_LIST = "mobile.supermux.ports.list"
# Words of the "Update Supermux on <Mac>" texts (en, ja), which only an older Mac may get.
UPDATE_WORDS = ("Update Supermux", "アップデート")
# Armed failures that outlast the step (it disarms them itself).
UNTIL_DISARMED = 1000
REPEATED_GETS = 30
# Host names that must never reach the host's journal.
HOST_NAMES = ("localhost", "example.com", "127.0.0.1", "169.254", "::1")
# Destinations another Mac never reaches, even with the iPhone's "iOS Browser
# Reaches Other Hosts" on: cloud metadata (forbidden for the phone too), a
# public name (the phone's tunnel would resolve it) and a non-loopback literal
# (TEST-NET-1: the phone's tunnel would try it; never DNS or a real network).
POLICY_DENIED = (("metadata", "169.254.169.254"), ("public", "example.com"), ("non_loopback_literal", "192.0.2.1"))


def free_port(family: int = socket.AF_INET, address: str = "127.0.0.1") -> int:
    with socket.socket(family, socket.SOCK_STREAM) as probe:
        probe.bind((address, 0))
        return probe.getsockname()[1]


class TunnelSocket(Socket):
    """The shared socket client plus v1 text commands (the sidebar's `report_ports`)."""

    def v1(self, line: str) -> str:
        assert self._sock is not None, "not connected"
        self._sock.sendall((line + "\n").encode("utf-8"))
        reply = self._read_line(self.timeout_s).strip()
        if reply.startswith("ERROR"):
            raise Failure(f"v1 `{line.split(' ')[0]}`: {reply}")
        return reply


class MarkerServer:
    """A threading HTTP server answering every GET with its marker, recording
    each request's Host header."""

    def __init__(self, marker: str, address: str = "127.0.0.1", v6_only: bool = False) -> None:
        self.marker = marker
        self.hosts: List[str] = []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                outer.hosts.append(self.headers.get("Host", ""))
                body = outer.marker.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args: Any) -> None:
                pass

        family = socket.AF_INET6 if ":" in address else socket.AF_INET

        class Server(http.server.ThreadingHTTPServer):
            address_family = family
            daemon_threads = True

            def server_bind(self) -> None:
                if v6_only:
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                super().server_bind()

        self.server = Server((address, 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


class DeviceTunnelE2E:
    def __init__(self, sock: TunnelSocket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:8]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.machine = ""
        self.servers: Dict[str, MarkerServer] = {}
        self.created: List[str] = []
        self.workdir = Path(tempfile.mkdtemp(prefix=f"tunnel-e2e-{self.nonce}-"))
        self.workspace_port = 0
        self.source = ""
        self.source_terminal = ""

    # -- reads and actions ----------------------------------------------------

    def tunnel(self, action: str, **params: Any) -> Dict[str, Any]:
        return self.sock.call(f"supermux.devices.tunnel.{action}", params, timeout_s=60) or {}

    def get(self, port: int, host: Optional[str] = None, path: str = "/marker") -> Dict[str, Any]:
        params: Dict[str, Any] = {"machine": self.machine, "port": port, "path": path}
        if host:
            params["host"] = host
        return self.tunnel("http_get", **params)

    def host_request(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        result = self.sock.call("supermux.devices.request", {
            "machine": self.machine, "method": method, "params": params or {},
        }, timeout_s=60) or {}
        return result.get("result") or {}

    def capabilities(self) -> List[str]:
        return list(self.host_request("mobile.host.status").get("capabilities") or [])

    def cached_capabilities(self) -> Optional[List[str]]:
        devices = (self.sock.call("supermux.devices.list", {"include_capabilities": True}) or {}).get("devices") or []
        device = next((d for d in devices if d.get("machine") == self.machine), {})
        return device.get("capabilities")

    def ports_list(self, include_other: bool = False) -> Dict[str, Any]:
        return self.host_request(PORTS_LIST, {"include_other": include_other} if include_other else {})

    def workspace_ports(self, workspace_id: str) -> List[int]:
        """The ports a workspace reports right now (its sidebar ports, unfiltered)."""
        rows = (self.sock.call("workspace.list", {"workspace_id": workspace_id}) or {}).get("workspaces") or []
        row = next((r for r in rows if up(r.get("id")) == up(workspace_id)), None)
        if row is None:
            raise Failure(f"workspace.list has no {workspace_id}")
        return list(row.get("listening_ports") or [])

    def journal(self) -> List[Dict[str, Any]]:
        return self.tunnel("journal").get("events") or []

    def fail_requests(self, method: str, count: Optional[int] = None) -> Dict[str, Any]:
        """The loopback host answers the next `count` `method` requests `timed_out` (0 disarms);
        without `count`, how many it failed so far."""
        params: Dict[str, Any] = {"method": method}
        if count is not None:
            params["count"] = count
        return self.tunnel("fail_requests", **params)

    def forwards_availability(self) -> Optional[str]:
        """Whether the port forwards think this Mac can forward (`supermux.devices.ports.list`)."""
        listing = self.sock.call("supermux.devices.ports.list", {"machine": self.machine}) or {}
        return (listing.get("availability") or {}).get(self.machine)

    def ports_note(self) -> Optional[str]:
        """The Settings card's ports note for this Mac (the "Ports on <Mac>" menu says the same)."""
        settings = self.sock.call("supermux.devices.remote_macs_settings", {}) or {}
        mac = next((m for m in settings.get("macs") or [] if m.get("machine") == self.machine), {})
        return mac.get("ports_note")

    def expect_no_update_text(self, text: Any, what: str) -> None:
        if any(word in str(text or "") for word in UPDATE_WORDS):
            raise Failure(f"{what} asks for an update: {text!r}")

    def loopback_device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def wait_connected(self) -> None:
        def connected() -> bool:
            device = self.loopback_device()
            return device.get("link_state") == "connected" and bool(device.get("has_fetched_records"))

        wait_for("the loopback link to connect", connected, self.timeout)

    def relink(self) -> None:
        """Drops and redials the link, so the viewer relearns the host's capabilities."""
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        wait_for("the link to drop", lambda: self.loopback_device().get("link_state") != "connected", self.timeout)
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        self.wait_connected()

    def expect_status(self, result: Dict[str, Any], status: str, what: str) -> None:
        if result.get("status") != status:
            raise Failure(f"{what}: expected status {status!r}, got {result}")

    def expect_marker(self, result: Dict[str, Any], marker: str, what: str) -> None:
        self.expect_status(result, "connected", what)
        if result.get("http_status") != 200 or result.get("body") != marker:
            raise Failure(f"{what}: expected HTTP 200 with {marker!r}, got {result}")

    def refusals(self, scope: str, port: int) -> List[Dict[str, Any]]:
        return [e for e in self.journal() if e.get("event") == "refused"
                and (e.get("attributes") or {}).get("scope") == scope
                and (e.get("attributes") or {}).get("port") == str(port)]

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
        self.wait_connected()
        self.machine = self.loopback_device()["machine"]
        self.servers["marker"] = MarkerServer(f"marker-{self.nonce}")
        self.servers["v6"] = MarkerServer(f"v6-{self.nonce}", address="::1", v6_only=True)
        self.servers["guard"] = MarkerServer(f"guard-{self.nonce}")
        self.reset_driver_state()
        ports = {name: server.port for name, server in self.servers.items()}
        self.facts.update(machine=self.machine, server_ports=ports)
        return {"machine": self.machine, "server_ports": ports}

    def reset_driver_state(self) -> None:
        self.tunnel("release_held")
        self.tunnel("revoke", revoked=False)
        self.tunnel("pretend_old_host", enabled=False)
        self.tunnel("allow_other_hosts", enabled=False)
        self.tunnel("clear_injected")
        self.fail_requests(HOST_STATUS, 0)
        if self.servers.get("guard"):
            self.tunnel("own_port", port=self.servers["guard"].port, registered=False)

    def capability_advertised(self) -> Dict[str, Any]:
        capabilities = self.capabilities()
        if CAPABILITY not in capabilities:
            raise Failure(f"mobile.host.status does not list {CAPABILITY}: {sorted(capabilities)}")
        return {"capability": CAPABILITY}

    def tunnel_reaches_owner_loopback(self) -> Dict[str, Any]:
        server = self.servers["marker"]
        result = self.get(server.port)
        self.expect_marker(result, server.marker, f"GET localhost:{server.port}")
        return {"result": result, "server_saw_hosts": server.hosts[-3:]}

    def closing_server_ends_clean(self) -> Dict[str, Any]:
        """A server that answers `Connection: close` and closes ends every tunnel
        clean: the viewer reads the whole page and then the end of the stream,
        never a reset (the host relay must not abort after a complete response)."""
        server = MarkerServer(f"close-{self.nonce}")
        self.servers["close"] = server
        port = str(server.port)
        early = []
        for _ in range(REPEATED_GETS):
            result = self.get(server.port)
            if result.get("status") != "connected" or result.get("http_status") != 200 or result.get("body") != server.marker:
                early.append(result)
        closed = [e for e in self.journal() if e.get("event") == "closed" and (e.get("attributes") or {}).get("port") == port]
        aborted = [e for e in closed if (e.get("attributes") or {}).get("result") != "clean"]
        if early or aborted:
            raise Failure(f"{len(early)} of {REPEATED_GETS} GETs ended early (first: {early[:1]}); "
                          f"the host journaled {len(aborted)} of {len(closed)} relays as aborted")
        return {"gets": REPEATED_GETS, "closed_clean": len(closed)}

    def ipv6_only_server(self) -> Dict[str, Any]:
        server = self.servers["v6"]
        result = self.get(server.port)
        self.expect_marker(result, server.marker, f"GET localhost:{server.port} (::1 only)")
        return {"result": result}

    def journal_scoped(self) -> Dict[str, Any]:
        port = str(self.servers["marker"].port)
        events = self.journal()
        opened = [e for e in events if e.get("event") == "opened"
                  and (e.get("attributes") or {}).get("port") == port]
        if not opened:
            raise Failure(f"no `host-tunnel opened` event for port {port} in {events[-10:]}")
        if (opened[-1].get("attributes") or {}).get("scope") != "loopback":
            raise Failure(f"the open was journaled with {opened[-1]}")
        leaks = [e for e in events for value in (e.get("attributes") or {}).values()
                 if any(name in str(value) for name in HOST_NAMES)]
        if leaks:
            raise Failure(f"the journal names hosts: {leaks[:3]}")
        return {"opened": opened[-1], "event_count": len(events)}

    def policy_denies(self) -> Dict[str, Any]:
        """Another Mac reaches only loopback, whatever the iPhone's "iOS Browser
        Reaches Other Hosts" says: with it on, the phone's policy would resolve
        example.com and try 192.0.2.1, so only the Mac-peer policy denies both."""
        before = len(self.refusals("policy", 80))
        enabled = self.tunnel("allow_other_hosts", enabled=True)
        if enabled.get("enabled") is not True:
            raise Failure(f"the driver did not turn on mobile.browserTunnel.allowOtherHosts: {enabled}")
        results: Dict[str, Any] = {}
        try:
            for name, host in POLICY_DENIED:
                results[name] = self.get(80, host=host)
                self.expect_status(results[name], "denied", f"{host}:80 with allowOtherHosts on")
            still = self.tunnel("allow_other_hosts")
            if still.get("enabled") is not True:
                raise Failure(f"allowOtherHosts did not stay on during the opens (does cmux.json manage it?): {still}")
        finally:
            self.tunnel("allow_other_hosts", enabled=False)
        after = len(self.refusals("policy", 80))
        if after < before + len(POLICY_DENIED):
            raise Failure(f"expected {len(POLICY_DENIED)} `refused {{scope: policy}}` journal events, found {after - before}")
        return results

    def closed_port(self) -> Dict[str, Any]:
        port = free_port()
        result = self.get(port)
        self.expect_status(result, "refused", f"closed port {port}")
        return {"port": port, "result": result}

    def loop_guard(self) -> Dict[str, Any]:
        server = self.servers["guard"]
        self.expect_marker(self.get(server.port), server.marker, "the guard server before it is registered")
        registered = self.tunnel("own_port", port=server.port, registered=True)
        if registered.get("registered") is not True:
            raise Failure(f"the driver did not register port {server.port} as this app's: {registered}")
        try:
            refused = self.get(server.port)
            self.expect_status(refused, "denied", f"own listener port {server.port}")
        finally:
            self.tunnel("own_port", port=server.port, registered=False)
        self.expect_marker(self.get(server.port), server.marker, "the guard server after it is unregistered")
        return {"port": server.port, "refused": refused}

    def revoked(self) -> Dict[str, Any]:
        port = self.servers["marker"].port
        before = len(self.refusals("unauthorized", port))
        self.tunnel("revoke", revoked=True)
        try:
            result = self.get(port)
            self.expect_status(result, "denied", "a revoked peer")
        finally:
            self.tunnel("revoke", revoked=False)
        if len(self.refusals("unauthorized", port)) <= before:
            raise Failure("no `refused {scope: unauthorized}` journal event")
        self.expect_marker(self.get(port), self.servers["marker"].marker, "after the revoke is lifted")
        return {"result": result}

    def ports_list_attributes_workspace_port(self) -> Dict[str, Any]:
        title = f"tunnel-ports-{self.nonce}"
        created = self.sock.call("workspace.create", {"title": title, "focus": False}) or {}
        self.source = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not self.source:
            raise Failure(f"workspace.create returned no id: {created}")
        self.created.append(self.source)
        self.sock.call("workspace.rename", {"workspace_id": self.source, "title": title})

        def terminal() -> Optional[str]:
            surfaces = (self.sock.call("surface.list", {"workspace_id": self.source}) or {}).get("surfaces") or []
            return next((up(s.get("id")) for s in surfaces if s.get("type") == "terminal"), None)

        surface = wait_for("the workspace's terminal", terminal, self.timeout)
        self.source_terminal = surface
        wait_for("the terminal's prompt", lambda: (self.sock.call("surface.read_text", {
            "workspace_id": self.source, "surface_id": surface}) or {}).get("text", "").strip(), self.timeout)
        port = free_port()
        self.workspace_port = port
        (self.workdir / "marker.html").write_text(f"ws-{self.nonce}")
        self.sock.call("surface.send_text", {"workspace_id": self.source, "surface_id": surface,
                                             "text": f"cd {self.workdir} && exec python3 -m http.server {port} --bind 127.0.0.1\n"})
        wait_for(f"the workspace's server on {port}", lambda: self.direct_get(port, "/marker.html") == f"ws-{self.nonce}", self.timeout)

        def listed() -> Optional[Dict[str, Any]]:
            self.sock.call("surface.ports_kick", {"workspace_id": self.source, "surface_id": surface})
            entries = self.ports_list().get("ports") or []
            return next((e for e in entries if e.get("port") == port and up(e.get("workspace_id")) == self.source), None)

        entry = wait_for(f"ports.list to attribute {port} to the workspace", listed, self.timeout, interval_s=1.0)
        if entry.get("workspace_title") != title:
            raise Failure(f"the entry names workspace {entry.get('workspace_title')!r}, not {title!r}: {entry}")
        return {"port": port, "workspace_id": self.source, "entry": entry}

    def direct_get(self, port: int, path: str) -> Optional[str]:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=2) as response:
                return response.read().decode()
        except OSError:
            return None

    def other_ports_lists_unattributed(self) -> Dict[str, Any]:
        marker = self.servers["marker"].port
        listing = self.ports_list(include_other=True)
        attributed = {e.get("port") for e in listing.get("ports") or []}
        other = listing.get("other_ports")
        if not isinstance(other, list) or marker not in other:
            raise Failure(f"other_ports does not list the suite's own server {marker}: {other}")
        if marker in attributed:
            raise Failure(f"the suite's server {marker} is attributed to a workspace: {listing.get('ports')}")
        if self.workspace_port and self.workspace_port in other:
            raise Failure(f"the workspace's port {self.workspace_port} is also in other_ports")
        plain = self.ports_list()
        if plain.get("other_ports"):
            raise Failure(f"other_ports came back without include_other: {plain.get('other_ports')[:5]}")
        return {"other_count": len(other)}

    def injected_port_listed_then_cleared(self) -> Dict[str, Any]:
        """The DEBUG injection other suites use (it bypasses the live-listener filter)."""
        if not self.source:
            raise Failure("no source workspace (ports_list_attributes_workspace_port failed)")
        port = free_port()

        def has_port() -> bool:
            return any(e.get("port") == port and up(e.get("workspace_id")) == self.source
                       for e in self.ports_list().get("ports") or [])

        self.tunnel("inject_port", workspace_id=self.source, port=port)
        wait_for(f"the injected port {port} in ports.list", has_port, self.timeout)
        self.tunnel("clear_injected")
        wait_for(f"the injected port {port} to leave ports.list", lambda: not has_port(), self.timeout)
        return {"port": port}

    def link_drop_ends_tunnels(self) -> Dict[str, Any]:
        held = self.tunnel("hold", machine=self.machine, port=self.servers["marker"].port)
        self.expect_status(held, "connected", "holding a tunnel")
        state = self.tunnel("host_state", machine=self.machine)
        if not state.get("connection_live") or (state.get("active_tunnels") or 0) < 1:
            raise Failure(f"the held tunnel is not active on the host: {state}")
        def ended() -> Optional[Dict[str, Any]]:
            now = self.tunnel("host_state", machine=self.machine)
            return now if not now.get("connection_live") and now.get("active_tunnels") == 0 else None

        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        try:
            drained = wait_for("the host's tunnels to end with the link", ended, self.timeout)
        finally:
            self.tunnel("release_held")
            self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
            self.wait_connected()
        again = self.tunnel("host_state", machine=self.machine)
        if not again.get("connection_live"):
            raise Failure(f"the new connection has no live tunnel host: {again}")
        return {"held": state, "after_drop": drained, "after_restore": again}

    def old_host_hides_capability(self) -> Dict[str, Any]:
        self.tunnel("pretend_old_host", enabled=True)
        try:
            self.relink()
            if CAPABILITY in self.capabilities():
                raise Failure("mobile.host.status still lists the capability")
            cached = self.cached_capabilities() or []
            if CAPABILITY in cached:
                raise Failure("the viewer still believes the host serves port forwarding")
            result = self.get(self.servers["marker"].port)
            self.expect_status(result, "needs_update", "a tunnel to an old host")
        finally:
            self.tunnel("pretend_old_host", enabled=False)
            self.relink()
        if CAPABILITY not in (self.cached_capabilities() or []):
            raise Failure("the capability did not come back after the host was 'updated'")
        self.expect_marker(self.get(self.servers["marker"].port), self.servers["marker"].marker, "after the update")
        return {"old_host_result": result}

    def unknown_capabilities_are_retryable(self) -> Dict[str, Any]:
        """A capability request that fails (a Mac stalled past the reply deadline, or still busy after
        the link's retries) leaves the capabilities unknown, not absent: nothing may say "Update
        Supermux", a tunnel open is retryable, and the forwards ask again by themselves."""
        marker = self.servers["marker"]
        self.fail_requests(HOST_STATUS, UNTIL_DISARMED)
        try:
            self.relink()
            result = self.get(marker.port)
            self.expect_status(result, "unreachable", "a tunnel while the capabilities are unknown")
            if result.get("page_reason") != "unreachable":
                raise Failure(f"the browser page's reason is {result.get('page_reason')!r}, not unreachable: {result}")
            self.expect_no_update_text(result.get("page_headline"), "the browser page")
            def checked() -> Optional[str]:
                value = self.forwards_availability()
                if value == "available":
                    raise Failure("the forwards still hold 'available' from before the relink")
                return value

            availability = wait_for("the forwards to check this Mac", checked, self.timeout)
            if availability != "unreachable":
                raise Failure(f"the forwards' availability is {availability!r} while the capabilities are unknown")
            note = self.ports_note()
            self.expect_no_update_text(note, "the Settings ports note")
            failed = self.fail_requests(HOST_STATUS).get("failed")
        finally:
            self.fail_requests(HOST_STATUS, 0)
        wait_for("the forwards to find this Mac available again without a relink",
                 lambda: self.forwards_availability() == "available", self.timeout)
        self.expect_marker(self.get(marker.port), marker.marker, "once the host answers again")
        return {"unknown_result": result, "settings_note": note, "failed_status_requests": failed}

    def stale_port_dropped(self) -> Dict[str, Any]:
        """A port a workspace still reports that nothing serves (a port restored
        from a session snapshot, before the next scan) is not listed: the
        live-listener filter, not a port scan, drops it. `report_ports` sets
        the terminal's ports to its live server's and a dead one without a
        scan; the workspace still reporting the dead port after the listing
        proves it was there when ports.list read it (a scan in between
        replaces it, so the seed is retried)."""
        if not (self.source and self.source_terminal and self.workspace_port):
            raise Failure("no workspace server (ports_list_attributes_workspace_port failed)")
        live, dead = self.workspace_port, free_port()
        seed = f"report_ports {live} {dead} --tab={self.source} --panel={self.source_terminal}"

        def listed_while_seeded() -> Optional[Dict[str, Any]]:
            self.sock.v1(seed)
            entries = self.ports_list().get("ports") or []
            return {"entries": entries} if dead in self.workspace_ports(self.source) else None

        try:
            entries = wait_for(f"a listing while the workspace reports the dead port {dead}",
                               listed_while_seeded, self.timeout)["entries"]
        finally:
            # A scan puts the terminal's real ports back.
            self.sock.call("surface.ports_kick", {"workspace_id": self.source, "surface_id": self.source_terminal})
        if any(e.get("port") == dead for e in entries):
            raise Failure(f"ports.list lists {dead}, which the workspace reports but nothing serves: {entries}")
        if not any(e.get("port") == live and up(e.get("workspace_id")) == self.source for e in entries):
            raise Failure(f"ports.list no longer attributes the live {live} to the workspace: {entries}")
        return {"live_port": live, "dead_port": dead}

    # -- run ------------------------------------------------------------------

    def cleanup(self) -> None:
        try:
            self.reset_driver_state()
            bindings = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
            for workspace_id in self.created:
                for mirror in bindings:
                    if mirror.get("machine") == self.machine and up(mirror.get("remote_workspace_id")) == workspace_id:
                        self.sock.call("workspace.close", {"workspace_id": mirror.get("workspace_id"), "force": True})
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
        except (Failure, OSError) as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))
        for server in self.servers.values():
            server.close()

    def run(self) -> bool:
        ok = self.step("setup", self.setup)
        if ok:
            for name, check in [
                ("capability_advertised", self.capability_advertised),
                ("tunnel_reaches_owner_loopback", self.tunnel_reaches_owner_loopback),
                ("closing_server_ends_clean", self.closing_server_ends_clean),
                ("ipv6_only_server", self.ipv6_only_server),
                ("journal_scoped", self.journal_scoped),
                ("policy_denies", self.policy_denies),
                ("closed_port", self.closed_port),
                ("loop_guard", self.loop_guard),
                ("revoked", self.revoked),
                ("ports_list_attributes_workspace_port", self.ports_list_attributes_workspace_port),
                ("other_ports_lists_unattributed", self.other_ports_lists_unattributed),
                ("injected_port_listed_then_cleared", self.injected_port_listed_then_cleared),
                ("link_drop_ends_tunnels", self.link_drop_ends_tunnels),
                ("old_host_hides_capability", self.old_host_hides_capability),
                ("unknown_capabilities_are_retryable", self.unknown_capabilities_are_retryable),
                ("stale_port_dropped", self.stale_port_dropped),
            ]:
                ok = self.step(name, check) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per wait")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = TunnelSocket(path)
    try:
        sock.connect()
        test = DeviceTunnelE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-device-tunnel-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_device_tunnel_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
