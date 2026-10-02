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
 5b typed_navigations_are_prompt        URLs typed into the open mirror tab, to owner ports forwarded here on
                                         the same port, each show the owner's page within 3 s, 6 times (through
                                         the alias each waited ~10.5 s on WebKit's hardened-process swap)
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
                                         auto-mirror off) loads the owner's page like a bound one's
 13 idle_proxy_connections_close         connections that never send a byte are closed: the ones past the
                                         limit of clients still in their handshake at once, the rest at the
                                         handshake deadline
 14 owner_localhost_keeps_origin        a Cloudflare Turnstile login page on the owner's localhost:P, P listed as
                                         the source workspace's port and so forwarded here on P: the mirror
                                         tab runs at http://localhost:P (a secure context, the hostname a dev
                                         sitekey allows), not the alias, and
                                         Turnstile hands it a token (test sitekey; a local browser on the
                                         same page is the control). Loopback: the owner serves P from
                                         another port (`tunnel.serve_port`), so P is free here
 15 as_written_page_reaches_owner_ports  an as-written mirror page's fetch and XHR to localhost:Q, where this Mac
                                         runs its own server on Q, reach the owner's Q (alias route, CORS intact)
                                         and never this Mac's server
 16 forward_changes_reroute_open_tab     a mirror tab opened before its port's forward is active moves to
                                         http://localhost:P once it is; when the forward stops and this Mac
                                         serves P itself, the tab goes back through the alias and a reload
                                         still shows the owner's page
 17 unlisted_forward_explains            a forward of a port the owner does not list is not loaded as written:
                                         the proxy's "isn't answering" page, not a bare connection error
 17b bypass_browser_stays_local          a browser opened in the mirror with bypass_remote_proxy loads this Mac's
                                         page (no reroute loop, not the mirror's store) and the other mirror
                                         tabs keep routing through the owner
 17c as_written_page_navigation_reroutes an as-written page's own navigation to localhost:Q (this Mac serves Q)
                                         shows the owner's Q (the #756 navigation policy), never this Mac's
 17d public_page_gets_no_ports           a non-loopback mirror page that defines the bridge's setter is handed
                                         no ports when the forwards change
 17e same_origin_iframe_reaches_owner    a same-origin iframe's fetch to localhost:Q reaches the owner's Q
 18 proxy_listener_failure_recovers      after the proxy's listener fails, it is replaced on its own (waited
                                         for with a read that starts no listener); then the open mirror tab
                                         and a new one each load the owner's page on the fresh endpoint,
                                         never this Mac's own server on the same port
 19 restart_keeps_mirror_store_proxied   a mirror tab opened while the failed listener is being replaced
                                         (held down by `browser_proxy_hold`) leaves the app instance's
                                         data store with its proxy (2 configurations, as the open tab's);
                                         a load while it is down fails and reaches nothing; once released,
                                         that tab loads the owner's page

Steps 12, 15, 18 and 19 run this Mac's own server on the port they open and the
owner's page on another port that the loopback owner serves as that port
(`owner_and_this_mac`), as on two Macs: a page with the owner's title came
through the owner, and a request to this Mac's server means a load went direct.

Uses the DEBUG drivers `supermux.devices.mirror.browser_route`, `.browser_proxy`,
`.browser_proxy_fail`, `.browser_proxy_hold`, `.browser_store` and `.link_open`
(SupermuxMirrorBrowserSocket) and the tunnel driver
`supermux.devices.tunnel.journal`, `.pretend_old_host` and `.serve_port`, and the
port-forward drivers `supermux.devices.ports.forward`, `.list` and `.stop`. Step
16 needs challenges.cloudflare.com. Writes a JSON report
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
import random
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
# URLs typed into the open mirror tab, and how long each may take to show the
# owner's page (the owner answers at once; a new tab takes ~0.15 s).
TYPED_NAVIGATIONS = 6
TYPED_NAVIGATION_S = 3.0
# Cloudflare's dummy Turnstile sitekey that always passes (meant for automated
# tests; it works on any hostname). A real sitekey also checks the page's
# hostname against its allowlist, which for a dev app lists `localhost`.
TURNSTILE_TEST_SITEKEY = "1x00000000000000000000AA"
# How long Turnstile (challenges.cloudflare.com) may take to hand a token.
TURNSTILE_TOKEN_S = 45.0
# What the page reports about itself and its Turnstile widget.
TURNSTILE_PROBE = """JSON.stringify({origin: location.origin, hostname: location.hostname,
  secure: window.isSecureContext, subtle: !!(window.crypto && window.crypto.subtle),
  turnstile: window.__turnstile || null})"""


def turnstile_page(title: str) -> str:
    """A login-like page with an explicitly rendered Turnstile widget that records
    its outcome in `window.__turnstile` (state: loading, rendered, token, error,
    unsupported, threw)."""
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{title}</title>
<script>
window.__turnstile = {{state: "loading"}};
window.onTurnstileLoad = function () {{
  try {{
    turnstile.render("#widget", {{
      sitekey: "{TURNSTILE_TEST_SITEKEY}",
      callback: function (token) {{ window.__turnstile = {{state: "token", length: token.length}}; }},
      "error-callback": function (code) {{ window.__turnstile = {{state: "error", code: String(code)}}; return true; }},
      "unsupported-callback": function () {{ window.__turnstile = {{state: "unsupported"}}; }}
    }});
    if (window.__turnstile.state === "loading") window.__turnstile = {{state: "rendered"}};
  }} catch (error) {{ window.__turnstile = {{state: "threw", error: String(error)}}; }}
}};
</script>
<script src="https://challenges.cloudflare.com/turnstile/v0/api.js?onload=onTurnstileLoad&render=explicit" async defer></script>
</head><body><form><h1>{title}</h1><div id="widget"></div></form></body></html>
"""


class MarkerServer:
    """A threaded HTTP server for one step: a marker page and every request's headers."""

    def __init__(self, host: str, title: str, body: Optional[str] = None, port: int = 0) -> None:
        self.title = title
        self.hits: List[Dict[str, Any]] = []
        page = (body or f"<html><head><title>{title}</title></head><body>{title}</body></html>").encode()
        hits = self.hits

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 (http.server API)
                origin = self.headers.get("Origin")
                hits.append({"path": self.path, "host": self.headers.get("Host"), "client": self.client_address[0],
                             "origin": origin})
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                if origin:
                    # As a dev API that allows the page's origin does.
                    self.send_header("Access-Control-Allow-Origin", origin)
                self.send_header("Content-Length", str(len(page)))
                self.end_headers()
                self.wfile.write(page)

            def log_message(self, *_: Any) -> None:
                pass

        self.server = http.server.ThreadingHTTPServer((host, port), Handler)
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


def free_dev_port() -> int:
    """A port free on both loopback addresses below the ephemeral range, as a dev
    server's is: an ephemeral port can be taken meanwhile as the local port of any
    outgoing connection (the page's own loads), and a forward then lands elsewhere."""
    for _ in range(200):
        port = random.randint(20000, 40000)
        try:
            for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
                with socket.socket(family, socket.SOCK_STREAM) as probe:
                    probe.bind((host, port))
        except OSError:
            continue
        return port
    raise Failure("precondition: no free port in 20000-40000")


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
        # Ports the loopback owner serves from another port (`tunnel.serve_port`).
        self.served_ports: List[int] = []
        # Owner ports this suite forwarded here by hand (stopped at the end).
        self.forwarded_ports: List[int] = []
        # Whether a step listed ports as the source's (`tunnel.inject_port`, cleared at the end).
        self.injected = False

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

    def proxy(self, start: bool = True) -> Optional[Dict[str, Any]]:
        """The endpoint the mirror browser proxy hands out now; `start=False` reads
        without starting a listener (one that restarts on its own can be waited for)."""
        reply = self.sock.call("supermux.devices.mirror.browser_proxy", {"machine": self.pair.machine, "start": start}) or {}
        return reply.get("proxy") or None

    def hold_proxy(self, held: bool) -> None:
        """While held the proxy makes no new listener, so a failed one stays down."""
        reply = self.sock.call("supermux.devices.mirror.browser_proxy_hold", {"machine": self.pair.machine, "held": held}) or {}
        if reply.get("held") is None:
            raise Failure(f"precondition: no browser proxy to hold for the loopback Mac: {reply}")

    def wait_replacement(self, failed_port: int) -> Dict[str, Any]:
        """The listener that replaces the one on `failed_port`, waited for without starting one."""
        def replaced() -> Dict[str, Any]:
            proxy = self.proxy(start=False)
            if not proxy or proxy.get("port") == failed_port:
                raise Failure(f"the proxy hands out {proxy and proxy.get('port')}")
            return proxy

        return wait_for(f"a listener to replace the failed one on port {failed_port}", replaced, self.timeout)

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

    def navigate_open_tab(self, surface_id: str, url: str) -> None:
        """`navigate` for a tab that already shows a page, to the localhost alias.
        WebKit 27 moves such a navigation (plain HTTP to a host that is not
        loopback by name) into a new hardened WebContent process, and making one
        blocks its UI thread ~10 s on an affected host (LOOPBACK-HARNESS.md).
        That can outlast browser.navigate's own 17.5 s wait, so its timeout is not
        the verdict: the page the caller then waits for is."""
        try:
            self.navigate(surface_id, url)
        except Failure as error:
            if "navigation_timeout" not in str(error):
                raise

    def owner_and_this_mac(self, label: str) -> Tuple[MarkerServer, MarkerServer]:
        """Two servers for one `localhost:P`, as on two Macs: this Mac's own listens
        on P; the owner's runs on another port that the loopback owner serves as P
        (`tunnel.serve_port`). A page with the owner's title came through the owner;
        a request this Mac's server sees went direct. Unlike a count of the owner's
        tunnel opens, this holds for every request, also one that rides a tunnel
        opened earlier: WebKit opens one it sends nothing on for a navigation, and
        may send a later request on it."""
        owner = self.server(f"{label}-owner")
        here = self.server(f"{label}-this-mac")
        self.tunnel("serve_port", port=here.port, **{"from": owner.port})
        self.served_ports.append(here.port)
        return owner, here

    def wait_owner_page(self, surface_id: str, owner: MarkerServer, here: MarkerServer, what: str) -> str:
        """Waits for either server's page; fails at once on this Mac's."""
        title = self.wait_title(surface_id, lambda t: t in (owner.title, here.title), what)
        if title != owner.title or here.hits:
            raise Failure(f"{what}: this Mac's own localhost:{here.port} answered (title {title!r}, "
                          f"its server saw {here.hits}), not the owner's")
        return title

    def require_owner_hosts(self, owner: MarkerServer, port: int) -> List[str]:
        """Every page request reached the owner as `Host: localhost:<port>`: the
        proxy's alias route rewrote it (a direct load of the alias keeps its name)."""
        hosts = owner.marker_hosts()
        if not hosts or any(host != f"localhost:{port}" for host in hosts):
            raise Failure(f"the owner saw Host {hosts}, want localhost:{port} for each request")
        return hosts

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

    def owner_page_forwarded_here(self, label: str, body: Optional[Callable[[str], str]] = None) -> Tuple[MarkerServer, int]:
        """An owner page at the owner's localhost:P, listed as the source
        workspace's port (`tunnel.inject_port`, as a dev server in its terminal
        is) and so forwarded to this Mac on P itself by automatic forwarding
        (P is free here). The loopback owner serves P from the page server's own
        port (`tunnel.serve_port`), so only the forward, through the owner,
        answers on P here."""
        owner = MarkerServer("127.0.0.1", f"marker-{self.nonce}-{label}", body=body(f"marker-{self.nonce}-{label}") if body else None)
        self.servers.append(owner)
        port = free_dev_port()
        self.serve_owner_port(port, owner.port)
        self.list_owner_port(port)
        row = self.wait_forward(port)
        if int(row.get("local_port") or 0) != port:
            raise Failure(f"precondition: the forward listens on {row.get('local_port')}, not on {port}: {row}")
        return owner, port

    def serve_owner_port(self, port: int, source: int) -> None:
        """The loopback owner serves its `port` from this machine's `source`."""
        self.tunnel("serve_port", port=port, **{"from": source})
        self.served_ports.append(port)

    def list_owner_port(self, port: int) -> None:
        """The owner lists `port` as the source workspace's (automatic forwarding on)."""
        self.sock.call("supermux.devices.ports.set_auto", {"enabled": True})
        self.tunnel("inject_port", workspace_id=self.pair.source_id, port=port)
        self.injected = True
        self.sock.call("supermux.devices.ports.refresh", {"machine": self.pair.machine})

    def wait_forward(self, port: int, active: bool = True) -> Dict[str, Any]:
        def state() -> Dict[str, Any]:
            rows = (self.sock.call("supermux.devices.ports.list", {"machine": self.pair.machine}) or {}).get("forwards") or []
            row = next((r for r in rows if int(r.get("remote_port") or 0) == port), None)
            if active != bool(row and row.get("state") == "active"):
                raise Failure(f"forward {row}")
            return row or {"remote_port": port, "state": "gone"}

        return wait_for(f"the owner's {port} to be {'forwarded' if active else 'not forwarded'} here", state, self.timeout)

    def page_href(self, surface_id: str) -> str:
        return str((self.sock.call("browser.eval", {"surface_id": surface_id, "script": "location.href"}) or {}).get("value") or "")

    def typed_navigations_are_prompt(self) -> Dict[str, Any]:
        """URLs typed into the open mirror tab, each to an owner port forwarded
        here on the same port, show the owner's page within TYPED_NAVIGATION_S,
        TYPED_NAVIGATIONS times. Through the localhost alias each took 10.5-11 s:
        WebKit 27 moves a typed navigation to plain HTTP on a host that is not
        loopback by name into a new hardened WebContent process, and making one
        blocks its UI thread ~10 s here (issuing font sandbox extensions); a
        local tab typed to the alias or a LAN address waits as long, no proxy
        involved. Loaded as written (#754), the page is http://localhost:P."""
        browser = self.require_mirror_browser()
        owner, port = self.owner_page_forwarded_here("typed-0")
        self.navigate_open_tab(browser, f"http://localhost:{port}/marker.html")
        self.wait_title(browser, lambda t: t == owner.title, "the open mirror tab to show an owner page")
        timings: List[float] = []
        for index in range(1, TYPED_NAVIGATIONS + 1):
            owner, port = self.owner_page_forwarded_here(f"typed-{index}")
            url = f"http://localhost:{port}/marker.html?typed={index}"
            started = time.monotonic()
            self.navigate_open_tab(browser, url)
            self.wait_title(browser, lambda t: t == owner.title, f"typed navigation {index}")
            timings.append(round(time.monotonic() - started, 2))
        page = str((self.sock.call("browser.eval", {"surface_id": browser, "script": "location.href"}) or {}).get("value") or "")
        slow = [seconds for seconds in timings if seconds > TYPED_NAVIGATION_S]
        if slow:
            raise Failure(f"{len(slow)} of {len(timings)} typed navigations took over {TYPED_NAVIGATION_S:.0f}s "
                          f"(seconds {timings}; the last page ran at {page})")
        return {"navigation_seconds": timings, "last_page": page}

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
            self.navigate_open_tab(self.mirror_browser, f"http://localhost:{self.owner_server.port}/marker.html?old=1")
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
        owner, here = self.owner_and_this_mac("unbound")
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
            panel = self.new_tab(mirror, terminal, f"http://localhost:{here.port}/marker.html?unbound=1")
            title = self.wait_owner_page(panel, owner, here, "the marker page in the unbound mirror")
            route = self.expect_route(mirror, panel, remote=True)
            hosts = self.require_owner_hosts(owner, here.port)
            return {"source": source, "unbound_mirror": mirror, "title": title, "route": route, "hosts": hosts}
        finally:
            for workspace_id in (mirror, source):
                if workspace_id:
                    try:
                        self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
                    except Failure:
                        pass
            self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True})

    def turnstile_probe(self, surface_id: str) -> Dict[str, Any]:
        reply = self.sock.call("browser.eval", {"surface_id": surface_id, "script": TURNSTILE_PROBE}) or {}
        try:
            return json.loads(reply.get("value") or "{}")
        except (TypeError, ValueError):
            raise Failure(f"the page's probe returned {reply.get('value')!r}")

    def wait_turnstile_token(self, surface_id: str, where: str) -> Dict[str, Any]:
        def token() -> Dict[str, Any]:
            probe = self.turnstile_probe(surface_id)
            if (probe.get("turnstile") or {}).get("state") != "token":
                raise Failure(f"{probe}")
            return probe

        return wait_for(f"Turnstile to hand {where} a token", token, TURNSTILE_TOKEN_S, interval_s=0.5)

    def owner_localhost_keeps_origin(self) -> Dict[str, Any]:
        """The user's case: a dev app's login page with a Cloudflare Turnstile
        widget, served on the owning Mac's localhost:P and opened in the mirror.
        P is forwarded to this Mac on P itself (port forwarding does that for a
        server in a mirrored terminal whenever P is free here), so the mirror tab
        must run at the page's own origin, http://localhost:P: a secure context,
        and the hostname a real sitekey's allowlist names. Before the fix the
        mirror loaded upstream's alias, http://cmux-loopback.localtest.me:P, an
        insecure origin whose hostname no sitekey allows (Turnstile 110200,
        "Domain not authorized": no widget, no login). In loopback both "Macs"
        share one port space, so the owner serves P from another port Q
        (`tunnel.serve_port`), leaving P free here as on two Macs. A local
        browser on the same page is the control that Turnstile itself works."""
        tabs: List[str] = []
        try:
            server, owner_port = self.owner_page_forwarded_here("turnstile", body=turnstile_page)
            title = server.title
            local = self.new_tab(self.pair.source_id, self.source_terminal, f"http://localhost:{server.port}/login")
            tabs.append(local)
            self.wait_title(local, lambda t: t == title, "the Turnstile page in a local browser")
            try:
                control = self.wait_turnstile_token(local, "a local browser")
            except Failure as error:
                raise Failure(f"precondition: Turnstile hands no token in a local cmux browser either "
                              f"(is challenges.cloudflare.com reachable?): {error}")
            opens_before = self.journal_opens(owner_port)
            url = f"http://localhost:{owner_port}/login"
            panel = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), url)
            tabs.append(panel)
            self.wait_title(panel, lambda t: t == title, "the owner's Turnstile page in the mirror")
            route = self.expect_route(self.pair.mirror_id, panel, remote=True)
            opens = self.journal_opens(owner_port)
            if opens <= opens_before:
                raise Failure(f"the page did not come from the owner (journal `opened` for {owner_port}: "
                              f"{opens_before} -> {opens})")
            probe = self.turnstile_probe(panel)
            want = f"http://localhost:{owner_port}"
            if probe.get("origin") != want or probe.get("secure") is not True:
                raise Failure(f"the mirror tab runs at {probe.get('origin')} (secure context: {probe.get('secure')}, "
                              f"crypto.subtle: {probe.get('subtle')}), want {want}, a secure context: Turnstile "
                              f"checks a real sitekey against hostname {probe.get('hostname')!r}, which no dev "
                              f"sitekey allows (110200); probe {probe}")
            mirrored = self.wait_turnstile_token(panel, "the mirror tab")
            return {"owner_port": owner_port, "served_from": server.port, "route": route,
                    "journal_opens": opens, "hosts": [hit.get("host") for hit in server.hits],
                    "local_probe": control, "mirror_probe": mirrored}
        finally:
            for tab in tabs:
                try:
                    self.sock.call("surface.close", {"surface_id": tab})
                except Failure:
                    pass

    def page_fetch(self, surface_id: str, url: str, how: str = "fetch") -> str:
        """The page's own `fetch` (or XHR) of `url`: its text, or `err:` and why."""
        key = f"__cmuxE2E{uuid.uuid4().hex[:8]}"
        if how == "fetch":
            start = (f"window.{key} = 'pending'; fetch({json.dumps(url)}).then(r => r.text())"
                     f".then(t => window.{key} = 'ok:' + t, e => window.{key} = 'err:' + e); true")
        else:
            start = (f"window.{key} = 'pending'; const x = new XMLHttpRequest(); x.open('GET', {json.dumps(url)});"
                     f" x.onload = () => window.{key} = 'ok:' + x.responseText;"
                     f" x.onerror = () => window.{key} = 'err:xhr'; x.send(); true")
        self.sock.call("browser.eval", {"surface_id": surface_id, "script": start})

        def settled() -> str:
            value = str((self.sock.call("browser.eval", {"surface_id": surface_id, "script": f"String(window.{key})"}) or {}).get("value"))
            if value == "pending":
                raise Failure("pending")
            return value

        return wait_for(f"the page's {how} of {url}", settled, self.timeout)

    def as_written_page_reaches_owner_ports(self) -> Dict[str, Any]:
        """A mirror page loaded as written (http://localhost:P, P forwarded here
        on P) that calls the owner's API on another port Q: the call reaches the
        owner and never this Mac's own server on Q, with CORS intact. This Mac
        runs its own server on Q (so Q cannot be forwarded here, as a Postgres or
        Supabase this Mac also runs); the loopback owner serves its Q from
        another port. Before, upstream's bridge stood aside on a page not on the
        alias, so `fetch('http://localhost:Q')` went to this Mac's Q with the
        page's cookies; and through the alias the proxy rewrote the API's
        `Access-Control-Allow-Origin: http://localhost:P` to the alias, which the
        page refused. A call to an owner port forwarded here on the same port
        goes to that forward as written."""
        page, port = self.owner_page_forwarded_here("cross-page")
        other, other_port = self.owner_page_forwarded_here("cross-forwarded")
        owner_api, here_api = self.owner_and_this_mac("cross-api")
        tab = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), f"http://localhost:{port}/marker.html")
        try:
            self.wait_title(tab, lambda t: t == page.title, "the as-written owner page in the mirror")
            href = self.page_href(tab)
            if not href.startswith(f"http://localhost:{port}/"):
                raise Failure(f"precondition: the page runs at {href}, not as written")
            api = f"http://localhost:{here_api.port}/api"
            results = {how: self.page_fetch(tab, api, how) for how in ("fetch", "xhr")}
            wrong = {how: value for how, value in results.items()
                     if not value.startswith("ok:") or owner_api.title not in value}
            if here_api.hits or wrong:
                raise Failure(f"the page's calls to localhost:{here_api.port} did not reach the owner: {wrong or results}; "
                              f"this Mac's own server on that port saw {here_api.hits}")
            origins = sorted({str(hit.get("origin")) for hit in owner_api.hits})
            if origins != [f"http://localhost:{port}"]:
                raise Failure(f"the owner's API saw Origin {origins}, want http://localhost:{port}")
            # A port forwarded here on the same port is called as written (its
            # forward, with the page's localhost cookies), not through the proxy.
            dials_before = int(self.require_proxy().get("owner_dials") or 0)
            forwarded = self.page_fetch(tab, f"http://localhost:{other_port}/api")
            dials = int(self.require_proxy().get("owner_dials") or 0) - dials_before
            if not forwarded.startswith("ok:") or other.title not in forwarded or dials:
                raise Failure(f"the page's call to the forwarded localhost:{other_port} got {forwarded[:60]!r} with "
                              f"{dials} proxy dials to the owner, want the owner's page through its forward and none")
            return {"page": href, "api_port": here_api.port, "results": {k: v[:40] for k, v in results.items()},
                    "owner_api_hits": owner_api.hits, "forwarded_port": other_port, "forwarded_hits": other.hits}
        finally:
            self.sock.call("surface.close", {"surface_id": tab})

    def forward_changes_reroute_open_tab(self) -> Dict[str, Any]:
        """A mirror tab follows its port's forward. Opened before the forward is
        active (a link the dev server prints, a restored tab) it loads through
        the alias, and moves to http://localhost:P once the forward is active;
        when the forward stops and this Mac starts its own server on P, the tab
        goes back through the alias, and a reload still shows the owner's page,
        never this Mac's. Before, the route was decided once per typed
        navigation: the first tab stayed on the alias, the second reloaded this
        Mac's localhost:P."""
        owner = self.server("reroute")
        port = free_dev_port()
        self.serve_owner_port(port, owner.port)
        tab = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), f"http://localhost:{port}/marker.html")
        here: Optional[MarkerServer] = None
        try:
            self.wait_title(tab, lambda t: t == owner.title, "the owner page before its forward exists")
            before = self.page_href(tab)
            if LOOPBACK_ALIAS not in before:
                raise Failure(f"precondition: with no forward the tab runs at {before}, not the alias")
            self.list_owner_port(port)
            self.wait_forward(port)

            def at(prefix: str) -> str:
                href = self.page_href(tab)
                if not href.startswith(prefix):
                    raise Failure(f"the tab runs at {href}")
                return href

            forwarded = wait_for(f"the tab to move to localhost:{port} once its forward is active",
                                 lambda: at(f"http://localhost:{port}/"), self.timeout)
            self.sock.call("supermux.devices.ports.stop", {"machine": self.pair.machine, "port": port})
            self.wait_forward(port, active=False)
            here = wait_for(f"this Mac's own server to take {port}", lambda: self.bind_here(port), self.timeout)
            back = wait_for("the tab to go back through the alias once the forward stopped",
                            lambda: at(f"http://{LOOPBACK_ALIAS}:{port}/"), self.timeout)
            self.sock.call("browser.eval", {"surface_id": tab, "script": "location.reload(); true"})
            time.sleep(1.0)
            self.wait_owner_page(tab, owner, here, "the reloaded tab")
            return {"before_forward": before, "forwarded": forwarded, "after_stop": back, "this_mac_hits": here.hits}
        finally:
            self.sock.call("surface.close", {"surface_id": tab})
            if here:
                here.close()

    def bind_here(self, port: int) -> Optional[MarkerServer]:
        """This Mac's own server on `port`, once nothing holds it (None meanwhile)."""
        try:
            server = MarkerServer("127.0.0.1", f"marker-{self.nonce}-this-mac-{port}", port=port)
        except OSError:
            return None
        return server

    def unlisted_forward_explains(self) -> Dict[str, Any]:
        """A forward of a port the owner does not list (a manual one; nothing
        serves it there) is not loaded as written: the tab goes through the
        alias, whose proxy says "localhost:P on <Mac> isn't answering". Before,
        the page loaded as written and WebKit showed a bare connection error."""
        port, closed = free_dev_port(), free_port()
        self.serve_owner_port(port, closed)
        self.sock.call("supermux.devices.ports.forward", {"machine": self.pair.machine, "port": port})
        self.forwarded_ports.append(port)
        row = self.wait_forward(port)
        if int(row.get("local_port") or 0) != port:
            raise Failure(f"precondition: the forward listens on {row.get('local_port')}, not on {port}")
        name = self.pair.device_name
        tab = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), f"http://localhost:{port}/")
        try:
            title = self.wait_title(tab, lambda t: f"localhost:{port}" in t and name in t,
                                    f"the \"localhost:{port} on {name} isn't answering\" page")
            return {"port": port, "title": title, "page": self.page_href(tab)}
        finally:
            self.sock.call("surface.close", {"surface_id": tab})

    def bypass_browser_stays_local(self) -> Dict[str, Any]:
        """A browser opened in the mirror with `bypass_remote_proxy` (the http
        diff viewer, a `local`-context split) is a local browser: it loads this
        Mac's localhost page, and the mirror's other tabs keep routing through
        the owner. Before, it got the mirror's data store with no proxy endpoint:
        every main-frame navigation to a loopback URL was rerouted to the panel,
        which handed it back unchanged, forever; and its init wrote this Mac's
        system proxies (none: no configuration) onto the store every mirror tab
        of that Mac shares, so their alias loads went nowhere."""
        here = self.server("bypass-here")
        reply = self.sock.call("browser.open_split", {
            "workspace_id": self.pair.mirror_id, "surface_id": self.mirror_terminal(),
            "url": f"http://localhost:{here.port}/marker.html", "bypass_remote_proxy": True,
        }) or {}
        panel = up(reply.get("surface_id"))
        if not panel:
            raise Failure(f"browser.open_split opened no browser: {reply}")
        try:
            # The open mirror tab, beside it, keeps the store's proxy (no new tab
            # re-applies it first) and still loads the owner's page.
            mirror_route = self.expect_route(self.pair.mirror_id, self.require_mirror_browser(), remote=True)
            owner, this_mac = self.owner_and_this_mac("bypass-owner")
            self.navigate_open_tab(self.mirror_browser, f"http://localhost:{this_mac.port}/marker.html")
            self.wait_owner_page(self.mirror_browser, owner, this_mac, "the open mirror tab beside the bypassing browser")
            title = self.wait_title(panel, lambda t: t == here.title, "the bypassing browser to load this Mac's page")
            route = self.route(self.pair.mirror_id, panel)
            if route.get("routes_remotely") or up(route.get("store_identifier")) == data_store_id(self.pair.machine):
                raise Failure(f"the bypassing browser routes like a mirror tab: {route}")
            return {"title": title, "bypass_route": route, "mirror_route": mirror_route, "hits_here": len(here.hits)}
        finally:
            self.sock.call("surface.close", {"surface_id": panel})

    def as_written_page_navigation_reroutes(self) -> Dict[str, Any]:
        """A page loaded as written that navigates itself to another loopback port
        (`location.href = 'http://localhost:Q/'`, Q neither forwarded nor listed;
        this Mac serves its own Q) shows the owner's Q, never this Mac's: the
        navigation policy (#756) hands the main-frame navigation back to the
        panel, which sends it through the alias. Without that fence WebKit loads
        the loopback URL itself, straight to this Mac's Q (it never asks a proxy
        for a loopback host), and the step sees this Mac's page."""
        page, port = self.owner_page_forwarded_here("self-nav")
        owner, here = self.owner_and_this_mac("self-nav-target")
        tab = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), f"http://localhost:{port}/marker.html")
        try:
            self.wait_title(tab, lambda t: t == page.title, "the as-written page")
            if not self.page_href(tab).startswith(f"http://localhost:{port}/"):
                raise Failure(f"precondition: the page is not loaded as written ({self.page_href(tab)})")
            target = f"http://localhost:{here.port}/marker.html?self=1"
            self.sock.call("browser.eval", {"surface_id": tab, "script": f"location.href = {json.dumps(target)}; true"})
            title = self.wait_owner_page(tab, owner, here, "the page's own navigation to another loopback port")
            return {"from": f"localhost:{port}", "to": target, "title": title, "page": self.page_href(tab)}
        finally:
            self.sock.call("surface.close", {"surface_id": tab})

    def public_page_gets_no_ports(self) -> Dict[str, Any]:
        """A mirror page that is not on a loopback host cannot learn the owner's
        as-written ports: it defines the bridge's setter itself, and a change of
        the forwards (a new listed, forwarded port) hands it nothing. Before,
        every mirror tab's page world was called with the ports."""
        owner, here = self.owner_and_this_mac("no-ports")
        tab = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), f"http://localhost:{here.port}/marker.html")
        try:
            self.wait_owner_page(tab, owner, here, "an alias page in the mirror")
            if LOOPBACK_ALIAS not in self.page_href(tab):
                raise Failure(f"precondition: the page is not on the alias ({self.page_href(tab)})")
            self.sock.call("browser.eval", {"surface_id": tab, "script":
                "window.__cmuxE2ELeak = null; window.__cmuxSetMirrorLoopbackPorts = (p) => { window.__cmuxE2ELeak = p; }; true"})
            _, forwarded = self.owner_page_forwarded_here("no-ports-new")

            def delivered() -> str:
                value = str((self.sock.call("browser.eval", {"surface_id": tab, "script":
                    "JSON.stringify(window.__cmuxE2ELeak)"}) or {}).get("value"))
                if value in ("null", "None", ""):
                    raise Failure("nothing handed yet")
                return value

            try:
                leak = wait_for("the forwards change to reach the page", delivered, 3.0)
            except Failure:
                return {"page": self.page_href(tab), "new_forward": forwarded, "leaked": None}
            raise Failure(f"a page on {self.page_href(tab)} was handed the owner's as-written ports: {leak}")
        finally:
            self.sock.call("surface.close", {"surface_id": tab})

    def same_origin_iframe_reaches_owner(self) -> Dict[str, Any]:
        """A same-origin iframe of an as-written page (localhost:P inside
        localhost:P) calls the owner's other port Q like its parent: the owner
        answers, never this Mac's own server on Q. Before, the bridge ran in the
        main frame only, so the iframe's own `fetch` went to this Mac."""
        body = (lambda title: f"<html><head><title>{title}</title></head><body>{title}<script>"
                "if (window === window.top) { const f = document.createElement('iframe'); f.src = '/frame.html';"
                " document.body.appendChild(f); }</script></body></html>")
        page, port = self.owner_page_forwarded_here("iframe-page", body=body)
        owner_api, here_api = self.owner_and_this_mac("iframe-api")
        tab = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), f"http://localhost:{port}/marker.html")
        try:
            self.wait_title(tab, lambda t: t == page.title, "the as-written page with its iframe")
            key = f"__cmuxE2E{uuid.uuid4().hex[:8]}"
            api = f"http://localhost:{here_api.port}/api"
            script = (f"(() => {{ const w = document.querySelector('iframe').contentWindow; window.{key} = 'pending';"
                      f" w.fetch({json.dumps(api)}).then(r => r.text()).then(t => window.{key} = 'ok:' + t,"
                      f" e => window.{key} = 'err:' + e); return true; }})()")

            def framed() -> bool:
                ready = (self.sock.call("browser.eval", {"surface_id": tab, "script":
                    "(() => { const f = document.querySelector('iframe'); return !!(f && f.contentDocument && "
                    "f.contentDocument.readyState === 'complete'); })()"}) or {}).get("value")
                if ready is not True:
                    raise Failure("iframe not loaded")
                return True

            wait_for("the same-origin iframe to load", framed, self.timeout)
            self.sock.call("browser.eval", {"surface_id": tab, "script": script})

            def settled() -> str:
                value = str((self.sock.call("browser.eval", {"surface_id": tab, "script": f"String(window.{key})"}) or {}).get("value"))
                if value == "pending":
                    raise Failure("pending")
                return value

            result = wait_for("the iframe's fetch", settled, self.timeout)
            if here_api.hits or not result.startswith("ok:") or owner_api.title not in result:
                raise Failure(f"the iframe's call to localhost:{here_api.port} did not reach the owner: {result[:80]!r}; "
                              f"this Mac's own server on that port saw {here_api.hits}")
            return {"result": result[:40], "owner_api_hits": owner_api.hits}
        finally:
            self.sock.call("surface.close", {"surface_id": tab})

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
        """A failed proxy listener is replaced on its own, and the mirror's open tab
        (it held the dead endpoint) and a new tab each load the owner's page on the
        fresh one. The replacement is waited for with a read that starts no listener
        (`start=False`), so the open tab never navigates inside the restart delay,
        whatever WebKit's speed; with no restart the wait times out. This Mac runs
        its own server on the same port (`owner_and_this_mac`), so a load that went
        direct shows this Mac's page and fails the step whatever tunnels were open.
        (It used to count the owner's tunnel opens instead: a new tab whose request
        rode a tunnel WebKit had opened during the open tab's load counted none.)"""
        browser = self.require_mirror_browser()
        old = self.require_proxy()
        owner, here = self.owner_and_this_mac("recover")
        failed = self.sock.call("supermux.devices.mirror.browser_proxy_fail", {"machine": self.pair.machine}) or {}
        if failed.get("failed_port") != old["port"]:
            raise Failure(f"precondition: the driver failed no listener on port {old['port']}: {failed}")
        fresh = self.wait_replacement(old["port"])
        url = f"http://localhost:{here.port}/marker.html"
        self.navigate_open_tab(browser, url + "?tab=open")
        open_title = self.wait_owner_page(browser, owner, here, "the open mirror tab to load after the failure")
        panel = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), url + "?tab=new")
        new_title = self.wait_owner_page(panel, owner, here, "a new mirror tab to load after the failure")
        route = self.expect_route(self.pair.mirror_id, panel, remote=True)
        hosts = self.require_owner_hosts(owner, here.port)
        proxy = self.require_proxy()
        if int(proxy.get("owner_dials") or 0) <= int(old.get("owner_dials") or 0):
            raise Failure(f"the proxy never dialed the owner ({old.get('owner_dials')} -> {proxy.get('owner_dials')})")
        return {"failed_port": old["port"], "port": fresh["port"], "open_tab": open_title, "new_tab": new_title,
                "hosts": hosts, "owner_dials": proxy.get("owner_dials"), "route": route}

    def restart_keeps_mirror_store_proxied(self) -> Dict[str, Any]:
        """A mirror tab opened while a failed proxy listener is replaced gets the
        dead endpoint like the open tabs, never none: an endpoint configures the
        whole data store every mirror tab of that app instance shares, so a tab
        made with none took the proxy away from the open tabs too, and their
        `localhost` loads went straight to this Mac. While the listener is down a
        load fails and nothing reaches this Mac's own server on that port; once a
        listener is ready again, the tab made meanwhile loads the owner's page."""
        browser = self.require_mirror_browser()
        old = wait_for("the proxy to listen", self.proxy, self.timeout)
        owner, here = self.owner_and_this_mac("restart")
        url = f"http://localhost:{here.port}/marker.html?tab=restart"
        self.hold_proxy(True)
        held = True
        try:
            failed = self.sock.call("supermux.devices.mirror.browser_proxy_fail", {"machine": self.pair.machine}) or {}
            if failed.get("failed_port") != old["port"]:
                raise Failure(f"precondition: the driver failed no listener on port {old['port']}: {failed}")
            panel = self.new_tab(self.pair.mirror_id, self.mirror_terminal(), url)
            configs = {name: self.route(self.pair.mirror_id, tab).get("proxy_configs")
                       for name, tab in (("open_tab", browser), ("new_tab", panel))}
            if any(count != 2 for count in configs.values()):
                raise Failure(f"a mirror tab opened while the listener restarts left the app instance's data store "
                              f"without its proxy (WebKit proxy configurations {configs}, want 2 each): the open "
                              f"tabs' localhost loads go to this Mac")
            # A load that ends while the listener is down: it must fail, not reach this Mac.
            try:
                self.navigate(panel, url + "&down=1")
                down = str((self.sock.call("browser.get.title", {"surface_id": panel}) or {}).get("title") or "")
            except Failure as error:
                down = f"failed: {str(error)[:60]}"
            if here.hits or down in (owner.title, here.title):
                raise Failure(f"a load while the listener was down went somewhere (title {down!r}; this Mac's "
                              f"server saw {here.hits})")
            self.hold_proxy(False)
            held = False
            fresh = self.wait_replacement(old["port"])
            self.navigate_open_tab(panel, url + "&again=1")
            title = self.wait_owner_page(panel, owner, here, "the tab made during the restart to load")
            hosts = self.require_owner_hosts(owner, here.port)
            return {"failed_port": old["port"], "port": fresh.get("port"), "proxy_configs": configs,
                    "while_down": down, "title": title, "hosts": hosts}
        finally:
            if held:
                self.hold_proxy(False)

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
                ("typed_navigations_are_prompt", self.typed_navigations_are_prompt),
                ("proxy_requires_credential", self.proxy_requires_credential),
                ("terminal_link_opens_routed_browser", self.terminal_link_opens_routed_browser),
                ("moved_tab_swaps_route", self.moved_tab_swaps_route),
                ("old_host_page", self.old_host_page),
                ("proxy_connections_are_released", self.proxy_connections_are_released),
                ("data_store_per_app_instance", self.data_store_per_app_instance),
                ("unbound_mirror_browser_routes", self.unbound_mirror_browser_routes),
                ("idle_proxy_connections_close", self.idle_proxy_connections_close),
                ("owner_localhost_keeps_origin", self.owner_localhost_keeps_origin),
                ("as_written_page_reaches_owner_ports", self.as_written_page_reaches_owner_ports),
                ("forward_changes_reroute_open_tab", self.forward_changes_reroute_open_tab),
                ("unlisted_forward_explains", self.unlisted_forward_explains),
                ("bypass_browser_stays_local", self.bypass_browser_stays_local),
                ("as_written_page_navigation_reroutes", self.as_written_page_navigation_reroutes),
                ("public_page_gets_no_ports", self.public_page_gets_no_ports),
                ("same_origin_iframe_reaches_owner", self.same_origin_iframe_reaches_owner),
                # Last: they fail the proxy's listener.
                ("proxy_listener_failure_recovers", self.proxy_listener_failure_recovers),
                ("restart_keeps_mirror_store_proxied", self.restart_keeps_mirror_store_proxied),
            ]:
                ok = self.step(name, check) and ok
        for port in self.forwarded_ports:
            try:
                self.sock.call("supermux.devices.ports.stop", {"machine": self.pair.machine, "port": port})
            except Failure:
                pass
        for port in self.served_ports:
            try:
                self.tunnel("serve_port", port=port)
            except Failure:
                pass
        if self.injected:
            try:
                self.tunnel("clear_injected")
                self.sock.call("supermux.devices.ports.refresh", {"machine": self.pair.machine})
            except Failure:
                pass
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
