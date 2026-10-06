#!/usr/bin/env python3
"""End-to-end check that a remote Mac's link stays direct whenever direct works.

Runs against a tagged DEBUG build launched with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1
(tests/supermux/run_all_loopback_e2e.sh does that). The loopback device has no
Iroh path, so the DEBUG driver `supermux.devices.route.switch` puts a simulated
network under its link: each new session lands like the dial's race (direct
when the simulated lane is open, the link's switch policy allows direct and the
route-candidate cache holds an address for the peer; otherwise the relay), a
probe and a direct session's liveness check answer only while the lane is open.
Everything above that is real: the switch policy, the switcher's 1 s ticks, its
planned redials and fall backs, the link's reconnect policy and the loopback
host's admissions (`connections_admitted` counts every reconnect).

  1. starts_direct           With a direct address cached and the lane open, a
                             reconnect lands direct; with none cached it lands
                             on the relay; once one is cached again the link
                             moves direct on its own within 15 s.
  2. relay_to_direct         On the relay with the lane blocked, probes fail and
                             nothing moves; once the lane opens the link moves
                             direct within ~15 s with exactly one planned redial.
  3. direct_dies_falls_back  The lane blocks under a direct session: the link is
                             on the relay within 8 s with one reconnect, direct
                             is held off ~30 s (no move back even though the
                             lane reopened at once), then it moves direct again.
  4. flapping_is_bounded     The lane opens and blocks every 4 s for 100 s: at
                             most 4 reconnects in any 60 s, and the link still
                             switches (at least 2).
  5. network_change_restores_direct
                             (Review T4) Direct dies under a direct session and
                             is held off ~30 s; the path comes back and the
                             network changes (`power.simulate network_change`):
                             the hold-off clears at once and the link is direct
                             again within 5 s, not after the 30 s.
  6. recovery_probes_next_session
                             (Review T5) The network changes while the link is
                             down; the session that starts right after lands on
                             the relay and probes direct within 3 s of
                             connecting, not after the 8-12 s cadence.
  7. healthy_after           The link is connected and answers a request.

CMUX_E2E_STEPS=<step,step> runs only those steps after setup (all by default).

Writes a JSON report (default tests/supermux/artifacts/loopback_device_route_switch_e2e-<tag>.json)
with a timeline of route kinds and admissions, and exits non-zero on any failed
check. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_device_route_switch_e2e.py [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = REPO_ROOT / "tests" / "supermux" / "artifacts"
ENDPOINT_ID = "e2e0000000000000000000000000000000000000000000000000000000000002"
ADDRESSES = ["192.168.1.20:58465", "100.69.64.102:58465"]


class SwitchFailure(Exception):
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
                raise SwitchFailure(f"{method}: socket response timed out")
            self._sock.settimeout(remaining)
            chunk = self._sock.recv(65536)
            if not chunk:
                raise SwitchFailure(f"{method}: socket closed by the app")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        response = json.loads(line.decode("utf-8", errors="replace"))
        if response.get("ok") is True:
            return response.get("result")
        error = response.get("error") or {}
        raise SwitchFailure(f"{method}: {error.get('code', 'error')}: {error.get('message', 'unknown error')}")


def socket_path_for_tag(tag: str) -> str:
    slug = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", tag.strip().lower())).strip("-")
    return f"/tmp/cmux-debug-{slug}.sock"


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SwitchFailure(message)


class RouteSwitchE2E:
    def __init__(self, client: SocketClient) -> None:
        self.client = client
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {}
        self.timeline: List[Dict[str, Any]] = []
        self.machine = ""
        self.started = time.monotonic()

    # -- reads and drivers ----------------------------------------------------

    def loopback(self) -> Optional[Dict[str, Any]]:
        listed = self.client.call("supermux.devices.list", {}) or {}
        return next((d for d in listed.get("devices") or [] if d.get("is_loopback")), None)

    def link(self, action: str = "status") -> Dict[str, Any]:
        return self.client.call("supermux.devices.link", {"machine": self.machine, "action": action}) or {}

    def switch(self, **params: Any) -> Dict[str, Any]:
        return self.client.call("supermux.devices.route.switch", {"machine": self.machine, **params}) or {}

    def status(self) -> Dict[str, Any]:
        return self.client.call("supermux.devices.route.switch_status", {"machine": self.machine}) or {}

    def power(self, method: str, **params: Any) -> Dict[str, Any]:
        return self.client.call(f"supermux.devices.power.{method}", params) or {}

    def serve(self, addresses: Optional[List[str]]) -> None:
        params: Dict[str, Any] = {} if addresses is None else {"addresses": addresses, "endpoint_id": ENDPOINT_ID}
        self.client.call("supermux.devices.route.candidates_serve", params)

    def fetch(self) -> str:
        return str(self.client.call("supermux.devices.route.candidates_fetch", {"machine": self.machine}).get("outcome"))

    def observe(self) -> Dict[str, Any]:
        """One timeline sample: the link's state, its route kind and the admissions so far."""
        device = self.loopback() or {}
        link = self.link()
        route = device.get("route")
        sample = {
            "t": round(time.monotonic() - self.started, 2),
            "link": device.get("link_state"),
            "route": route.get("kind") if route else None,
            "admitted": link.get("connections_admitted"),
        }
        self.timeline.append(sample)
        return sample

    def wait_for(self, description: str, condition: Callable[[Dict[str, Any]], bool], timeout_s: float,
                 interval_s: float = 0.25) -> Dict[str, Any]:
        deadline = time.monotonic() + timeout_s
        last: Dict[str, Any] = {}
        while time.monotonic() < deadline:
            last = self.observe()
            if condition(last):
                return last
            time.sleep(interval_s)
        raise SwitchFailure(f"timed out after {timeout_s:.0f}s waiting for {description} (last: {last})")

    def on(self, kind: str) -> Callable[[Dict[str, Any]], bool]:
        return lambda sample: sample["link"] == "connected" and sample["route"] == kind

    def wait_for_fall_back(self, timeout_s: float) -> Dict[str, Any]:
        """The policy's fall back after the lane blocked under a direct session: the link is on the relay
        and the policy fell back (its `fallbacks` stat rose) or a new session started. A relay route
        sample alone is not one: the connection's path can move to the relay inside the same session,
        before the policy's liveness misses make it fall back and hold direct off."""
        fallbacks = self.status()["stats"]["fallbacks"]
        admitted = self.link().get("connections_admitted")

        def fell_back(sample: Dict[str, Any]) -> bool:
            if not self.on("relay")(sample):
                return False
            return self.status()["stats"]["fallbacks"] > fallbacks or sample["admitted"] > admitted

        return self.wait_for("the fall back to the relay", fell_back, timeout_s)

    def reconnect(self) -> None:
        self.link("stop")
        self.wait_for("the link to drop", lambda s: s["link"] != "connected", 20)
        self.link("restore")
        self.wait_for("the link to reconnect", lambda s: s["link"] == "connected", 30)

    def cache(self, addresses: List[str]) -> None:
        self.serve(addresses)
        expect(self.fetch() == "stored", "the candidate fetch was not stored")

    def forget(self) -> None:
        """The host says direct is off (relay-only): the link forgets its addresses."""
        self.client.call("supermux.devices.route.candidates_serve", {"refuse": "direct_off"})
        outcome = self.fetch()
        expect(outcome == "direct_off", f"the direct-off answer read {outcome}")

    # -- steps -----------------------------------------------------------------

    def step(self, name: str, action: Callable[[], Dict[str, Any]]) -> None:
        started = time.monotonic()
        try:
            details = action() or {}
            self.steps.append({"name": name, "ok": True, "seconds": round(time.monotonic() - started, 2), **details})
        except SwitchFailure as error:
            self.steps.append({"name": name, "ok": False, "seconds": round(time.monotonic() - started, 2),
                               "error": str(error)})
            raise

    def setup(self) -> Dict[str, Any]:
        deadline = time.monotonic() + 30
        device = None
        while time.monotonic() < deadline:
            device = self.loopback()
            if device and device.get("link_state") == "connected":
                break
            time.sleep(0.25)
        expect(device is not None and device.get("link_state") == "connected", "the loopback device never connected")
        self.machine = device["machine"]
        self.cache(ADDRESSES)
        status = self.switch(active=True, lane="open", reset=True)
        expect(status.get("active") is True, f"the simulation did not turn on: {status}")
        return {"machine": self.machine}

    def starts_direct(self) -> Dict[str, Any]:
        self.reconnect()
        landed = self.wait_for("a direct landing with an address cached", self.on("direct"), 5)
        landings = self.status().get("landings") or []
        expect(landings and landings[-1]["direct"] is True, f"the last landing was not direct: {landings}")
        self.forget()
        self.reconnect()
        relayed = self.wait_for("a relay landing with no address cached", self.on("relay"), 5)
        before = self.link().get("connections_admitted")
        self.cache(ADDRESSES)
        cached_at = time.monotonic()
        moved = self.wait_for("the move to direct once an address is cached", self.on("direct"), 16)
        after = self.link().get("connections_admitted")
        expect(after == before + 1, f"moving direct took {after - before} reconnects, not one")
        return {"direct_landing": landed, "relay_landing": relayed,
                "moved_after_s": round(time.monotonic() - cached_at, 2)}

    def relay_to_direct(self) -> Dict[str, Any]:
        self.switch(lane="blocked", reset=True)
        self.reconnect()
        self.wait_for("a relay landing with the lane blocked", self.on("relay"), 5)
        time.sleep(13)
        stats = self.status()["stats"]
        expect(stats["probes"] >= 1 and stats["probe_successes"] == 0, f"probes while blocked: {stats}")
        expect(self.observe()["route"] == "relay", "the link left the relay while the lane was blocked")
        before = self.link().get("connections_admitted")
        self.switch(lane="open")
        opened = time.monotonic()
        self.wait_for("the move to direct", self.on("direct"), 16)
        moved_after = round(time.monotonic() - opened, 2)
        time.sleep(1.5)
        after = self.link().get("connections_admitted")
        stats = self.status()["stats"]
        expect(after == before + 1, f"moving direct took {after - before} reconnects, not one")
        expect(stats["upgrades"] == 1, f"upgrades: {stats}")
        self.facts["relay_to_direct_s"] = moved_after
        return {"moved_after_s": moved_after, "reconnects": after - before, "stats": stats}

    def direct_dies_falls_back(self) -> Dict[str, Any]:
        expect(self.observe()["route"] == "direct", "not direct before the cut")
        before = self.link().get("connections_admitted")
        self.switch(lane="blocked")
        blocked = time.monotonic()
        self.wait_for_fall_back(8)
        fell_back_after = round(time.monotonic() - blocked, 2)
        self.switch(lane="open")
        status = self.status()
        policy = status["policy"]
        expect(status["stats"]["fallbacks"] == 1, f"fallbacks: {status['stats']}")
        expect(policy["allows_direct"] is False and 20_000 <= policy["hold_off_ms"] <= 30_000,
               f"direct is not held off ~30 s after the fall back: {policy}")
        held_until = time.monotonic() + policy["hold_off_ms"] / 1000
        while time.monotonic() < held_until - 1:
            expect(self.observe()["route"] == "relay", "the link moved back to direct inside the hold-off")
            time.sleep(0.5)
        self.wait_for("the move back to direct after the hold-off", self.on("direct"), 16)
        after = self.link().get("connections_admitted")
        expect(after == before + 2, f"fall back and move back took {after - before} reconnects, not two")
        self.facts["fall_back_s"] = fell_back_after
        return {"fell_back_after_s": fell_back_after, "held_off_ms": policy["hold_off_ms"],
                "reconnects": after - before}

    def flapping_is_bounded(self) -> Dict[str, Any]:
        self.switch(reset=True, lane="open")
        self.wait_for("a direct session before flapping", self.on("direct"), 16)
        start = time.monotonic()
        admissions: List[Dict[str, float]] = []
        lane_open = True
        next_toggle = start + 4
        while time.monotonic() - start < 100:
            if time.monotonic() >= next_toggle:
                lane_open = not lane_open
                self.switch(lane="open" if lane_open else "blocked")
                next_toggle += 4
            sample = self.observe()
            admissions.append({"t": time.monotonic() - start, "admitted": sample["admitted"]})
            time.sleep(0.5)
        self.switch(lane="open")
        first = admissions[0]["admitted"]
        moments = [a["t"] for i, a in enumerate(admissions[1:], 1) if a["admitted"] > admissions[i - 1]["admitted"]]
        reconnects = admissions[-1]["admitted"] - first
        worst = max((sum(1 for m in moments if s <= m < s + 60) for s in moments), default=0)
        stats = self.status()["stats"]
        expect(reconnects >= 2, f"the link never switched while the path flapped ({reconnects} reconnects)")
        expect(worst <= 4, f"{worst} reconnects in one minute while flapping: {moments}")
        return {"reconnects": reconnects, "worst_minute": worst, "moments_s": [round(m, 1) for m in moments],
                "stats": stats}

    def network_change_restores_direct(self) -> Dict[str, Any]:
        self.switch(reset=True, lane="open")
        self.wait_for("a direct session", self.on("direct"), 16)
        before = self.link().get("connections_admitted")
        self.switch(lane="blocked")
        self.wait_for_fall_back(8)
        held = self.status()["policy"]
        expect(held["allows_direct"] is False and held["hold_off_ms"] >= 20_000,
               f"direct is not held off after the fall back: {held}")
        self.switch(lane="open")
        self.power("simulate", event="network_change")
        changed = time.monotonic()
        cleared = self.status()["policy"]
        expect(cleared["allows_direct"] is True and cleared["hold_off_ms"] == 0,
               f"the network change left direct held off: {cleared}")
        self.wait_for("the move back to direct after the network change", self.on("direct"), 5)
        took = round(time.monotonic() - changed, 2)
        time.sleep(1)
        after = self.link().get("connections_admitted")
        expect(after == before + 2, f"fall back and move back took {after - before} reconnects, not two")
        self.facts["direct_after_network_change_s"] = took
        return {"held_before": held, "cleared": cleared, "direct_after_s": took, "reconnects": after - before}

    def recovery_probes_next_session(self) -> Dict[str, Any]:
        self.switch(reset=True, lane="blocked")
        self.link("stop")
        self.wait_for("the link to drop", lambda s: s["link"] != "connected", 20)
        self.power("simulate", event="network_change")
        self.link("restore")
        self.wait_for("a relay landing with the lane blocked", self.on("relay"), 15)
        connected = time.monotonic()
        while self.status()["stats"]["probes"] == 0 and time.monotonic() - connected < 4:
            time.sleep(0.1)
        took = round(time.monotonic() - connected, 2)
        stats = self.status()["stats"]
        expect(stats["probes"] >= 1, f"no probe within 4 s of the session after the recovery: {stats}")
        expect(took <= 3, f"the session after the recovery first probed after {took} s, not at once")
        self.switch(lane="open")
        self.wait_for("the move to direct", self.on("direct"), 16)
        self.facts["first_probe_after_recovery_session_s"] = took
        return {"first_probe_after_connect_s": took, "stats": stats}

    def healthy_after(self) -> Dict[str, Any]:
        sample = self.wait_for("a connected link with a route", lambda s: s["link"] == "connected" and s["route"], 30)
        answer = self.client.call("supermux.devices.request", {
            "machine": self.machine, "method": "mobile.supermux.route.candidates", "params": {}}) or {}
        expect("result" in answer, f"the link did not answer a request: {answer}")
        return {"final": sample}

    def cleanup(self) -> None:
        if not self.machine:
            return
        for call in (lambda: self.switch(active=False), lambda: self.power("reset"), self.forget,
                     lambda: self.serve(None)):
            try:
                call()
            except SwitchFailure as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        try:
            self.step("setup", self.setup)
            wanted = [s for s in os.environ.get("CMUX_E2E_STEPS", "").split(",") if s]
            for name in ("starts_direct", "relay_to_direct", "direct_dies_falls_back", "flapping_is_bounded",
                         "network_change_restores_direct", "recovery_probes_next_session", "healthy_after"):
                if not wanted or name in wanted:
                    self.step(name, getattr(self, name))
            return True
        except SwitchFailure:
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
    parser.add_argument("--report", help="report path (default: tests/supermux/artifacts/loopback_device_route_switch_e2e-<tag>.json)")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    socket_path = args.socket or socket_path_for_tag(args.tag)

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    timeline: List[Dict[str, Any]] = []
    try:
        with SocketClient(socket_path) as client:
            suite = RouteSwitchE2E(client)
            passed = suite.run()
            steps, facts, timeline = suite.steps, suite.facts, suite.timeline
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-device-route-switch",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
        "timeline": timeline,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_device_route_switch_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("suite", "passed", "steps", "facts")}, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
