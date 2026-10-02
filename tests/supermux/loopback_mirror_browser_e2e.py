#!/usr/bin/env python3
"""End-to-end test: a device mirror's browser opens the owning Mac's localhost.

A browser tab opened in a mirror of another Mac's workspace used to be a plain
browser of THIS Mac: `localhost:3000` there loaded this Mac's server, never the
one running in the mirrored terminal. Now a mirror's browsers (bound or not)
use upstream's remote-workspace browser mode: one website data store per remote
app instance, and a per-instance authenticated SOCKS5/HTTP CONNECT proxy on this
Mac's loopback that sends the owner's loopback hosts through the device link's
tunnel lanes and dials every other host directly. This suite drives one tagged
DEBUG build running the loopback device ("Loopback Mac" = this same app's own
mobile host, whose tunnel host runs in-process), so "the owner's loopback" and
this Mac's are one machine: every check is about the ROUTE (proxy, tunnel opens,
store), not just whether a page loads. Marker servers run in this script, in no
workspace, each on its own port so tunnel opens are attributed exactly. A
routed browser's data store is the owning app instance's: a name-based UUID of
its machine id (`device:<uuid>@<tag>`), the key its proxy has, computed here
independently:

  1 mirror_browser_routes_through_owner  localhost:P in the mirror loads through the proxy and the owner's
                                         tunnel host (journal `opened` for P), in the app instance's data
                                         store, and the server sees `Host: localhost:P`
  2 literal_127_routes                   http://127.0.0.1:P2 in the mirror routes the same way
  3 local_workspace_stays_direct         the same kind of URL in the source workspace: no proxy, the
                                         profile store, no tunnel open (control)
  4 non_loopback_goes_direct             this Mac's LAN address in the mirror loads this Mac's page, no tunnel
                                         open (Network.framework skips the proxy for this Mac's own addresses,
                                         as for localhost); an authenticated CONNECT to it, as WebKit sends for
                                         any other LAN or public host, is dialed directly by the proxy, no
                                         tunnel open (skipped when the Mac has no non-loopback IPv4)
  5 closed_port_explains                 a closed port in a new mirror tab shows the "localhost:N on <Mac> isn't
                                         answering" page within 5 s
  6 proxy_requires_credential            the proxy refuses SOCKS no-auth (05 FF), a wrong password (01 01)
                                         and CONNECT without credentials (407); the right one connects
  7 terminal_link_opens_routed_browser   a link click in the mirror's terminal (cmux browser) opens a
                                         routed browser in the mirror
  8 moved_tab_swaps_route                the routed browser moved into the source loses the route and
                                         store; moved back, it routes again
  9 old_host_page                        an owner without `supermux.port_forward.v1` gives the "update
                                         Supermux" page
 10 proxy_connections_are_released       after relayed, refused, failed and explained proxy connections (and
                                         direct ones, with a LAN address) end, the app holds no socket of
                                         theirs (lsof on the app: the proxy cancels every connection it
                                         accepted or dialed)
 11 data_store_per_app_instance          the route's data store for two machine ids that differ only by tag
                                         are two stores, each the name-based UUID of its machine id
 12 unbound_mirror_browser_routes        a browser in an unbound mirror (upstream's vm.workspace_open with
                                         auto-mirror off) routes through the owner like a bound one's
 13 idle_proxy_connections_close         connections that never send a byte are closed: the ones past the
                                         limit of clients still in their handshake at once, the rest at the
                                         handshake deadline
 14 proxy_listener_failure_recovers      after the proxy's listener fails, an open mirror tab and a new one
                                         load through a fresh endpoint

Uses the DEBUG drivers `supermux.devices.mirror.browser_route`, `.browser_proxy`,
`.browser_proxy_fail`, `.browser_store` and `.link_open`
(SupermuxMirrorBrowserSocket) and the tunnel driver
`supermux.devices.tunnel.journal` and `.pretend_old_host`. Writes a JSON report
(default tests/supermux/artifacts/loopback_mirror_browser_e2e-<tag>.json) and
exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_browser_e2e.py [--timeout 20] [--report PATH]
"""

from __future__ import annotations

import argparse
import base64
import http.server
import json
import os
import select
import socket
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_mirror_local_panels_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    Failure,
    MirrorPair,
    Socket,
    socket_path_for_tag,
    up,
    wait_for,
)

