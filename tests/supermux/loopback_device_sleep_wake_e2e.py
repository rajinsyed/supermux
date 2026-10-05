#!/usr/bin/env python3
"""End-to-end check of what a Mac's links do around sleep, wake and network changes.

Runs against a tagged DEBUG build launched with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1
(tests/supermux/run_all_loopback_e2e.sh does that). The loopback device is this
app talking to its own mobile host, so it plays both Macs. The DEBUG drivers
`supermux.devices.power.*` run the app's real handlers for the system's signals
(macOS cannot be put to sleep from a test): `simulate` feeds willSleep, didWake,
the screens waking and a network change; `announce_sleep` sends the real
"going to sleep" notice from this host to the Macs subscribed to it (here the
loopback link); `peer_dialed_in` runs what an admitted inbound session from that
Mac runs. Everything they drive is real: the dark gate on the link's dials, the
link's reconnect policy and backoff, the route switcher's probes over the
simulated network (`supermux.devices.route.switch`) and the loopback host's
admissions (`connections_admitted` counts every reconnect).

  1. wake_probes_now         On the relay with the direct lane blocked, a wake or
                             a network change probes direct within ~2 s instead of
                             waiting the 10 s cadence; a minute-long sleep plans a
                             main-endpoint rebuild, a short one does not.
  2. dark_holds_dials        willSleep takes the link down at once and nothing
                             dials while the Mac is dark (a DarkWake: the process
                             runs, no wake notification); the app holds no App Nap
                             activity with no session; didWake dials at once, one
                             reconnect.
  3. peer_sleep_backs_off    The other Mac says it is going to sleep: the link
                             drops at once and does not redial for 20 s (a normal
                             loss redials in about a second); its wait is >= 280 s.
  4. dial_in_redials_now     That Mac dials in: the waiting link dials at once.
  5. healthy_after           The link is connected, answers a request, and the
                             App Nap activity is held while it is.

Writes a JSON report (default tests/supermux/artifacts/loopback_device_sleep_wake_e2e-<tag>.json)
with the timeline of link states and admissions, and exits non-zero on any
failed check. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_device_sleep_wake_e2e.py [--report PATH]
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
ENDPOINT_ID = "e2e0000000000000000000000000000000000000000000000000000000000003"
ADDRESSES = ["192.168.1.20:58465", "100.69.64.102:58465"]


class PowerFailure(Exception):
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
                raise PowerFailure(f"{method}: socket response timed out")
            self._sock.settimeout(remaining)
            chunk = self._sock.recv(65536)
            if not chunk:
                raise PowerFailure(f"{method}: socket closed by the app")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        response = json.loads(line.decode("utf-8", errors="replace"))
        if response.get("ok") is True:
            return response.get("result")
        error = response.get("error") or {}
        raise PowerFailure(f"{method}: {error.get('code', 'error')}: {error.get('message', 'unknown error')}")


def socket_path_for_tag(tag: str) -> str:
    slug = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", tag.strip().lower())).strip("-")
    return f"/tmp/cmux-debug-{slug}.sock"


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise PowerFailure(message)


class SleepWakeE2E:
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

    def power(self, method: str, **params: Any) -> Dict[str, Any]:
        return self.client.call(f"supermux.devices.power.{method}", params) or {}

    def status(self) -> Dict[str, Any]:
        return self.power("status", machine=self.machine)

    def switch(self, **params: Any) -> Dict[str, Any]:
        return self.client.call("supermux.devices.route.switch", {"machine": self.machine, **params}) or {}

    def probes(self) -> int:
        status = self.client.call("supermux.devices.route.switch_status", {"machine": self.machine}) or {}
        return int((status.get("stats") or {}).get("probes") or 0)

    def observe(self) -> Dict[str, Any]:
        device = self.loopback() or {}
        link = self.link()
        sample = {
            "t": round(time.monotonic() - self.started, 2),
            "link": device.get("link_state"),
            "phase": link.get("phase"),
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
        raise PowerFailure(f"timed out after {timeout_s:.0f}s waiting for {description} (last: {last})")

    def hold(self, description: str, condition: Callable[[Dict[str, Any]], bool], seconds: float) -> Dict[str, Any]:
        """Checks `condition` on every sample for `seconds`."""
        until = time.monotonic() + seconds
        last: Dict[str, Any] = {}
        while time.monotonic() < until:
            last = self.observe()
            expect(condition(last), f"{description} broke at {last}")
            time.sleep(0.5)
        return last

    def connected(self, sample: Dict[str, Any]) -> bool:
        return sample["link"] == "connected"

    # -- steps -----------------------------------------------------------------

    def step(self, name: str, action: Callable[[], Dict[str, Any]]) -> None:
        started = time.monotonic()
        try:
            details = action() or {}
            self.steps.append({"name": name, "ok": True, "seconds": round(time.monotonic() - started, 2), **details})
        except PowerFailure as error:
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
        self.power("reset")
        status = self.status()
        expect(status.get("dark") is False, f"the Mac starts dark: {status}")
        return {"machine": self.machine, "status": status}

    def wake_probes_now(self) -> Dict[str, Any]:
        self.client.call("supermux.devices.route.candidates_serve", {"addresses": ADDRESSES, "endpoint_id": ENDPOINT_ID})
        fetched = self.client.call("supermux.devices.route.candidates_fetch", {"machine": self.machine}) or {}
        expect(fetched.get("outcome") == "stored", f"the candidate fetch was not stored: {fetched}")
        self.switch(active=True, lane="blocked", reset=True)
        self.link("stop")
        self.wait_for("the link to drop", lambda s: not self.connected(s), 20)
        self.link("restore")
        self.wait_for("a relay session", self.connected, 30)
        results: Dict[str, Any] = {}
        for event in ("did_wake", "network_change"):
            # Right after a probe the next is >= 8 s away (10 s +-20 %).
            before = self.probes()
            deadline = time.monotonic() + 15
            while self.probes() == before and time.monotonic() < deadline:
                time.sleep(0.1)
            expect(self.probes() > before, f"no cadence probe within 15 s before {event}")
            settled = self.probes()
            self.power("simulate", event=event)
            fired = time.monotonic()
            while self.probes() == settled and time.monotonic() - fired < 4:
                time.sleep(0.1)
            took = round(time.monotonic() - fired, 2)
            expect(self.probes() > settled, f"{event} did not probe direct within 4 s")
            expect(took <= 3.0, f"{event} probed after {took} s, not at once")
            last = self.status().get("last_recovery") or {}
            expect(last.get("probed_now") is True, f"{event} recovery did not probe now: {last}")
            results[event] = {"probe_after_s": took, "recovery": last}
        self.switch(active=False)
        for slept, rebuilds in ((30, False), (90, True)):
            self.power("simulate", event="will_sleep", announce=False)
            self.power("simulate", event="did_wake", slept_s=slept)
            last = self.status().get("last_recovery") or {}
            expect(last.get("slept_s") == slept, f"the sleep read {last.get('slept_s')}, not {slept}")
            expect(last.get("rebuilds_main") is rebuilds, f"a {slept} s sleep: rebuilds_main {last.get('rebuilds_main')}")
            results[f"slept_{slept}"] = last
        self.wait_for("the link back after the simulated sleeps", self.connected, 30)
        self.facts["wake_probe_s"] = results["did_wake"]["probe_after_s"]
        return results

    def dark_holds_dials(self) -> Dict[str, Any]:
        self.wait_for("a connected link", self.connected, 30)
        before = self.link().get("connections_admitted")
        self.power("simulate", event="will_sleep", announce=False)
        dropped = self.wait_for("the link to drop at willSleep", lambda s: not self.connected(s), 3)
        status = self.status()
        expect(status.get("dark") is True, f"not dark after willSleep: {status}")
        held = self.hold("no dial while dark", lambda s: not self.connected(s) and s["admitted"] == before, 10)
        dark_status = self.status()
        activity = dark_status.get("activity") or {}
        if (activity.get("inbound") or 0) + (activity.get("outbound") or 0) == 0:
            expect(activity.get("held") is False, f"App Nap activity held with no session: {activity}")
        self.power("simulate", event="did_wake", slept_s=12)
        woke = time.monotonic()
        back = self.wait_for("a reconnect after didWake", self.connected, 5)
        reconnect_s = round(time.monotonic() - woke, 2)
        after = self.link().get("connections_admitted")
        expect(after == before + 1, f"waking took {after - before} reconnects, not one")
        self.facts["reconnect_after_wake_s"] = reconnect_s
        return {"dropped": dropped, "held": held, "activity_while_dark": activity,
                "reconnect_after_wake_s": reconnect_s}

    def peer_sleep_backs_off(self) -> Dict[str, Any]:
        self.wait_for("a connected link", self.connected, 30)
        before = self.link().get("connections_admitted")
        self.power("announce_sleep")
        dropped = self.wait_for("the link to drop on the notice", lambda s: not self.connected(s), 3)
        status = self.status()
        peer = status.get("peer") or {}
        expect(peer.get("asleep") is True, f"the peer is not marked asleep: {status}")
        expect((peer.get("wait_ms") or 0) >= 280_000, f"the link waits {peer.get('wait_ms')} ms, not >= 280 s")
        held = self.hold("no redial of a sleeping Mac", lambda s: not self.connected(s) and s["admitted"] == before, 20)
        self.facts["peer_sleep_wait_ms"] = peer.get("wait_ms")
        return {"dropped": dropped, "held": held, "peer": peer}

    def dial_in_redials_now(self) -> Dict[str, Any]:
        before = self.link().get("connections_admitted")
        self.power("peer_dialed_in", machine=self.machine)
        nudged = time.monotonic()
        self.wait_for("a redial after the dial-in", self.connected, 5)
        took = round(time.monotonic() - nudged, 2)
        after = self.link().get("connections_admitted")
        expect(after == before + 1, f"the dial-in took {after - before} reconnects, not one")
        peer = self.status().get("peer") or {}
        expect(peer.get("asleep") is False, f"still marked asleep after it dialed in: {peer}")
        self.facts["redial_after_dial_in_s"] = took
        return {"redial_after_s": took, "peer": peer}

    def healthy_after(self) -> Dict[str, Any]:
        sample = self.wait_for("a connected link", self.connected, 30)
        answer = self.client.call("supermux.devices.request", {
            "machine": self.machine, "method": "mobile.supermux.route.candidates", "params": {}}) or {}
        expect("result" in answer, f"the link did not answer a request: {answer}")
        activity = self.status().get("activity") or {}
        expect(activity.get("held") is True, f"no App Nap activity while a session is live: {activity}")
        return {"final": sample, "activity": activity}

    def cleanup(self) -> None:
        if not self.machine:
            return
        # The candidate cache outlives the app: forget this suite's peer (an empty
        # answer for its endpoint) so the route suites start from their own state.
        calls = (
            lambda: self.power("reset"),
            lambda: self.switch(active=False),
            lambda: self.link("restore"),
            lambda: self.wait_for("a connected link for the cleanup fetch", self.connected, 30),
            lambda: self.client.call("supermux.devices.route.candidates_serve",
                                     {"addresses": [], "endpoint_id": ENDPOINT_ID}),
            lambda: self.client.call("supermux.devices.route.candidates_fetch", {"machine": self.machine}),
            lambda: self.client.call("supermux.devices.route.candidates_serve", {}),
        )
        for call in calls:
            try:
                call()
            except PowerFailure as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        try:
            self.step("setup", self.setup)
            self.step("wake_probes_now", self.wake_probes_now)
            self.step("dark_holds_dials", self.dark_holds_dials)
            self.step("peer_sleep_backs_off", self.peer_sleep_backs_off)
            self.step("dial_in_redials_now", self.dial_in_redials_now)
            self.step("healthy_after", self.healthy_after)
            return True
        except PowerFailure:
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
    parser.add_argument("--report", help="report path (default: tests/supermux/artifacts/loopback_device_sleep_wake_e2e-<tag>.json)")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    socket_path = args.socket or socket_path_for_tag(args.tag)

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    timeline: List[Dict[str, Any]] = []
    try:
        with SocketClient(socket_path) as client:
            suite = SleepWakeE2E(client)
            passed = suite.run()
            steps, facts, timeline = suite.steps, suite.facts, suite.timeline
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-device-sleep-wake",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
        "timeline": timeline,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_device_sleep_wake_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("suite", "passed", "steps", "facts")}, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
