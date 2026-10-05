#!/usr/bin/env python3
"""End-to-end check of a remote Mac link's route and its direct-address exchange.

Runs against a tagged DEBUG build launched with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1
(tests/supermux/run_all_loopback_e2e.sh does that). The loopback device has no
Iroh connection to sample, so its route is pinned with the DEBUG driver
`supermux.devices.route.override`, which goes through the same publish rule as a
real sample; its `mobile.supermux.route.candidates` request runs for real over
the loopback link, through the host's early (off-main) answer.

Route (what `supermux.devices.list` reports as each device's `route`):
  1. The loopback link is connected and has no route of its own (no Iroh path).
  2. A direct LAN path reads {kind: direct, scope: lan, rtt_ms}.
  3. The Tokyo relay reads {kind: relay, relay_id: apne1, place: Tokyo,
     place_confidence: confirmed}; its since_ms is new.
  4. RTT jitter is not republished; a large move waits for 5 s since the last
     publish, then is published with the same since_ms.
  5. An assumed relay city shows its region (usc1: US Central, best_effort);
     an unknown id shows itself (XYZ9, unknown).
  6. A Tailscale path reads scope tailscale; clearing it reads null.
  7. A link that drops has no route; once it reconnects it has one again.

Direct addresses:
  8. The host advertises supermux.route_candidates.v1 and answers
     route.candidates with {endpoint_id, addresses}.
  9. A pinned answer full of undialable addresses is filtered on both sides:
     only LAN, Tailscale and global IPv6 reach the cache, LAN first, and the
     cache file (0600, next to the projects file) holds exactly those.
 10. A reconnect asks again without being told to; the new answer replaces
     the old one (a DHCP change and a new port).
 11. An empty answer clears the peer from the cache and its file.

Writes a JSON report (default tests/supermux/artifacts/loopback_device_route_e2e-<tag>.json)
and exits non-zero on any failed check. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_device_route_e2e.py [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import stat
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = REPO_ROOT / "tests" / "supermux" / "artifacts"
CAPABILITY = "supermux.route_candidates.v1"
ENDPOINT_ID = "e2e0000000000000000000000000000000000000000000000000000000000001"
SERVED_FIRST = [
    "127.0.0.1:58465", "[fe80::1%14]:58465", "169.254.3.4:58465", "203.0.113.7:58465",
    "100.100.100.100:53", "224.0.0.251:5353", "garbage",
    "[2001:db8:1::5]:58465", "100.69.64.102:58465", "192.168.1.20:58465",
    "[fd7a:115c:a1e0::9]:58465", "[::ffff:192.168.1.20]:58465",
]
EXPECTED_FIRST = ["192.168.1.20:58465", "100.69.64.102:58465", "[fd7a:115c:a1e0::9]:58465", "[2001:db8:1::5]:58465"]
SERVED_SECOND = ["192.168.1.21:61234", "100.69.64.102:61234"]


class RouteFailure(Exception):
    """A check failed; the message says which and why."""


class SocketClient:
    """Minimal newline-delimited JSON client for the cmux v2 control socket."""

    def __init__(self, path: str, timeout_s: float = 30.0) -> None:
        self.path = path
        self.timeout_s = timeout_s
        self._sock: Optional[socket.socket] = None
        self._buffer = b""
        self._next_id = 1

    def __enter__(self) -> "SocketClient":
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout_s)
        sock.connect(self.path)
        self._sock = sock
        return self

    def __exit__(self, *_: Any) -> None:
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    def call(self, method: str, params: Optional[Dict[str, Any]] = None) -> Any:
        assert self._sock is not None, "not connected"
        request_id = self._next_id
        self._next_id += 1
        self._sock.sendall((json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n").encode())
        deadline = time.monotonic() + self.timeout_s
        while b"\n" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RouteFailure(f"{method}: socket response timed out")
            self._sock.settimeout(remaining)
            chunk = self._sock.recv(65536)
            if not chunk:
                raise RouteFailure(f"{method}: socket closed by the app")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        response = json.loads(line.decode("utf-8", errors="replace"))
        if response.get("ok") is True:
            return response.get("result")
        error = response.get("error") or {}
        raise RouteFailure(f"{method}: {error.get('code', 'error')}: {error.get('message', 'unknown error')}")


def socket_path_for_tag(tag: str) -> str:
    slug = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", tag.strip().lower())).strip("-")
    return f"/tmp/cmux-debug-{slug}.sock"


def wait_for(description: str, probe: Callable[[], Any], timeout_s: float, interval_s: float = 0.25) -> Any:
    deadline = time.monotonic() + timeout_s
    last_error: Optional[str] = None
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value:
                return value
        except RouteFailure as error:
            last_error = str(error)
        time.sleep(interval_s)
    suffix = f" (last error: {last_error})" if last_error else ""
    raise RouteFailure(f"timed out after {timeout_s:.0f}s waiting for {description}{suffix}")


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise RouteFailure(message)


class RouteE2E:
    def __init__(self, client: SocketClient, projects_file: Optional[str]) -> None:
        self.client = client
        self.projects_file = projects_file
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {}
        self.machine = ""
        self.device_id = ""
        self.tag = ""

    # -- reads ---------------------------------------------------------------

    def loopback(self, include_capabilities: bool = False) -> Optional[Dict[str, Any]]:
        listed = self.client.call("supermux.devices.list", {"include_capabilities": include_capabilities}) or {}
        return next((d for d in listed.get("devices") or [] if d.get("is_loopback")), None)

    def route(self) -> Any:
        device = self.loopback()
        expect(device is not None, "the loopback device is gone")
        return device.get("route")

    def pin(self, **route: Any) -> Any:
        return self.client.call("supermux.devices.route.override", {"machine": self.machine, **route}).get("route")

    def sample(self) -> None:
        self.client.call("supermux.devices.route.sample", {})

    def link(self, action: str) -> Dict[str, Any]:
        return self.client.call("supermux.devices.link", {"machine": self.machine, "action": action}) or {}

    def candidates(self) -> Dict[str, Any]:
        return self.client.call("supermux.devices.route.candidates", {}) or {}

    def peer(self) -> Optional[Dict[str, Any]]:
        return next(
            (p for p in self.candidates().get("peers") or []
             if p.get("device_id") == self.device_id and p.get("tag") == self.tag),
            None,
        )

    def serve(self, addresses: Optional[List[str]]) -> None:
        params: Dict[str, Any] = {} if addresses is None else {"addresses": addresses, "endpoint_id": ENDPOINT_ID}
        self.client.call("supermux.devices.route.candidates_serve", params)

    def fetch(self) -> str:
        return str(self.client.call("supermux.devices.route.candidates_fetch", {"machine": self.machine}).get("outcome"))

    # -- steps ---------------------------------------------------------------

    def step(self, name: str, action: Callable[[], Dict[str, Any]]) -> None:
        started = time.monotonic()
        try:
            details = action() or {}
            self.steps.append({"name": name, "ok": True, "seconds": round(time.monotonic() - started, 2), **details})
        except RouteFailure as error:
            self.steps.append({"name": name, "ok": False, "seconds": round(time.monotonic() - started, 2), "error": str(error)})
            raise

    def check_connected_without_route(self) -> Dict[str, Any]:
        device = wait_for("the loopback device to connect",
                          lambda: (lambda d: d if d and d.get("link_state") == "connected" else None)(self.loopback()), 30)
        self.machine, self.device_id, self.tag = device["machine"], device["device_id"], device["tag"]
        self.pin(kind="clear")
        expect(self.route() is None, f"the loopback link has no Iroh path, yet reports {self.route()}")
        return {"machine": self.machine}

    def check_direct_lan(self) -> Dict[str, Any]:
        self.pin(kind="direct", scope="lan", rtt_ms=6)
        route = self.route()
        expect(route and route["kind"] == "direct" and route["scope"] == "lan" and route["rtt_ms"] == 6,
               f"direct LAN reads {route}")
        expect(route["relay_id"] is None and route["place"] is None, f"a direct route names a relay: {route}")
        self.facts["lan_since_ms"] = route["since_ms"]
        return {"route": route}

    def check_tokyo_relay(self) -> Dict[str, Any]:
        self.pin(kind="relay", relay_id="apne1", rtt_ms=241)
        route = self.route()
        expect(route and route["kind"] == "relay" and route["scope"] is None, f"the relay reads {route}")
        expect(route["relay_id"] == "apne1" and route["place"] == "Tokyo" and route["city"] == "Tokyo"
               and route["place_confidence"] == "confirmed", f"apne1 is not Tokyo: {route}")
        expect(route["rtt_ms"] == 241, f"relay RTT {route['rtt_ms']}")
        expect(route["since_ms"] >= self.facts["lan_since_ms"], "a new kind kept the old since")
        self.facts["relay_since_ms"] = route["since_ms"]
        self.facts["relay_published_at"] = time.monotonic()
        return {"route": route}

    def check_rtt_throttle(self) -> Dict[str, Any]:
        self.pin(kind="relay", relay_id="apne1", rtt_ms=245)
        self.sample()
        expect(self.route()["rtt_ms"] == 241, f"jitter 241 -> 245 was republished: {self.route()}")
        self.pin(kind="relay", relay_id="apne1", rtt_ms=400)
        early = self.route()["rtt_ms"]
        expect(time.monotonic() - self.facts["relay_published_at"] >= 5 or early == 241,
               f"a large move was published within 5 s: {early}")
        wait_s = max(0.0, 5.2 - (time.monotonic() - self.facts["relay_published_at"]))
        time.sleep(wait_s)
        self.sample()
        route = self.route()
        expect(route["rtt_ms"] == 400, f"the move to 400 ms never published: {route}")
        expect(route["since_ms"] == self.facts["relay_since_ms"], "an RTT-only update moved since")
        return {"before_interval": early, "after_interval": route["rtt_ms"], "waited_s": round(wait_s, 2)}

    def check_assumed_and_unknown_places(self) -> Dict[str, Any]:
        self.pin(kind="relay", relay_id="usc1", rtt_ms=150)
        assumed = self.route()
        expect(assumed["place"] == "US Central" and assumed["city"] == "Iowa"
               and assumed["place_confidence"] == "best_effort", f"usc1 reads {assumed}")
        self.pin(kind="relay", relay_id="XYZ9", rtt_ms=150)
        unknown = self.route()
        expect(unknown["relay_id"] == "xyz9" and unknown["place"] == "XYZ9" and unknown["city"] is None
               and unknown["place_confidence"] == "unknown", f"an unknown relay reads {unknown}")
        return {"assumed": assumed["place"], "unknown": unknown["place"]}

    def check_tailscale_and_clear(self) -> Dict[str, Any]:
        self.pin(kind="direct", scope="tailscale", rtt_ms=8)
        route = self.route()
        expect(route["kind"] == "direct" and route["scope"] == "tailscale", f"Tailscale reads {route}")
        self.pin(kind="clear")
        expect(self.route() is None, "a cleared route still reads")
        return {"route": route}

    def check_link_loss_clears_route(self) -> Dict[str, Any]:
        self.pin(kind="direct", scope="lan", rtt_ms=5)
        expect(self.route() is not None, "no route before the drop")
        self.link("stop")
        wait_for("the link to drop", lambda: (self.loopback() or {}).get("link_state") != "connected", 20)
        while_down = self.route()
        expect(while_down is None, f"a dropped link still reports {while_down}")
        self.link("restore")
        wait_for("the link to reconnect", lambda: (self.loopback() or {}).get("link_state") == "connected", 30)
        route = wait_for("the route after reconnecting", self.route, 10)
        expect(route["scope"] == "lan", f"after reconnecting: {route}")
        self.pin(kind="clear")
        return {"after_reconnect": route}

    def check_host_answers(self) -> Dict[str, Any]:
        device = wait_for("the capabilities", lambda: (lambda d: d if d and d.get("capabilities") else None)(
            self.loopback(include_capabilities=True)), 20)
        expect(CAPABILITY in device["capabilities"], f"{CAPABILITY} not advertised")
        answer = (self.client.call("supermux.devices.request", {
            "machine": self.machine, "method": "mobile.supermux.route.candidates", "params": {}}) or {}).get("result") or {}
        expect("endpoint_id" in answer and isinstance(answer.get("addresses"), list), f"answer shape: {answer}")
        return {"real_answer": answer}

    def check_filtered_and_persisted(self) -> Dict[str, Any]:
        self.serve(SERVED_FIRST)
        outcome = self.fetch()
        expect(outcome == "stored", f"the fetch did not store: {outcome}")
        peer = self.peer()
        expect(peer is not None, "the loopback peer is not in the cache")
        expect(peer["endpoint_id"] == ENDPOINT_ID, f"filed under {peer['endpoint_id']}")
        expect(peer["dial_addresses"] == EXPECTED_FIRST, f"dial addresses {peer['dial_addresses']}")
        path = Path(self.candidates()["file"])
        expect(path.is_file(), f"no cache file at {path}")
        if self.projects_file:
            expect(path.parent == Path(self.projects_file).parent, f"cache {path} is not next to {self.projects_file}")
        mode = stat.S_IMODE(path.stat().st_mode)
        expect(mode == 0o600, f"cache file mode {oct(mode)}")
        document = json.loads(path.read_text())
        stored = next((p for p in document.get("peers", [])
                       if p["key"]["device_id"] == self.device_id and p["key"]["tag"] == self.tag), None)
        expect(stored is not None, f"the file has no loopback peer: {document}")
        on_disk = [c["address"] for c in stored["candidates"]]
        expect(on_disk == EXPECTED_FIRST, f"the file holds {on_disk}")
        self.facts["cache_file"] = str(path)
        return {"dial_addresses": peer["dial_addresses"], "file": str(path), "mode": oct(mode)}

    def check_reconnect_asks_again(self) -> Dict[str, Any]:
        before = self.candidates()
        self.serve(SERVED_SECOND)
        self.link("stop")
        wait_for("the link to drop", lambda: (self.loopback() or {}).get("link_state") != "connected", 20)
        self.link("restore")
        wait_for("the link to reconnect", lambda: (self.loopback() or {}).get("link_state") == "connected", 30)
        peer = wait_for("the new addresses after reconnecting",
                        lambda: (lambda p: p if p and p["dial_addresses"] == SERVED_SECOND else None)(self.peer()), 20)
        after = self.candidates()
        expect(after["fetches_stored"] > before["fetches_stored"], "no fetch was stored after the reconnect")
        expect(after["served_count"] > before["served_count"], "the host served no new answer")
        return {"dial_addresses": peer["dial_addresses"], "fetches_stored": after["fetches_stored"],
                "served_count": after["served_count"]}

    def check_empty_answer_clears(self) -> Dict[str, Any]:
        self.serve([])
        outcome = self.fetch()
        expect(outcome == "stored", f"the empty answer was not taken: {outcome}")
        expect(self.peer() is None, "an empty answer left the peer cached")
        document = json.loads(Path(self.facts["cache_file"]).read_text())
        expect(not any(p["key"]["device_id"] == self.device_id for p in document.get("peers", [])),
               "the file still holds the peer")
        return {}

    def cleanup(self) -> None:
        for call in (lambda: self.serve(None), lambda: self.pin(kind="clear")):
            try:
                if self.machine:
                    call()
            except RouteFailure as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        try:
            self.step("connected_without_route", self.check_connected_without_route)
            self.step("direct_lan", self.check_direct_lan)
            self.step("tokyo_relay", self.check_tokyo_relay)
            self.step("rtt_throttle", self.check_rtt_throttle)
            self.step("assumed_and_unknown_places", self.check_assumed_and_unknown_places)
            self.step("tailscale_and_clear", self.check_tailscale_and_clear)
            self.step("link_loss_clears_route", self.check_link_loss_clears_route)
            self.step("host_answers_route_candidates", self.check_host_answers)
            self.step("candidates_filtered_and_persisted", self.check_filtered_and_persisted)
            self.step("reconnect_asks_again", self.check_reconnect_asks_again)
            self.step("empty_answer_clears", self.check_empty_answer_clears)
            return True
        except RouteFailure:
            return False
        except (OSError, ValueError, KeyError, TypeError) as error:
            self.steps.append({"name": "harness", "ok": False, "error": f"{type(error).__name__}: {error}"})
            return False
        finally:
            self.cleanup()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"), help="tagged build (default: $CMUX_TAG)")
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock)")
    parser.add_argument("--projects-file", help="the build's SUPERMUX_PROJECTS_FILE; the cache must sit next to it")
    parser.add_argument("--report", help="report path (default: tests/supermux/artifacts/loopback_device_route_e2e-<tag>.json)")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    socket_path = args.socket or socket_path_for_tag(args.tag)

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with SocketClient(socket_path) as client:
            suite = RouteE2E(client, args.projects_file)
            passed = suite.run()
            steps, facts = suite.steps, suite.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-device-route",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_device_route_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
