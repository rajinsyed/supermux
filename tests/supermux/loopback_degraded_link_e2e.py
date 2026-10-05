#!/usr/bin/env python3
"""Loopback E2E: Mac mirrors stay usable over a slow, capacity-limited link.

Field report (2026-10-05): remote terminals were "awfully delayed" after the other Mac woke
and the link sat on a relay at 240-400 ms, reconnecting ~45 times an hour. The loop
(/tmp/latency-work/STREAM.md, TRANSPORT.md): bulk output and multi-MB replays queue ahead of
keystroke echo, replies and the liveness probe; a probe stuck behind them declares a live link
dead; every redial re-sends full replays of every mirror; replays that miss their deadline are
asked for again while the first is still being sent; typing on a re-attaching mirror is dropped;
replays are captured on the host's main thread.

One tagged DEBUG build is both Macs (LOOPBACK-HARNESS.md). The DEBUG driver
`supermux.devices.link_impairment` (SupermuxDeviceLoopbackImpairment) gives the loopback link a
300 ms round trip and 300 KB/s each way behind a 64 KB send buffer (about the link's
bandwidth-delay product, so the app's own queues hold the backlog and an app change can reorder
it), plus a one-shot 2 s drop that cuts the connection. The loopback is ONE ordered byte stream
per direction (events ride the control stream, as on a Tailscale route); QUIC stream priority is
covered by SupermuxIrxPriorityStarvationTests in CmuxIrxTransport.

Setup (impairment off): six mirrors of six source terminals, all opened with
`vm.workspace_open` (auto-mirror off). The selected mirror shows three panes: the ECHO terminal (a
raw-mode program that logs every byte it reads with its arrival time and echoes it back as
"EK:" lines) and two TICKERs; three more mirrors are hidden: two TICKERs and the FLOOD. Tickers
and the flood first print 12000 lines of ~100 columns (a full 10000-row replay is MBs, as an
agent's long scrollback is), then a ticker prints one line a second (an agent's status line),
and the flood prints ~600 KB/s while its control file exists (twice the link).

Steps (D1, D3 and D4 are red today; D2 and D5 are guards; the others check the harness):
  setup / impairment_on        programs running, mirrors attached, link impaired
  baseline_echo                no flood: each key echoes within 1 s (RTT + processing); proves
                               the echo measurement and the impairment's round trip
  link_saturated               flood on: the viewer receives the cap (300 KB/s +-20%), so the
                               flood really fills the link
  D1 echo_under_flood          30 keys, 300 ms apart, typed into the visible ECHO mirror while
                               the hidden FLOOD fills the link: echo p95 <= 1.5 s and every key
                               reaches the program exactly once and echoes. 1.5 s = 300 ms RTT +
                               the 64 KB send buffer (~0.2 s) + one bounded output frame ahead of
                               the echo (<= 256 KB, ~0.85 s) + margin. RED: one first-in-first-out
                               event queue per connection for every watched terminal
                               (MobileHostConnectionEventQueue, 8 MB per terminal), so the echo
                               waits behind the hidden flood's backlog (~27 s at 300 KB/s).
  D2 no_redial_under_flood     60 s of flood: no unplanned redial (`connections_admitted` steady,
                               the link never leaves `connected`). GREEN in the loopback: its single
                               ordered stream interleaves replies between event frames in the host's
                               writer, so no request misses its 20 s deadline and the liveness probe
                               never runs. In the field the probe and keepalive starve behind output
                               on the QUIC connection's strict stream priority; that red lives in
                               SupermuxIrxPriorityStarvationTests. Kept as a guard for the fixes.
  flood_drained                flood off; waits until an echo is fast again (the backlog drained)
  D4 typing_during_reattach    a re-attach of the ECHO mirror (`terminal_close.replay`, a resume
                               over the 300 ms link) with 10 keys typed right after it starts:
                               every key reaches the program exactly once. RED: input typed while
                               the mirror is `.attaching` is dropped (DeviceTerminalInputRouter's
                               enabled gate; `terminal_input.stats` `dropped_while_detached`).
  D3 recovers_after_drop       a 2 s drop that cuts the connection, while the tickers print: the
                               link reconnects, within 60 s no unplanned redial, each mirror pane
                               asks for at most one replay besides its quiet-output confirmations
                               (`replay_requests - replay_confirmations <= 1`), the ECHO mirror echoes
                               a key within 8 s of the drop's end, and no pane is left detached on
                               a connected link ("disconnected until Retry"). RED (2026-10-05): the
                               host drops this Mac's viewport reports with the connection
                               (`mobile.viewport.clear`), so each visible terminal resizes to its
                               own pane and back on the re-attach; that moves its grid generation,
                               so even the idle ECHO terminal gets a full replay, and the tickers
                               (they printed while no one was subscribed) too: five 10000-row
                               replays share the 300 KB/s link. Each visible pane asks three times
                               (a `viewport_transition` answer, the full replay, then a second
                               attach whose resume waits ~12 s behind the other terminals' full
                               replays in the host's writer); typing is dropped that whole time and
                               the ECHO mirror first echoes ~20 s after the drop ended. A deadline
                               miss, a probe failure and a redial follow only when the replays take
                               over 20 s (more or larger terminals than here).
  D5 host_main_responsive      during the 30 s after the drop, a main-actor socket round trip
                               (`supermux.devices.link status`) stays under 250 ms. Full replays are
                               captured synchronously on the host's main thread (in the loopback the
                               viewer shares it, so this is the app's main thread). GREEN on an M4:
                               a 10000-row capture takes ~20 ms, the worst round trip was ~50 ms.
                               Kept as a guard.

Every step runs; the suite exits non-zero if any fails. The JSON report (per-key latencies,
link samples, replay counts per pane and from the host's DEBUG log) goes to
tests/supermux/artifacts/loopback_degraded_link_e2e-<tag>.json (and --report if given).

Usage:
  CMUX_E2E_SUITES="loopback_degraded_link_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh
  CMUX_TAG=<tag> python3 tests/supermux/loopback_degraded_link_e2e.py [--scratch DIR] [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))

from loopback_terminal_input_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    LOOPBACK_DEVICE_ID,
    Failure,
    Socket,
    socket_path_for_tag,
    up,
    wait_for,
)

RTT_MS = 300
BYTES_PER_SECOND = 300_000
QUEUE_BYTES = 64 * 1024
HISTORY_LINES = 12_000
FLOOD_BYTES_PER_SECOND = 600_000
BASELINE_ECHO_BOUND_S = 1.0
D1_KEYS = "abcdefghijklmnopqrstuvwxyz0123"
D1_SPACING_S = 0.3
D1_P95_BOUND_S = 1.5
D1_ECHO_WAIT_S = 120.0
D2_WINDOW_S = 60.0
DRAIN_TIMEOUT_S = 150.0
D4_KEYS = "qwertyuiop"
D4_SPACING_S = 0.06
D3_DROP_S = 2.0
D3_WINDOW_S = 60.0
D3_SETTLE_S = 30.0
D3_ECHO_BOUND_S = 8.0
D3_PROBE_KEYS = "abcdefghijklmnopqrstuvwxyz0123456789"
D5_WINDOW_S = 30.0
D5_MAX_BOUND_S = 0.25
ECHO_PREFIX = "EK:"

ECHO = r'''
import binascii, os, sys, time, tty
out = sys.argv[1]
fd = sys.stdin.fileno()
tty.setraw(fd)
os.write(1, ("ECHO-" + "READY\r\n").encode())
count = 0
with open(out, "ab", 0) as log:
    while True:
        data = os.read(fd, 4096)
        if not data:
            break
        log.write(b"%.6f %s\n" % (time.time(), binascii.hexlify(data)))
        echo = b""
        for byte in data:
            if count % 20 == 0:
                echo += b"\r\nEK:"
            echo += bytes([byte])
            count += 1
        os.write(1, echo)
'''

HISTORY = r'''
def history(label, lines):
    filler = "the quick brown fox jumps over the lazy dog 0123456789 " * 2
    out = []
    for i in range(lines):
        out.append("%s %05d %s" % (label, i, filler[: 86 - len(label)]))
        if len(out) == 500:
            sys.stdout.write("\n".join(out) + "\n")
            out = []
    if out:
        sys.stdout.write("\n".join(out) + "\n")
    sys.stdout.write("HISTORY-" + "DONE-" + label + "\n")
    sys.stdout.flush()
'''

TICKER = r'''
import sys, time
''' + HISTORY + r'''
label, lines = sys.argv[1], int(sys.argv[2])
history(label, lines)
n = 0
while True:
    time.sleep(1)
    n += 1
    sys.stdout.write("tick %s %d %.3f\n" % (label, n, time.time()))
    sys.stdout.flush()
'''

FLOOD = r'''
import os, sys, time
''' + HISTORY + r'''
label, lines, control, rate = sys.argv[1], int(sys.argv[2]), sys.argv[3], float(sys.argv[4])
history(label, lines)
n = 0
body = (label + " flood ").ljust(88, "x")
while True:
    if os.path.exists(control):
        start, sent = time.monotonic(), 0
        while os.path.exists(control):
            target = (time.monotonic() - start) * rate
            chunk = []
            while sent < target:
                n += 1
                line = "%09d %s\n" % (n, body)
                chunk.append(line)
                sent += len(line)
            if chunk:
                sys.stdout.write("".join(chunk))
                sys.stdout.flush()
            time.sleep(0.02)
        sys.stdout.write("FLOOD-" + "PAUSED %d\n" % n)
        sys.stdout.flush()
    time.sleep(0.05)
'''


def percentile(values: List[float], fraction: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round(fraction * (len(ordered) - 1)))))
    return ordered[index]


def ms(seconds: Optional[float]) -> Optional[int]:
    return None if seconds is None else int(round(seconds * 1000))


class Phase:
    """Keys typed into the ECHO mirror in one step, matched against what the
    program received (recorder log) and echoed (mirror text)."""

    def __init__(self, name: str, start_index: int) -> None:
        self.name = name
        self.start_index = start_index
        self.typed: List[Tuple[str, float]] = []


class DegradedLinkE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.timeout = args.timeout
        self.keep = args.keep
        self.nonce = uuid.uuid4().hex[:6]
        self.scratch = Path(args.scratch or f"/tmp/supermux-degraded-link-{self.nonce}")
        self.log_path = Path(args.log)
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "debug_log": str(self.log_path)}
        self.machine = ""
        self.sources: Dict[str, Dict[str, str]] = {}  # role -> workspace_id, surface_id
        self.mirrors: Dict[str, Dict[str, str]] = {}  # role -> workspace_id, panel_id
        self.workspaces: List[str] = []
        self.recorder_path = self.scratch / "echo.log"
        self.flood_control = self.scratch / "flood.on"
        self.echo_seen_at: List[float] = []
        self.echo_text = ""
        self.echo_anomalies: List[str] = []
        self.link_samples: List[Dict[str, Any]] = []
        self.auto_mirror_was: Optional[bool] = None
        self.flood_started: Optional[float] = None
        self.d2_before: Dict[str, Any] = {}
        self.d2_log_offset = 0
        self.d5: Dict[str, List[int]] = {}

    # -- socket helpers ---------------------------------------------------------

    def device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device in supermux.devices.list (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def impairment(self, **params: Any) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.link_impairment", params) or {}

    def link_status(self) -> Dict[str, Any]:
        """The link's phase and redial counter; the call's round trip hops to the
        main actor, so its latency is also the main thread's responsiveness."""
        started = time.monotonic()
        status = self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "status"}) or {}
        sample = {
            "t": round(time.time(), 3),
            "phase": status.get("phase"),
            "admitted": status.get("connections_admitted"),
            "main_rtt_ms": ms(time.monotonic() - started),
        }
        self.link_samples.append(sample)
        return sample

    def stream_stats(self) -> Dict[str, Dict[str, Any]]:
        stats = self.sock.call("supermux.devices.terminal_stream.stats", {"machine": self.machine}) or {}
        return {up(pane.get("panel_id")): pane for pane in stats.get("panes") or []}

    def input_stats(self, reset: bool = False) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.terminal_input.stats", {"reset": reset}) or {}

    def read_text(self, workspace_id: str, surface_id: str, scrollback: bool = False) -> str:
        result = self.sock.call("surface.read_text", {"workspace_id": workspace_id, "surface_id": surface_id,
                                                      "scrollback": scrollback}, timeout_s=120) or {}
        return str(result.get("text") or "")

    def panes(self, workspace_id: str) -> List[Dict[str, Any]]:
        inspected = self.sock.call("supermux.devices.terminal_close.inspect", {"workspace_id": workspace_id}) or {}
        return inspected.get("panes") or []

    def mirror_panel_for(self, mirror_workspace: str, source_surface: str) -> Optional[str]:
        for projection in (self.sock.call("surface.catalog", {}) or {}).get("projections") or []:
            resource = str(projection.get("resource", ""))
            if up(projection.get("workspace_id")) == up(mirror_workspace) and \
                    up(resource.rsplit("/", 1)[-1]) == up(source_surface):
                return up(projection.get("panel_id"))
        return None

    def log_offset(self) -> int:
        try:
            return self.log_path.stat().st_size
        except OSError:
            return 0

    def log_since(self, offset: int) -> List[str]:
        time.sleep(1.0)  # the debug log is written asynchronously
        try:
            with self.log_path.open("rb") as handle:
                handle.seek(offset)
                return handle.read().decode("utf-8", errors="replace").splitlines()
        except OSError as error:
            raise Failure(f"cannot read the debug log {self.log_path}: {error}")

    def host_replays(self, lines: List[str]) -> Dict[str, Any]:
        """Per source terminal: full replays the host captured and resumes it served."""
        roles = {self.sources[role]["surface_id"][:8].upper(): role for role in self.sources}
        full: Dict[str, int] = {role: 0 for role in self.sources}
        resumed: Dict[str, int] = {role: 0 for role in self.sources}
        for line in lines:
            match = re.search(r"mobile\.terminal\.replay surface=([0-9A-Fa-f]{8}) renderGrid=", line)
            if match and match.group(1).upper() in roles:
                full[roles[match.group(1).upper()]] += 1
            match = re.search(r"supermux\.terminal\.resume surface=([0-9A-Fa-f]{8}) from=", line)
            if match and match.group(1).upper() in roles:
                resumed[roles[match.group(1).upper()]] += 1
        return {
            "full_captures": full,
            "resumes": resumed,
            "missed_deadlines": sum("missed its reply deadline" in line for line in lines),
            "input_batches_dropped": sum("supermux.inputPipeline dropped" in line for line in lines),
            "connections_admitted": sum("supermux.loopback host admitted connection" in line for line in lines),
            "resume_refusals": sum("supermux.terminal.resume REFUSED" in line for line in lines),
        }

    # -- the ECHO terminal --------------------------------------------------------

    def recorder(self) -> List[Tuple[float, str]]:
        """Every byte the ECHO program received, with its arrival time."""
        try:
            lines = self.recorder_path.read_text().splitlines()
        except FileNotFoundError:
            return []
        out: List[Tuple[float, str]] = []
        for line in lines:
            stamp, _, payload = line.partition(" ")
            for byte in bytes.fromhex(payload.strip()):
                out.append((float(stamp), chr(byte)))
        return out

    def poll_echo(self) -> None:
        """Reads the ECHO mirror and stamps every newly echoed byte with now."""
        role = self.mirrors["echo"]
        text = self.read_text(role["workspace_id"], role["panel_id"], scrollback=True)
        now = time.time()
        echoed = "".join(line.strip()[len(ECHO_PREFIX):] for line in text.splitlines()
                         if line.strip().startswith(ECHO_PREFIX))
        if not (echoed.startswith(self.echo_text) or self.echo_text.startswith(echoed)):
            self.echo_anomalies.append(f"echo text changed: had {self.echo_text!r}, now {echoed!r}")
        if len(echoed) > len(self.echo_seen_at):
            self.echo_seen_at.extend([now] * (len(echoed) - len(self.echo_seen_at)))
        if len(echoed) > len(self.echo_text):
            self.echo_text = echoed

    def type_key(self, phase: Phase, key: str) -> None:
        phase.typed.append((key, time.time()))
        self.sock.call("debug.shortcut.simulate", {"combo": key})

    def echo_focused(self) -> None:
        role = self.mirrors["echo"]
        self.sock.call("workspace.select", {"workspace_id": role["workspace_id"]})
        self.sock.call("surface.focus", {"workspace_id": role["workspace_id"], "surface_id": role["panel_id"]})
        self.sock.call("debug.app.activate", {})

        def focused() -> bool:
            result = self.sock.call("debug.terminal.is_focused", {"surface_id": role["panel_id"]}) or {}
            if not result.get("focused"):
                self.sock.call("surface.focus", {"workspace_id": role["workspace_id"], "surface_id": role["panel_id"]})
            return bool(result.get("focused"))

        wait_for("the ECHO mirror to take keyboard focus", focused, self.timeout)

    def phase_result(self, phase: Phase) -> Dict[str, Any]:
        """Matches the phase's keys to the program's reads (in order) and their echoes."""
        received = self.recorder()[phase.start_index:]
        keys: List[Dict[str, Any]] = []
        cursor = 0
        unexpected: List[str] = []
        for index, (arrived_at, char) in enumerate(received):
            match = next((i for i in range(cursor, len(phase.typed)) if phase.typed[i][0] == char), None)
            if match is None:
                unexpected.append(char)
                continue
            for skipped in range(cursor, match):
                keys.append({"key": phase.typed[skipped][0], "dropped": True})
            pressed = phase.typed[match][1]
            echo_index = phase.start_index + index
            echoed_at = self.echo_seen_at[echo_index] if echo_index < len(self.echo_seen_at) else None
            keys.append({
                "key": char,
                "to_program_ms": ms(arrived_at - pressed),
                "echo_ms": ms(echoed_at - pressed) if echoed_at else None,
                "pressed_at": round(pressed, 3),
            })
            cursor = match + 1
        for skipped in range(cursor, len(phase.typed)):
            keys.append({"key": phase.typed[skipped][0], "dropped": True})
        echoes = [k["echo_ms"] / 1000 for k in keys if k.get("echo_ms") is not None]
        return {
            "typed": "".join(k for k, _ in phase.typed),
            "received": "".join(c for _, c in received),
            "keys": keys,
            "dropped": [k["key"] for k in keys if k.get("dropped")],
            "not_echoed": [k["key"] for k in keys if not k.get("dropped") and k.get("echo_ms") is None],
            "unexpected": unexpected,
            "echo_p50_ms": ms(percentile(echoes, 0.5)),
            "echo_p95_ms": ms(percentile(echoes, 0.95)),
            "echo_max_ms": ms(max(echoes)) if echoes else None,
        }

    def echo_pending(self, phase: Phase) -> bool:
        received = len(self.recorder()) - phase.start_index
        typed = len(phase.typed)
        return received < typed or len(self.echo_seen_at) < phase.start_index + received

    # -- steps -------------------------------------------------------------------

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

    def create_source(self, role: str) -> Tuple[str, str]:
        title = f"degraded-{role}-{self.nonce}"
        created = self.sock.call("workspace.create", {"title": title, "focus": False}) or {}
        workspace_id = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not workspace_id:
            raise Failure(f"workspace.create returned no id: {created}")
        self.workspaces.append(workspace_id)
        surfaces = (self.sock.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        terminal = next((s["id"] for s in surfaces if s.get("type") == "terminal"), None)
        if not terminal:
            raise Failure(f"{title} has no terminal: {surfaces}")
        return workspace_id, up(terminal)

    def split(self, workspace_id: str, surface_id: str, direction: str) -> str:
        result = self.sock.call("surface.split", {"workspace_id": workspace_id, "surface_id": surface_id,
                                                  "direction": direction}) or {}
        if not result.get("surface_id"):
            raise Failure(f"surface.split returned no surface: {result}")
        return up(result["surface_id"])

    def run_in(self, role: str, command: str) -> None:
        source = self.sources[role]
        self.sock.call("surface.send_text", {"workspace_id": source["workspace_id"],
                                             "surface_id": source["surface_id"], "text": command + "\n"})

    def setup(self) -> Dict[str, Any]:
        self.scratch.mkdir(parents=True, exist_ok=True)
        (self.scratch / "echo.py").write_text(ECHO)
        (self.scratch / "ticker.py").write_text(TICKER)
        (self.scratch / "flood.py").write_text(FLOOD)
        self.flood_control.unlink(missing_ok=True)
        self.impairment(reset=True)

        def connected() -> Optional[Dict[str, Any]]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        self.machine = wait_for("the loopback device to connect", connected, self.timeout)["machine"]
        listed = self.sock.call("supermux.devices.list", {}) or {}
        self.auto_mirror_was = bool(listed.get("auto_mirror"))
        if self.auto_mirror_was:
            self.sock.call("supermux.devices.set_auto_mirror", {"enabled": False})

        # The visible mirror's source: ECHO beside two TICKERs. Three hidden ones.
        visible, echo = self.create_source("visible")
        tick_a = self.split(visible, echo, "right")
        tick_b = self.split(visible, tick_a, "down")
        self.sources = {
            "echo": {"workspace_id": visible, "surface_id": echo},
            "tick_a": {"workspace_id": visible, "surface_id": tick_a},
            "tick_b": {"workspace_id": visible, "surface_id": tick_b},
        }
        for role in ("tick_c", "tick_d", "flood"):
            workspace_id, surface_id = self.create_source(role)
            self.sources[role] = {"workspace_id": workspace_id, "surface_id": surface_id}

        self.run_in("echo", f"python3 {self.scratch / 'echo.py'} {self.recorder_path}")
        for role in ("tick_a", "tick_b", "tick_c", "tick_d"):
            self.run_in(role, f"python3 {self.scratch / 'ticker.py'} {role} {HISTORY_LINES}")
        self.run_in("flood", f"python3 {self.scratch / 'flood.py'} flood {HISTORY_LINES} {self.flood_control} "
                             f"{FLOOD_BYTES_PER_SECOND}")
        for role in ("tick_a", "tick_b", "tick_c", "tick_d", "flood"):
            source = self.sources[role]
            wait_for(f"{role}'s history in its source", lambda s=source, r=role: f"HISTORY-DONE-{r}" in
                     self.read_text(s["workspace_id"], s["surface_id"], scrollback=True), 120, 1.0)
        wait_for("the ECHO program", lambda: self.recorder_path.exists(), self.timeout)

        # Mirrors: one workspace per source workspace.
        mirror_of: Dict[str, str] = {}
        for role, source in self.sources.items():
            if source["workspace_id"] in mirror_of:
                continue
            opened = self.sock.call("vm.workspace_open", {"id": self.machine, "workspace_id": source["workspace_id"],
                                                          "focus": False}, timeout_s=120) or {}
            mirror_id = up(opened.get("workspace_id"))
            if not mirror_id:
                raise Failure(f"vm.workspace_open did not open a mirror of {role}: {opened}")
            mirror_of[source["workspace_id"]] = mirror_id
            self.workspaces.insert(0, mirror_id)
        for role, source in self.sources.items():
            mirror_id = mirror_of[source["workspace_id"]]
            panel = wait_for(f"the mirror pane of {role}",
                             lambda m=mirror_id, s=source: self.mirror_panel_for(m, s["surface_id"]), self.timeout)
            self.mirrors[role] = {"workspace_id": mirror_id, "panel_id": panel}
        self.echo_focused()
        for role in ("tick_a", "tick_b", "tick_c", "tick_d", "flood"):
            mirror = self.mirrors[role]
            wait_for(f"{role}'s history in its mirror", lambda m=mirror, r=role: f"HISTORY-DONE-{r}" in
                     self.read_text(m["workspace_id"], m["panel_id"], scrollback=True), 120, 1.0)
        wait_for("ECHO-READY in the ECHO mirror", lambda: "ECHO-READY" in self.read_text(
            self.mirrors["echo"]["workspace_id"], self.mirrors["echo"]["panel_id"], scrollback=True), self.timeout)
        time.sleep(4.0)  # hidden mirrors turn background after 2 s; let the watch settle
        self.facts.update(machine=self.machine, sources=self.sources, mirrors=self.mirrors)
        return {"mirrors": len(self.mirrors), "auto_mirror_was": self.auto_mirror_was}

    def impairment_on(self) -> Dict[str, Any]:
        status = self.impairment(rtt_ms=RTT_MS, bytes_per_second=BYTES_PER_SECOND, queue_bytes=QUEUE_BYTES,
                                 drop_every_s=0, drop_for_s=0, reset_stats=True)
        if status.get("rtt_ms") != RTT_MS or status.get("bytes_per_second") != BYTES_PER_SECOND:
            raise Failure(f"the impairment did not take: {status}")
        if not status.get("live_connections"):
            raise Failure(f"no live loopback connection is registered for drops: {status}")
        self.facts["impairment"] = status
        return {"impairment": status}

    def baseline_echo(self) -> Dict[str, Any]:
        self.echo_focused()
        self.poll_echo()
        phase = Phase("baseline", len(self.recorder()))
        for key in "01234567":
            self.type_key(phase, key)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and self.echo_pending(phase):
                self.poll_echo()
                time.sleep(0.03)
            time.sleep(0.2)
        result = self.phase_result(phase)
        self.facts["baseline_echo"] = result
        if result["dropped"] or result["not_echoed"] or result["unexpected"]:
            raise Failure(f"keys lost on an unloaded impaired link (harness problem?): {result}")
        if (result["echo_max_ms"] or 0) > BASELINE_ECHO_BOUND_S * 1000:
            raise Failure(f"echo slower than {BASELINE_ECHO_BOUND_S} s without load: {result}")
        if (result["echo_p50_ms"] or 0) < RTT_MS * 0.9:
            raise Failure(f"echo faster than the {RTT_MS} ms round trip: the impairment is not applied: {result}")
        return {k: result[k] for k in ("echo_p50_ms", "echo_p95_ms", "echo_max_ms")}

    def link_saturated(self) -> Dict[str, Any]:
        self.flood_control.touch()
        self.flood_started = time.monotonic()
        self.d2_before = self.link_status()
        self.d2_log_offset = self.log_offset()
        time.sleep(5.0)
        before = self.impairment()["to_viewer"]["delivered_bytes"]
        started = time.monotonic()
        time.sleep(5.0)
        after = self.impairment()
        rate = (after["to_viewer"]["delivered_bytes"] - before) / (time.monotonic() - started)
        result = {"to_viewer_bytes_per_second": int(rate), "cap": BYTES_PER_SECOND,
                  "peak_queued_to_viewer": after["to_viewer"]["peak_queued_bytes"],
                  "writes_waited_to_viewer": after["to_viewer"]["writes_waited"]}
        self.facts["link_saturated"] = result
        if not 0.8 * BYTES_PER_SECOND <= rate <= 1.2 * BYTES_PER_SECOND:
            raise Failure(f"the flood does not fill the link at its cap: {result}")
        return result

    def echo_under_flood(self) -> Dict[str, Any]:
        self.echo_focused()
        self.poll_echo()
        phase = Phase("d1", len(self.recorder()))
        next_press = time.monotonic()
        next_sample = time.monotonic()
        keys = list(D1_KEYS)
        deadline: Optional[float] = None
        while True:
            now = time.monotonic()
            if keys and now >= next_press:
                self.type_key(phase, keys.pop(0))
                next_press += D1_SPACING_S
                if not keys:
                    deadline = now + D1_ECHO_WAIT_S
            if now >= next_sample:
                self.link_status()
                next_sample = now + 1.0
            self.poll_echo()
            if deadline is not None and (now > deadline or not self.echo_pending(phase)):
                break
            time.sleep(0.03)
        result = self.phase_result(phase)
        self.facts["d1"] = result
        summary = {k: result[k] for k in ("echo_p50_ms", "echo_p95_ms", "echo_max_ms", "dropped", "not_echoed",
                                          "unexpected")}
        problems = []
        if result["dropped"] or result["unexpected"]:
            problems.append(f"keys not received exactly once: dropped={result['dropped']} extra={result['unexpected']}")
        if result["not_echoed"]:
            problems.append(f"keys never echoed within {D1_ECHO_WAIT_S:.0f} s: {result['not_echoed']}")
        if result["echo_p95_ms"] is None or result["echo_p95_ms"] > D1_P95_BOUND_S * 1000:
            problems.append(f"echo p95 {result['echo_p95_ms']} ms > {D1_P95_BOUND_S * 1000:.0f} ms")
        if problems:
            raise Failure("; ".join(problems) + f": {summary}")
        return summary

    def no_redial_under_flood(self) -> Dict[str, Any]:
        if self.flood_started is None:
            raise Failure("the flood never started")
        while time.monotonic() - self.flood_started < D2_WINDOW_S:
            self.link_status()
            time.sleep(1.0)
        after = self.link_status()
        window = [s for s in self.link_samples if s["t"] >= self.d2_before["t"]]
        not_connected = [s for s in window if s["phase"] != "connected"]
        host = self.host_replays(self.log_since(self.d2_log_offset))
        result = {
            "seconds": round(time.monotonic() - self.flood_started, 1),
            "redials": (after["admitted"] or 0) - (self.d2_before["admitted"] or 0),
            "samples_not_connected": len(not_connected),
            "host": host,
        }
        self.facts["d2"] = result
        if result["redials"] or not_connected:
            raise Failure(f"the link redialed under a sustained flood: {result}")
        return result

    def flood_drained(self) -> Dict[str, Any]:
        self.flood_control.unlink(missing_ok=True)
        stopped = time.monotonic()
        phase = Phase("drain", len(self.recorder()))
        probes = iter("abcdefghijklmnopqrstuvwxyz0123456789" * 3)
        last: Dict[str, Any] = {}
        while time.monotonic() - stopped < DRAIN_TIMEOUT_S:
            self.echo_focused()
            self.type_key(phase, next(probes))
            pressed = time.monotonic()
            while time.monotonic() - pressed < 2.0 and self.echo_pending(phase):
                self.poll_echo()
                time.sleep(0.05)
            last = self.phase_result(phase)
            fresh = last["keys"][-1] if last["keys"] else {}
            if fresh.get("echo_ms") is not None and fresh["echo_ms"] <= D1_P95_BOUND_S * 1000:
                result = {"drained_after_s": round(time.monotonic() - stopped, 1), "probes": len(phase.typed)}
                self.facts["drain"] = {**result, "keys": last["keys"]}
                return result
            self.poll_echo()
        self.facts["drain"] = last
        raise Failure(f"echo still slower than {D1_P95_BOUND_S} s {DRAIN_TIMEOUT_S:.0f} s after the flood stopped")

    def typing_during_reattach(self) -> Dict[str, Any]:
        self.echo_focused()
        time.sleep(1.0)
        self.input_stats(reset=True)
        phase = Phase("d4", len(self.recorder()))
        echo = self.mirrors["echo"]
        self.sock.call("supermux.devices.terminal_close.replay",
                       {"workspace_id": echo["workspace_id"], "panel_id": echo["panel_id"]})
        for key in D4_KEYS:
            self.type_key(phase, key)
            time.sleep(D4_SPACING_S)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and self.echo_pending(phase):
            self.poll_echo()
            time.sleep(0.05)
        time.sleep(2.0)
        self.poll_echo()
        result = self.phase_result(phase)
        stats = self.input_stats()
        self.facts["d4"] = {**result, "input_stats": stats}
        summary = {"typed": result["typed"], "received": result["received"], "dropped": result["dropped"],
                   "dropped_while_detached": stats.get("dropped_while_detached")}
        if result["dropped"] or result["unexpected"] or result["received"] != result["typed"]:
            raise Failure(f"keys typed during the re-attach did not arrive exactly once: {summary}")
        return summary

    def recovers_after_drop(self) -> Dict[str, Any]:
        self.echo_focused()
        time.sleep(2.0)
        before_stats = self.stream_stats()
        baseline = [self.link_status()["main_rtt_ms"] for _ in range(10)]
        before = self.link_status()
        offset = self.log_offset()
        dropped = self.impairment(drop_now_s=D3_DROP_S, drop_cuts=True)
        drop_started = time.monotonic()
        drop_ends = drop_started + D3_DROP_S
        drop_ends_wall = time.time() + D3_DROP_S
        phase = Phase("d3", len(self.recorder()))
        probes = list(D3_PROBE_KEYS)
        reconnected_at: Optional[float] = None
        first_echo_at: Optional[float] = None
        detached_since: Dict[str, float] = {}
        longest_detached: Dict[str, float] = {}
        main_rtts: List[int] = []
        next_probe = drop_ends
        next_inspect = time.monotonic()
        while time.monotonic() - drop_started < D3_WINDOW_S:
            now = time.monotonic()
            sample = self.link_status()
            if now - drop_ends <= D5_WINDOW_S and now >= drop_ends:
                main_rtts.append(sample["main_rtt_ms"])
            connected = sample["phase"] == "connected" and (sample["admitted"] or 0) > (before["admitted"] or 0)
            if connected and reconnected_at is None:
                reconnected_at = now
            if now >= next_inspect:
                next_inspect = now + 1.0
                self.note_detached(connected, detached_since, longest_detached)
            if first_echo_at is None and probes and now >= next_probe:
                self.type_key(phase, probes.pop(0))
                next_probe = now + 1.0
            if phase.typed:
                self.poll_echo()
            if first_echo_at is None and phase.typed:
                result = self.phase_result(phase)
                echoed = [k for k in result["keys"] if k.get("echo_ms") is not None]
                if echoed:
                    first_echo_at = echoed[0]["pressed_at"] + echoed[0]["echo_ms"] / 1000
            time.sleep(0.25)
        window_end = self.link_status()
        settle_deadline = time.monotonic() + D3_SETTLE_S
        final_panes: Dict[str, Dict[str, Any]] = {}
        while True:
            final_panes = self.pane_states()
            if all(p.get("attached") for p in final_panes.values()) or time.monotonic() > settle_deadline:
                break
            time.sleep(1.0)
        after_stats = self.stream_stats()
        host = self.host_replays(self.log_since(offset))
        self.poll_echo()
        echo_result = self.phase_result(phase)
        per_pane = {}
        for role, mirror in self.mirrors.items():
            b, a = before_stats.get(mirror["panel_id"], {}), after_stats.get(mirror["panel_id"], {})
            delta = {key: int(a.get(key, 0)) - int(b.get(key, 0))
                     for key in ("replay_requests", "full_replays", "resumes", "replay_confirmations", "gaps",
                                 "grid_resyncs")}
            delta["asks_beyond_one"] = delta["replay_requests"] - delta["replay_confirmations"] - 1
            per_pane[role] = delta
        redials = (window_end["admitted"] or 0) - (before["admitted"] or 0)
        first_echo_s = None if first_echo_at is None else round(first_echo_at - drop_ends_wall, 2)
        result = {
            "drop": {k: dropped.get(k) for k in ("drops_started", "connections_cut", "drop_ends_in_ms")},
            "reconnected_after_s": round(reconnected_at - drop_started, 2) if reconnected_at else None,
            "redials_in_window": redials,
            "unplanned_redials": max(0, redials - 1),
            "first_echo_after_drop_end_s": first_echo_s,
            "per_pane": per_pane,
            "longest_detached_on_live_link_s": {k: round(v, 1) for k, v in longest_detached.items()},
            "final_panes": final_panes,
            "host": host,
            "probe_keys": echo_result,
        }
        self.d5 = {"baseline_main_rtt_ms": baseline, "main_rtt_ms": main_rtts}
        self.facts["d3"] = result
        problems = []
        if not dropped.get("connections_cut"):
            problems.append("the drop cut no connection (harness problem)")
        if reconnected_at is None:
            problems.append("the link never reconnected")
        if result["unplanned_redials"]:
            problems.append(f"{result['unplanned_redials']} unplanned redial(s)")
        extra = {role: d["asks_beyond_one"] for role, d in per_pane.items() if d["asks_beyond_one"] > 0}
        if extra:
            problems.append(f"panes asked for more than one replay: {extra}")
        if first_echo_s is None or first_echo_s > D3_ECHO_BOUND_S:
            problems.append(f"the ECHO mirror echoed {first_echo_s} s after the drop ended (bound {D3_ECHO_BOUND_S} s)")
        stuck = [role for role, pane in final_panes.items() if not pane.get("attached")]
        if stuck:
            problems.append(f"panes not attached {D3_SETTLE_S:.0f} s after the window: {stuck}")
        if problems:
            raise Failure("; ".join(problems) + f": {json.dumps({k: result[k] for k in ('reconnected_after_s', 'redials_in_window', 'first_echo_after_drop_end_s', 'per_pane')})}")
        return {k: result[k] for k in ("reconnected_after_s", "redials_in_window", "first_echo_after_drop_end_s",
                                       "per_pane")}

    def pane_states(self) -> Dict[str, Dict[str, Any]]:
        states: Dict[str, Dict[str, Any]] = {}
        by_workspace: Dict[str, List[Dict[str, Any]]] = {}
        for role, mirror in self.mirrors.items():
            if mirror["workspace_id"] not in by_workspace:
                by_workspace[mirror["workspace_id"]] = self.panes(mirror["workspace_id"])
            pane = next((p for p in by_workspace[mirror["workspace_id"]] if up(p.get("panel_id")) == mirror["panel_id"]),
                        {})
            states[role] = {"attached": pane.get("attached"), "connecting": pane.get("connecting"),
                            "overlay_title": pane.get("overlay_title")}
        return states

    def note_detached(self, link_connected: bool, since: Dict[str, float], longest: Dict[str, float]) -> None:
        """Tracks how long each pane sits neither attached nor attaching while the
        link is connected: the "disconnected until Retry" state."""
        now = time.monotonic()
        for role, state in self.pane_states().items():
            stuck = link_connected and not state.get("attached") and not state.get("connecting")
            if stuck:
                since.setdefault(role, now)
                longest[role] = max(longest.get(role, 0.0), now - since[role])
            else:
                since.pop(role, None)

    def host_main_responsive(self) -> Dict[str, Any]:
        d5 = self.d5
        if not d5.get("main_rtt_ms"):
            raise Failure("no main-thread samples (the drop step did not run)")
        samples = d5["main_rtt_ms"]
        result = {
            "baseline_p95_ms": percentile(d5["baseline_main_rtt_ms"], 0.95),
            "samples": len(samples),
            "p50_ms": percentile(samples, 0.5),
            "p95_ms": percentile(samples, 0.95),
            "max_ms": max(samples),
            "over_bound": sum(1 for s in samples if s > D5_MAX_BOUND_S * 1000),
        }
        self.facts["d5"] = {**result, "main_rtt_ms": samples}
        if result["max_ms"] > D5_MAX_BOUND_S * 1000:
            raise Failure(f"the main thread stalled {result['max_ms']} ms (bound {D5_MAX_BOUND_S * 1000:.0f} ms) "
                          f"during the reconnect: {result}")
        return result

    # -- run ---------------------------------------------------------------------

    def cleanup(self) -> None:
        self.flood_control.unlink(missing_ok=True)
        try:
            self.impairment(reset=True)
        except Failure as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))
        if self.keep:
            return
        for workspace_id in self.workspaces:
            try:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except Failure as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))
        if self.auto_mirror_was:
            try:
                self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True})
            except Failure as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        try:
            ok = self.step("setup", self.setup) and self.step("impairment_on", self.impairment_on)
            if ok:
                self.step("baseline_echo", self.baseline_echo)
                self.step("link_saturated", self.link_saturated)
                self.step("D1_echo_under_flood", self.echo_under_flood)
                self.step("D2_no_redial_under_flood", self.no_redial_under_flood)
                self.step("flood_drained", self.flood_drained)
                self.step("D4_typing_during_reattach", self.typing_during_reattach)
                self.step("D3_recovers_after_drop", self.recovers_after_drop)
                self.step("D5_host_main_responsive", self.host_main_responsive)
        except (OSError, ValueError) as error:
            self.steps.append({"name": "transport", "ok": False, "error": str(error)})
        finally:
            self.facts["link_samples"] = self.link_samples
            self.facts["echo_anomalies"] = self.echo_anomalies
            try:
                self.facts["final_impairment"] = self.impairment()
            except Failure as error:
                self.facts["final_impairment"] = str(error)
            self.cleanup()
        return bool(self.steps) and all(step.get("ok") for step in self.steps)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tag's socket (default /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH)")
    parser.add_argument("--log", help="the tag's debug log (default /tmp/cmux-debug-<tag>.log)")
    parser.add_argument("--scratch", help="scratch directory for the programs and the ECHO log")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait before a setup check gives up")
    parser.add_argument("--keep", action="store_true", help="leave the sources and mirrors open")
    parser.add_argument("--report", help="also write the report here")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    path = args.socket or socket_path_for_tag(args.tag)
    slug = Path(socket_path_for_tag(args.tag or "socket")).stem.replace("cmux-debug-", "")
    args.log = args.log or f"/tmp/cmux-debug-{slug}.log"
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path, timeout_s=60.0)
    try:
        sock.connect()
        test = DegradedLinkE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-degraded-link-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "link": {"rtt_ms": RTT_MS, "bytes_per_second": BYTES_PER_SECOND, "queue_bytes": QUEUE_BYTES,
                 "flood_bytes_per_second": FLOOD_BYTES_PER_SECOND, "history_lines": HISTORY_LINES},
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    text = json.dumps(report, indent=2) + "\n"
    artifact = ARTIFACTS_DIR / f"loopback_degraded_link_e2e-{args.tag or 'socket'}.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    artifact.write_text(text, encoding="utf-8")
    if args.report and Path(args.report).resolve() != artifact.resolve():
        Path(args.report).parent.mkdir(parents=True, exist_ok=True)
        Path(args.report).write_text(text, encoding="utf-8")
    print(json.dumps({"passed": passed, "steps": [{k: s.get(k) for k in ("name", "ok", "error", "seconds")}
                                                  for s in steps]}, indent=2))
    print(f"report: {artifact}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
