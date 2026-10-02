#!/usr/bin/env python3
"""End-to-end test: a device mirror's browser opens the owning Mac's localhost.

A browser tab opened in a mirror of another Mac's workspace used to be a plain
browser of THIS Mac: `localhost:3000` there loaded this Mac's server, never the
one running in the mirrored terminal. Now a bound mirror's browsers use
upstream's remote-workspace browser mode: one website data store per remote
Mac, and a per-Mac authenticated SOCKS5/HTTP CONNECT proxy on this Mac's
loopback that sends the owner's loopback hosts through the device link's tunnel
lanes and dials every other host directly. This suite drives one tagged DEBUG
build running the loopback device ("Loopback Mac" = this same app's own mobile
host, whose tunnel host runs in-process), so "the owner's loopback" and this
Mac's are one machine: every check is about the ROUTE (proxy, tunnel opens,
store), not just whether a page loads. Marker servers run in this script, in no
workspace, each on its own port so tunnel opens are attributed exactly:

  1 mirror_browser_routes_through_owner  localhost:P in the mirror loads through the proxy and the owner's
                                         tunnel host (journal `opened` for P), in the device's data store,
                                         and the server sees `Host: localhost:P`
  2 literal_127_routes                   http://127.0.0.1:P2 in the mirror routes the same way
  3 local_workspace_stays_direct         the same kind of URL in the source workspace: no proxy, the
                                         profile store, no tunnel open (control)
  4 non_loopback_goes_direct             this Mac's LAN address in the mirror: dialed directly by the proxy,
                                         no tunnel open (skipped when the Mac has no non-loopback IPv4)
  5 closed_port_explains                 a closed port in the mirror shows the "localhost:N on <Mac> isn't
                                         answering" page
  6 proxy_requires_credential            the proxy refuses SOCKS no-auth (05 FF), a wrong password (01 01)
                                         and CONNECT without credentials (407); the right one connects
  7 terminal_link_opens_routed_browser   a link click in the mirror's terminal (cmux browser) opens a
                                         routed browser in the mirror
  8 moved_tab_swaps_route                the routed browser moved into the source loses the route and
                                         store; moved back, it routes again
  9 old_host_page                        an owner without `supermux.port_forward.v1` gives the "update
                                         Supermux" page

Uses the DEBUG drivers `supermux.devices.mirror.browser_route`, `.browser_proxy`
and `.link_open` (SupermuxMirrorBrowserSocket) and the tunnel driver
`supermux.devices.tunnel` (`journal`, `pretend_old_host`). Writes a JSON report
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
import socket
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

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
        """The tunnel driver; `{action}` form first, `tunnel.<action>` as a fallback."""
        try:
            return self.sock.call("supermux.devices.tunnel", {"action": action, **params}) or {}
        except Failure as error:
            if "method_not_found" not in str(error):
                raise
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

        def check() -> Dict[str, Any]:
            route = self.route(workspace_id, panel_id)
            store = up(route.get("store_identifier"))
            if remote:
                if not route.get("routes_remotely"):
                    raise Failure(f"the browser does not route through the owning Mac: {route}")
                if route.get("proxy_configs") != 2:
                    raise Failure(f"want 2 WebKit proxy configurations (SOCKS5 + CONNECT): {route}")
                if store != up(self.device_id):
                    raise Failure(f"want the remote Mac's data store {self.device_id}: {route}")
            else:
                if route.get("routes_remotely"):
                    raise Failure(f"a local browser routes through the owning Mac: {route}")
                if route.get("proxy_configs") != 0:
                    raise Failure(f"want no proxy configuration (is a system proxy set?): {route}")
                if store == up(self.device_id):
                    raise Failure(f"a local browser uses the remote Mac's data store: {route}")
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
        proxy = self.require_proxy()
        if int(proxy.get("direct_dials") or 0) <= dials_before:
            raise Failure(f"the proxy never dialed {address} directly ({dials_before} -> {proxy.get('direct_dials')})")
        opens = self.journal_opens(server.port)
        if opens:
            raise Failure(f"a LAN request went through the owner's tunnel ({opens} opens)")
        return {"url": url, "title": title, "direct_dials": proxy.get("direct_dials")}

    def closed_port_explains(self) -> Dict[str, Any]:
        closed = free_port()
        name = self.pair.device_name
        self.navigate(self.require_mirror_browser(), f"http://localhost:{closed}/")
        title = self.wait_title(
            self.mirror_browser, lambda t: f"localhost:{closed}" in t and name in t,
            f"the \"localhost:{closed} on {name} isn't answering\" page",
        )
        return {"port": closed, "title": title}

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
        token = base64.b64encode(f"{proxy['username']}:{proxy['password']}".encode()).decode()
        with connect() as conn:
            conn.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nProxy-Authorization: Basic {token}\r\n\r\n".encode())
            established = b""
            while b"\r\n\r\n" not in established:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                established += chunk
            conn.sendall(f"GET /marker.html HTTP/1.0\r\nHost: {target}\r\n\r\n".encode())
            page = recv_until_closed(conn).decode(errors="replace")
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