PORT_FORWARD_CAPABILITY = "supermux.port_forward.v1"
LOOPBACK_ALIAS = "cmux-loopback.localtest.me"
# The namespace of the route's per-app-instance data stores
# (SupermuxDeviceBrowserRoute.websiteDataStoreID(for:)); a store must keep its
# identity across launches, so this pins it.
DATA_STORE_NAMESPACE = uuid.UUID("503c7a18-bbc6-4c4b-beca-22549addb0eb")
# The proxy's limit of clients still in their handshake, and its deadline for one.
HANDSHAKE_LIMIT = 64
HANDSHAKE_DEADLINE_S = 10.0
# How long the closed port's explanation page may take in a new mirror tab: the
# proxy answers in milliseconds (the tunnel's refusal, then the page).
EXPLAIN_PAGE_S = 5.0


class MarkerServer:
    """A threaded HTTP server for one step: a marker page and every request's headers."""

    def __init__(self, host: str, title: str) -> None:
        self.title = title
        self.hits: List[Dict[str, Any]] = []
        page = f"<html><head><title>{title}</title></head><body>{title}</body></html>".encode()
        hits = self.hits

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 (http.server API)
                hits.append({"path": self.path, "host": self.headers.get("Host"), "client": self.client_address[0]})
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(page)))
                self.end_headers()
                self.wfile.write(page)

            def log_message(self, *_: Any) -> None:
                pass

        self.server = http.server.ThreadingHTTPServer((host, 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def marker_hosts(self) -> List[str]:
        return [str(hit.get("host")) for hit in self.hits if str(hit.get("path", "")).startswith("/marker.html")]

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def primary_ipv4() -> Optional[str]:
    """This Mac's outward IPv4 address (no packet is sent), or None."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("192.0.2.1", 9))
            address = probe.getsockname()[0]
    except OSError:
        return None
    return None if address.startswith("127.") or address == "0.0.0.0" else address


def recv_exactly(conn: socket.socket, count: int) -> bytes:
    data = b""
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            break
        data += chunk
    return data


def recv_until_closed(conn: socket.socket, limit: int = 1 << 20) -> bytes:
    data = b""
    while len(data) < limit:
        try:
            chunk = conn.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        data += chunk
    return data


def data_store_id(machine: str) -> str:
    """The data store a routed browser of `machine` (`device:<uuid>@<tag>`) must use."""
    return up(str(uuid.uuid5(DATA_STORE_NAMESPACE, machine)))


def sibling_instance(machine: str) -> str:
    """The same Mac's machine id with another app-instance tag."""
    device, _, tag = machine.partition("@")
    return f"{device}@{'default' if tag != 'default' else 'e2e-sibling'}"


def listening_pid(port: int) -> int:
    """The process listening on TCP `port` (lsof), 0 when none."""
    out = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
                         capture_output=True, text=True, timeout=30).stdout.split()
    return int(out[0]) if out else 0


def tcp_connections(pid: int, port: int) -> List[Tuple[int, int]]:
    """(local port, peer port) of every connected TCP socket `pid` holds with
    either end on `port` (lsof; a listener is not a connection)."""
    out = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), f"-iTCP:{port}", "-F", "n"],
                         capture_output=True, text=True, timeout=30).stdout
    found = []
    for line in out.splitlines():
        if line.startswith("n") and "->" in line:
            local, peer = line[1:].split("->", 1)
            found.append((int(local.rsplit(":", 1)[1]), int(peer.rsplit(":", 1)[1])))
    return found


class MirrorBrowserE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.timeout = args.timeout
        self.keep = args.keep
        self.nonce = uuid.uuid4().hex[:6]
        self.pair = MirrorPair(sock, args.timeout, f"mirror-browser-{self.nonce}")
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.servers: List[MarkerServer] = []
        self.device_id = ""
        self.source_terminal = ""
        self.mirror_browser = ""
        self.owner_server: Optional[MarkerServer] = None

    # -- reads -----------------------------------------------------------------

    def tunnel(self, action: str, **params: Any) -> Dict[str, Any]:
        """The tunnel lanes' DEBUG driver (`supermux.devices.tunnel.<action>`)."""
        return self.sock.call(f"supermux.devices.tunnel.{action}", params) or {}

    def journal_opens(self, port: int) -> int:
        """`host-tunnel opened` events for `port` in the owner's tunnel journal."""
        found = 0

        def walk(node: Any) -> None:
            nonlocal found
            if isinstance(node, dict):
                attributes = node.get("attributes") if isinstance(node.get("attributes"), dict) else node
                if node.get("event") == "opened" and str(attributes.get("port")) == str(port):
                    found += 1
                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)

        walk(self.tunnel("journal"))
        return found

    def proxy(self) -> Optional[Dict[str, Any]]:
        reply = self.sock.call("supermux.devices.mirror.browser_proxy", {"machine": self.pair.machine}) or {}
        return reply.get("proxy") or None

    def require_proxy(self) -> Dict[str, Any]:
        proxy = self.proxy()
        if not proxy:
            raise Failure("no browser proxy is listening for the loopback Mac")
        return proxy

    def route(self, workspace_id: str, panel_id: str) -> Dict[str, Any]:
        reply = self.sock.call("supermux.devices.mirror.browser_route", {"workspace_id": workspace_id}) or {}
        for browser in reply.get("browsers") or []:
            if up(browser.get("panel_id")) == up(panel_id):
                return browser
        raise Failure(f"no browser {panel_id} in workspace {workspace_id}")

    def expect_route(self, workspace_id: str, panel_id: str, remote: bool) -> Dict[str, Any]:
        """The browser routes through the owner (or not), with the matching proxy configs and store."""
        owner_store = data_store_id(self.pair.machine)

        def check() -> Dict[str, Any]:
            route = self.route(workspace_id, panel_id)
            store = up(route.get("store_identifier"))
            if remote:
                if not route.get("routes_remotely"):
                    raise Failure(f"the browser does not route through the owning Mac: {route}")
                if route.get("proxy_configs") != 2:
                    raise Failure(f"want 2 WebKit proxy configurations (SOCKS5 + CONNECT): {route}")
                if store != owner_store:
                    raise Failure(f"want the app instance's data store {owner_store}: {route}")
            else:
                if route.get("routes_remotely"):
                    raise Failure(f"a local browser routes through the owning Mac: {route}")
                if route.get("proxy_configs") != 0:
                    raise Failure(f"want no proxy configuration (is a system proxy set?): {route}")
                if store == owner_store:
                    raise Failure(f"a local browser uses the remote app instance's data store: {route}")
            return route

        return wait_for(f"browser {panel_id} to {'route' if remote else 'not route'} through the owner", check, self.timeout)

    def wait_title(self, surface_id: str, want: Callable[[str], bool], what: str) -> str:
        def titled() -> Optional[str]:
            title = str((self.sock.call("browser.get.title", {"surface_id": surface_id}) or {}).get("title") or "")
            if not want(title):
                raise Failure(f"title is {title!r}")
            return title

        return wait_for(what, titled, self.timeout)

    def new_tab(self, workspace_id: str, surface_id: str, url: str) -> str:
        created = self.sock.call("browser.tab.new", {"workspace_id": workspace_id, "surface_id": surface_id, "url": url}) or {}
        panel = up(created.get("surface_id"))
        if not panel:
            raise Failure(f"browser.tab.new returned no surface_id: {created}")
        return panel

    def navigate(self, surface_id: str, url: str) -> None:
        self.sock.call("browser.navigate", {"surface_id": surface_id, "url": url}, timeout_s=self.timeout + 10)

    def server(self, label: str, host: str = "127.0.0.1") -> MarkerServer:
        server = MarkerServer(host, f"marker-{self.nonce}-{label}")
        self.servers.append(server)
        return server

    def capabilities(self) -> Optional[List[str]]:
        return self.pair.device().get("capabilities")

    def link(self, action: str) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.link", {"machine": self.pair.machine, "action": action}) or {}

    def relink(self, expect_capability: Optional[bool]) -> Dict[str, Any]:
        """Drops and redials the loopback link, so the capability cache is fetched again."""
        self.link("stop")
        wait_for("the loopback link to drop", lambda: self.pair.device().get("link_state") != "connected", self.timeout)
        self.link("restore")
        self.pair.wait_connected()

        def fetched() -> Optional[List[str]]:
            capabilities = self.capabilities()
            if capabilities is None:
                raise Failure("capabilities not fetched yet")
            if expect_capability is not None and (PORT_FORWARD_CAPABILITY in capabilities) != expect_capability:
                raise Failure(f"capabilities {capabilities}")
            return capabilities or ["(none)"]

        return {"capabilities": wait_for("the link's capability fetch", fetched, self.timeout)}

    # -- steps -----------------------------------------------------------------

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
        status = "SKIP" if record.get("skipped") else ("PASS" if record["ok"] else "FAIL")
        print(f"{status} {name} ({record['seconds']}s)" + ("" if record["ok"] else ": " + record["error"]), file=sys.stderr)
        return record["ok"]

    def setup(self) -> Dict[str, Any]:
        created = self.pair.create()
        self.device_id = str(self.pair.device().get("device_id") or "")
        self.source_terminal = created["first_terminal"]
        self.facts.update(machine=self.pair.machine, device_id=self.device_id, device_name=self.pair.device_name,
                          source_workspace_id=self.pair.source_id, mirror_workspace_id=self.pair.mirror_id,
                          capabilities=self.capabilities())
        return created

    def require_mirror_browser(self) -> str:
        if not self.mirror_browser:
            raise Failure("precondition: the first step opened no browser in the mirror")
        return self.mirror_browser

    def mirror_terminal(self) -> str:
        return self.pair.require_mirror_panel(self.source_terminal, "the source's first terminal")

    def routes_through_owner(self) -> Dict[str, Any]:
        server = self.owner_server = self.server("owner")
        opens_before = self.journal_opens(server.port)
        dials_before = int((self.proxy() or {}).get("owner_dials") or 0)
        url = f"http://localhost:{server.port}/marker.html"
        self.mirror_browser = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), url)
        title = self.wait_title(self.mirror_browser, lambda t: t == server.title, "the marker page in the mirror")
        route = self.expect_route(self.pair.mirror_id, self.mirror_browser, remote=True)
        proxy = self.require_proxy()
        if int(proxy.get("owner_dials") or 0) <= dials_before:
            raise Failure(f"the proxy never dialed the owner ({dials_before} -> {proxy.get('owner_dials')})")
        opens = self.journal_opens(server.port)
        if opens <= opens_before:
            raise Failure(f"the owner's tunnel journal has no `opened` for port {server.port}")
        host = f"localhost:{server.port}"
        if host not in server.marker_hosts():
            raise Failure(f"the server never saw Host: {host} (saw {server.marker_hosts()})")
        return {"url": url, "title": title, "route": route, "owner_dials": proxy.get("owner_dials"),
                "journal_opens": opens, "hosts": server.marker_hosts()}

    def literal_127_routes(self) -> Dict[str, Any]:
        server = self.server("literal")
        opens_before = self.journal_opens(server.port)
        url = f"http://127.0.0.1:{server.port}/marker.html"
        panel = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), url)
        title = self.wait_title(panel, lambda t: t == server.title, "the 127.0.0.1 marker page in the mirror")
        route = self.expect_route(self.pair.mirror_id, panel, remote=True)
        opens = self.journal_opens(server.port)
        if opens <= opens_before:
            raise Failure(f"the owner's tunnel journal has no `opened` for port {server.port}")
        return {"url": url, "title": title, "route": route, "journal_opens": opens, "hosts": server.marker_hosts()}

    def local_stays_direct(self) -> Dict[str, Any]:
        server = self.server("local")
        url = f"http://localhost:{server.port}/marker.html"
        panel = self.new_tab(self.pair.source_id, self.source_terminal, url)
        title = self.wait_title(panel, lambda t: t == server.title, "the marker page in the source")
        route = self.expect_route(self.pair.source_id, panel, remote=False)
        opens = self.journal_opens(server.port)
        if opens:
            raise Failure(f"a local browser's request went through the tunnel ({opens} opens of port {server.port})")
        return {"url": url, "title": title, "route": route}

    def non_loopback_direct(self) -> Dict[str, Any]:
        address = primary_ipv4()
        if not address:
            return {"skipped": True, "reason": "this Mac has no non-loopback IPv4 address"}
        server = self.server("lan", host=address)
        dials_before = int(self.require_proxy().get("direct_dials") or 0)
        url = f"http://{address}:{server.port}/marker.html"
        self.navigate(self.require_mirror_browser(), url)
        title = self.wait_title(self.mirror_browser, lambda t: t == server.title, "the LAN marker page in the mirror")
        # The browser does not consult the proxy for this Mac's own address,
        # so whether it dialed is a fact, not a check.
        browser_dials = int(self.require_proxy().get("direct_dials") or 0) - dials_before
        target = f"{address}:{server.port}"
        established, page = self.proxy_connect(target, "/marker.html")
        if not established.startswith(b"HTTP/1.1 200") or server.title not in page:
            raise Failure(f"an authenticated CONNECT to {target} got {established[:40]!r} and no marker")
        proxy = self.require_proxy()
        if int(proxy.get("direct_dials") or 0) <= dials_before + browser_dials:
            raise Failure(f"the proxy never dialed {target} directly ({dials_before} -> {proxy.get('direct_dials')})")
        opens = self.journal_opens(server.port)
        if opens:
            raise Failure(f"a LAN request went through the owner's tunnel ({opens} opens)")
        return {"url": url, "title": title, "browser_direct_dials": browser_dials, "direct_dials": proxy.get("direct_dials")}

    def proxy_connect(self, target: str, path: str) -> tuple[bytes, str]:
        """An authenticated HTTP CONNECT to `target` through the mirror's proxy, then
        `GET path`: the CONNECT reply head and the page."""
        proxy = self.require_proxy()
        token = base64.b64encode(f"{proxy['username']}:{proxy['password']}".encode()).decode()
        with socket.create_connection(("127.0.0.1", int(proxy["port"])), timeout=10) as conn:
            conn.settimeout(10)
            conn.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nProxy-Authorization: Basic {token}\r\n\r\n".encode())
            established = b""
            while b"\r\n\r\n" not in established:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                established += chunk
            conn.sendall(f"GET {path} HTTP/1.0\r\nHost: {target}\r\n\r\n".encode())
            page = recv_until_closed(conn).decode(errors="replace")
        return established, page

    def closed_port_explains(self) -> Dict[str, Any]:
        """The explanation page opens promptly, in a tab of its own. Typing a URL
        into the shared tab (it shows the previous step's LAN page) would also
        time WebKit, not the proxy: since WebKit 27 a typed navigation to plain
        HTTP on a host that is not loopback by name (the localhost alias, a LAN
        address) leaves the page's hardened Enhanced Security process and comes
        back once the response arrives, and a swap into a process WebKit
        already had can take seconds on a busy host."""
        closed = free_port()
        name = self.pair.device_name
        started = time.monotonic()
        panel = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), f"http://localhost:{closed}/")
        title = self.wait_title(
            panel, lambda t: f"localhost:{closed}" in t and name in t,
            f"the \"localhost:{closed} on {name} isn't answering\" page",
        )
        seconds = round(time.monotonic() - started, 2)
        self.sock.call("surface.close", {"surface_id": panel})
        if seconds > EXPLAIN_PAGE_S:
            raise Failure(f"the explanation page took {seconds}s, want at most {EXPLAIN_PAGE_S:.0f}s")
        return {"port": closed, "title": title, "page_seconds": seconds}

    def proxy_requires_credential(self) -> Dict[str, Any]:
        proxy = self.require_proxy()
        port = int(proxy["port"])
        assert self.owner_server is not None

        def connect() -> socket.socket:
            conn = socket.create_connection(("127.0.0.1", port), timeout=10)
            conn.settimeout(10)
            return conn

        with connect() as conn:
            conn.sendall(b"\x05\x01\x00")
            no_auth = recv_exactly(conn, 2)
        if no_auth != b"\x05\xff":
            raise Failure(f"SOCKS5 no-auth got {no_auth.hex()}, want 05ff")
        with connect() as conn:
            conn.sendall(b"\x05\x01\x02")
            method = recv_exactly(conn, 2)
            conn.sendall(b"\x01" + bytes([len(b"cmux")]) + b"cmux" + bytes([len(b"wrong")]) + b"wrong")
            wrong = recv_exactly(conn, 2)
        if method != b"\x05\x02" or wrong != b"\x01\x01":
            raise Failure(f"SOCKS5 wrong password got {method.hex()} then {wrong.hex()}, want 0502 then 0101")
        target = f"localhost:{self.owner_server.port}"
        with connect() as conn:
            conn.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
            bare = recv_until_closed(conn, 4096).decode(errors="replace")
        if not bare.startswith("HTTP/1.1 407"):
            raise Failure(f"CONNECT without credentials got {bare.splitlines()[:1]}, want 407")
        # The right credential connects (HTTP CONNECT) and reaches the marker.
        established, page = self.proxy_connect(target, "/marker.html")
        if not established.startswith(b"HTTP/1.1 200") or self.owner_server.title not in page:
            raise Failure(f"an authenticated CONNECT got {established[:40]!r} and no marker")
        return {"no_auth": no_auth.hex(), "wrong_password": wrong.hex(), "bare_connect": bare.splitlines()[0]}

    def terminal_link_opens_routed_browser(self) -> Dict[str, Any]:
        assert self.owner_server is not None
        server = self.owner_server
        reply = self.sock.call("supermux.devices.mirror.link_open", {
            "workspace_id": self.pair.mirror_id, "surface_id": self.mirror_terminal(),
            "url": f"http://localhost:{server.port}/marker.html?link=1", "destination": "cmux",
        }) or {}
        panel = up(reply.get("new_browser_panel_id"))
        if not panel:
            raise Failure(f"the link click opened no browser in the mirror: {reply}")
        title = self.wait_title(panel, lambda t: t == server.title, "the linked marker page in the mirror")
        route = self.expect_route(self.pair.mirror_id, panel, remote=True)
        return {"link_open": reply, "title": title, "route": route}

    def moved_tab_swaps_route(self) -> Dict[str, Any]:
        self.sock.call("surface.move", {"surface_id": self.require_mirror_browser(), "workspace_id": self.pair.source_id})
        in_source = self.expect_route(self.pair.source_id, self.mirror_browser, remote=False)
        self.sock.call("surface.move", {"surface_id": self.mirror_browser, "workspace_id": self.pair.mirror_id})
        back = self.expect_route(self.pair.mirror_id, self.mirror_browser, remote=True)
        return {"in_source": in_source, "back_in_mirror": back}

    def old_host_page(self) -> Dict[str, Any]:
        assert self.owner_server is not None
        self.require_mirror_browser()
        had_capability = PORT_FORWARD_CAPABILITY in (self.capabilities() or [])
        self.facts["had_port_forward_capability"] = had_capability
        try:
            self.tunnel("pretend_old_host", enabled=True)
            relinked = self.relink(expect_capability=False)
            name = self.pair.device_name
            self.navigate(self.mirror_browser, f"http://localhost:{self.owner_server.port}/marker.html?old=1")
            title = self.wait_title(self.mirror_browser, lambda t: "Supermux" in t and name in t,
                                    "the \"update Supermux\" page")
            return {**relinked, "title": title}
        finally:
            self.tunnel("pretend_old_host", enabled=False)
            self.relink(expect_capability=True if had_capability else None)

    def connect_request(self, proxy: Dict[str, Any], target: str) -> bytes:
        token = base64.b64encode(f"{proxy['username']}:{proxy['password']}".encode()).decode()
        return f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nProxy-Authorization: Basic {token}\r\n\r\n".encode()

    def proxy_client(self, port: int, request: bytes, then: Optional[bytes]) -> Tuple[int, bytes]:
        """One client of the proxy: sends `request` (and `then` once the proxy's
        answer head arrived), reads until the proxy closes, closes. Its port and
        everything it read."""
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=10) as conn:
                conn.settimeout(10)
                client_port = conn.getsockname()[1]
                conn.sendall(request)
                data = b""
                if then is not None:
                    while b"\r\n\r\n" not in data:
                        chunk = conn.recv(4096)
                        if not chunk:
                            break
                        data += chunk
                    conn.sendall(then)
                data += recv_until_closed(conn)
        except OSError as error:
            raise Failure(f"a proxy client on port {port} failed: {error!r}") from error
        return client_port, data

    def proxy_connections_are_released(self) -> Dict[str, Any]:
        """Every proxy connection that ended leaves no socket in the app: the proxy
        cancels each connection it accepted or dialed. Before, a finished one kept
        its file descriptor for the app's lifetime (lsof shows it in TIME_WAIT,
        still the app's)."""
        assert self.owner_server is not None
        proxy = self.require_proxy()
        port = int(proxy["port"])
        pid = listening_pid(port)
        if not pid:
            raise Failure(f"no process listens on the proxy's port {port}")
        closed = free_port()

        def get(target: str) -> bytes:
            return f"GET /marker.html HTTP/1.0\r\nHost: {target}\r\n\r\n".encode()

        owner = f"localhost:{self.owner_server.port}"
        alias = f"{LOOPBACK_ALIAS}:{closed}"
        # (kind, request, request after the answer head, what the answer must contain)
        sessions: List[Tuple[str, bytes, Optional[bytes], bytes]] = [
            ("relayed", self.connect_request(proxy, owner), get(owner), self.owner_server.title.encode()),
            ("refused", b"\x05\x01\x00", None, b"\x05\xff"),
            ("failed", self.connect_request(proxy, f"localhost:{closed}"), None, b"HTTP/1.1 502"),
            ("explained", self.connect_request(proxy, alias), get(alias), b"HTTP/1.1 502"),
        ]
        address = primary_ipv4()
        lan = self.server("released-lan", host=address) if address else None
        if lan and address:
            target = f"{address}:{lan.port}"
            sessions.append(("direct", self.connect_request(proxy, target), get(target), lan.title.encode()))
        clients = set()
        for kind, request, then, expect in sessions:
            for _ in range(5):
                client, answer = self.proxy_client(port, request, then)
                if expect not in answer:
                    raise Failure(f"a {kind} proxy connection read {answer[:80]!r}, want {expect!r}")
                clients.add(client)

        def released() -> Dict[str, Any]:
            held = [c for c in tcp_connections(pid, port) if c[1] in clients]
            dialed = tcp_connections(pid, lan.port) if lan else []
            if held or dialed:
                raise Failure(f"the app still holds {len(held)} of {len(clients)} finished proxy connections "
                              f"and {len(dialed)} direct dials (local, peer ports): {held[:4]} {dialed[:4]}")
            return {"held": 0, "dialed": 0}

        wait_for("the proxy to release every finished connection", released, 10)
        return {"app_pid": pid, "connections": len(clients), "kinds": [s[0] for s in sessions],
                "direct": "skipped (no LAN IPv4)" if not lan else "checked"}

    def store_preview(self, machine: str) -> str:
        reply = self.sock.call("supermux.devices.mirror.browser_store", {"machine": machine}) or {}
        return up(reply.get("store_identifier"))

    def data_store_per_app_instance(self) -> Dict[str, Any]:
        """Two app instances of one Mac (device+tag, the key of their proxies) get
        two data stores: one store's proxy configuration serves every browser on
        it, so a shared store sent one instance's tabs through the other's proxy."""
        machine = self.pair.machine
        sibling = sibling_instance(machine)
        route = self.route(self.pair.mirror_id, self.require_mirror_browser())
        if up(route.get("store_identifier")) != data_store_id(machine):
            raise Failure(f"the mirror browser's data store is {route.get('store_identifier')}, "
                          f"want {machine}'s {data_store_id(machine)}")
        previews = {m: self.store_preview(m) for m in (machine, sibling)}
        for m, preview in previews.items():
            if preview != data_store_id(m):
                raise Failure(f"the route gives {m} the data store {preview or None}, want {data_store_id(m)}")
        if previews[machine] == previews[sibling]:
            raise Failure(f"{machine} and {sibling} share the data store {previews[machine]}")
        return {"stores": previews}

    def unbound_mirror_browser_routes(self) -> Dict[str, Any]:
        """A mirror no binding names (upstream's vm.workspace_open with auto-mirror
        off) gets the ports menu's "Open in cmux Browser" like a bound one, so its
        browser takes the same route."""
        assert self.owner_server is not None
        server = self.owner_server
        source = mirror = ""
        self.sock.call("supermux.devices.set_auto_mirror", {"enabled": False})
        try:
            created = self.sock.call("workspace.create", {"title": f"mirror-browser-unbound-{self.nonce}", "focus": False}) or {}
            source = up(created.get("workspace_id") or created.get("created_workspace_id"))
            if not source:
                raise Failure(f"workspace.create returned no id: {created}")
            wait_for("the new source's terminal", lambda: self.pair.surfaces(source), self.timeout)
            # The device lists a new workspace on its next record refresh; until then upstream answers not_found.
            opened = wait_for("the device to list the new source", lambda: self.sock.call(
                "vm.workspace_open", {"id": self.pair.machine, "workspace_id": source, "focus": False}, timeout_s=60
            ), self.timeout) or {}
            mirror = up(opened.get("workspace_id"))
            if not mirror:
                raise Failure(f"vm.workspace_open opened nothing: {opened}")

            def unbound_row() -> Optional[Dict[str, Any]]:
                rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
                return next((row for row in rows if up(row.get("workspace_id")) == mirror), None)

            row = wait_for("the opened workspace to be a mirror", unbound_row, self.timeout)
            if row.get("is_bound"):
                raise Failure(f"precondition: the opened mirror is bound: {row}")
            terminal = wait_for("the unbound mirror's terminal", lambda: (self.pair.surfaces(mirror) or [None])[0], self.timeout)
            opens_before = self.journal_opens(server.port)
            panel = self.new_tab(mirror, terminal, f"http://localhost:{server.port}/marker.html?unbound=1")
            title = self.wait_title(panel, lambda t: t == server.title, "the marker page in the unbound mirror")
            route = self.expect_route(mirror, panel, remote=True)
            opens = self.journal_opens(server.port)
            if opens <= opens_before:
                raise Failure(f"the owner's tunnel journal has no new `opened` for port {server.port}")
            return {"source": source, "unbound_mirror": mirror, "title": title, "route": route, "journal_opens": opens}
        finally:
            for workspace_id in (mirror, source):
                if workspace_id:
                    try:
                        self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
                    except Failure:
                        pass
            self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True})

    def idle_proxy_connections_close(self) -> Dict[str, Any]:
        """Local clients that connect and send nothing cannot hold the proxy's
        connections: past the limit of clients still in their handshake they are
        closed at once, and every one is closed at the handshake deadline."""
        port = int(self.require_proxy()["port"])
        extra = 8
        conns: List[socket.socket] = []
        closed_after: Dict[int, float] = {}
        try:
            for _ in range(HANDSHAKE_LIMIT + extra):
                conns.append(socket.create_connection(("127.0.0.1", port), timeout=10))
            opened_at = time.monotonic()
            while len(closed_after) < len(conns) and time.monotonic() - opened_at < HANDSHAKE_DEADLINE_S + 5:
                waiting = [conn for index, conn in enumerate(conns) if index not in closed_after]
                readable, _, _ = select.select(waiting, [], [], 0.25)
                for conn in readable:
                    try:
                        ended = not conn.recv(1)
                    except OSError:
                        ended = True
                    if ended:
                        closed_after[conns.index(conn)] = round(time.monotonic() - opened_at, 2)
        except OSError as error:
            raise Failure(f"a client of the proxy on port {port} failed ({len(conns)} connected): {error!r}") from error
        finally:
            for conn in conns:
                conn.close()
        at_once = sum(1 for seconds in closed_after.values() if seconds < 3)
        facts = {"connections": len(conns), "closed": len(closed_after), "closed_at_once": at_once,
                 "last_closed_after": max(closed_after.values(), default=None)}
        if len(closed_after) < len(conns):
            raise Failure(f"{len(conns) - len(closed_after)} of {len(conns)} connections that never sent a byte "
                          f"are still open after {HANDSHAKE_DEADLINE_S + 5:.0f}s: {facts}")
        if at_once < extra:
            raise Failure(f"want at least {extra} connections past the handshake limit closed at once: {facts}")
        return facts

    def proxy_listener_failure_recovers(self) -> Dict[str, Any]:
        """A failed proxy listener is replaced: the mirror's open tab (it held the
        dead endpoint) and a new tab both load through a fresh one."""
        browser = self.require_mirror_browser()
        old = self.require_proxy()
        server = self.server("recover")
        failed = self.sock.call("supermux.devices.mirror.browser_proxy_fail", {"machine": self.pair.machine}) or {}
        if failed.get("failed_port") != old["port"]:
            raise Failure(f"precondition: the driver failed no listener on port {old['port']}: {failed}")
        # No `browser_proxy` read until both tabs loaded: that read starts a listener itself.
        self.navigate(browser, f"http://localhost:{server.port}/marker.html?tab=open")
        open_title = self.wait_title(browser, lambda t: t == server.title, "the open mirror tab to load after the failure")
        panel = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), f"http://localhost:{server.port}/marker.html?tab=new")
        new_title = self.wait_title(panel, lambda t: t == server.title, "a new mirror tab to load after the failure")
        route = self.expect_route(self.pair.mirror_id, panel, remote=True)
        proxy = self.require_proxy()
        if proxy["port"] == old["port"]:
            raise Failure(f"the proxy still reports the failed port {old['port']}")
        if int(proxy.get("owner_dials") or 0) <= int(old.get("owner_dials") or 0):
            raise Failure(f"the proxy never dialed the owner ({old.get('owner_dials')} -> {proxy.get('owner_dials')})")
        return {"failed_port": old["port"], "port": proxy["port"], "open_tab": open_title, "new_tab": new_title,
                "route": route}

    # -- run -------------------------------------------------------------------

    def run(self) -> bool:
        ok = self.step("setup", self.setup)
        if ok:
            # Every later step runs even when an earlier one failed, so a red run
            # reports each missing behavior; they share only the first step's tab.
            for name, check in [
                ("mirror_browser_routes_through_owner", self.routes_through_owner),
                ("literal_127_routes", self.literal_127_routes),
                ("local_workspace_stays_direct", self.local_stays_direct),
                ("non_loopback_goes_direct", self.non_loopback_direct),
                ("closed_port_explains", self.closed_port_explains),
                ("proxy_requires_credential", self.proxy_requires_credential),
                ("terminal_link_opens_routed_browser", self.terminal_link_opens_routed_browser),
                ("moved_tab_swaps_route", self.moved_tab_swaps_route),
                ("old_host_page", self.old_host_page),
                ("proxy_connections_are_released", self.proxy_connections_are_released),
                ("data_store_per_app_instance", self.data_store_per_app_instance),
                ("unbound_mirror_browser_routes", self.unbound_mirror_browser_routes),
                ("idle_proxy_connections_close", self.idle_proxy_connections_close),
                # Last: in a red run the mirror's open tab keeps the dead endpoint.
                ("proxy_listener_failure_recovers", self.proxy_listener_failure_recovers),
            ]:
                ok = self.step(name, check) and ok
        for server in self.servers:
            server.close()
        if not self.keep:
            errors = self.pair.close()
            if errors:
                self.facts["cleanup_errors"] = errors
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    parser.add_argument("--timeout", type=float, default=20.0, help="seconds to wait before a check gives up")
    parser.add_argument("--keep", action="store_true", help="leave the source and mirror open")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path, timeout_s=60)
    try:
        sock.connect()
        test = MirrorBrowserE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-mirror-browser-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_mirror_browser_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
