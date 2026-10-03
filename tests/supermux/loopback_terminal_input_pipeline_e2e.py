#!/usr/bin/env python3
"""End-to-end test: typing into another Mac's terminal over a slow link is pipelined,
in order, and exactly once.

A device mirror used to send ONE `mobile.terminal.input` request at a time: keys typed
while it waited for the other Mac's reply queued behind it, so over a relay every burst
paid a full round trip before it even left this Mac. Now (`supermux.terminal_input_pipeline.v1`)
each batch leaves at once with a per-terminal sequence number; the other Mac applies them
strictly in order and drops resends it already applied, and this Mac resends whatever was
not acknowledged after a reconnect.

Runs against one tagged DEBUG build with the loopback device ("Loopback Mac" = this app's
own mobile host): the source workspace is the "other Mac" and its auto mirror is the
viewer. A recorder in the SOURCE terminal logs every read with its arrival time. Keys are
pressed for real in the mirror (debug.shortcut.simulate). The loopback link gets an
artificial one-way latency (supermux.devices.terminal_input.latency), and the mirror's
input counters come from supermux.devices.terminal_input.stats.

  1. setup / source_gets_mirror / recorder_running / mirror_focused
  2. slow_link_typing_is_pipelined  with 250 ms to the other Mac, 8 separate key presses
                                    arrive complete and in order, more than one request is
                                    in flight at once, and no key waits for an earlier
                                    key's reply (each arrives within ~1 one-way delay of
                                    being pressed, not 2+)
  3. lost_requests_resent_after_reconnect
                                    keys still in transit when the link drops are sent
                                    again after it reconnects: each arrives exactly once
  4. applied_input_not_duplicated_after_reconnect
                                    keys the other Mac applied but whose replies were lost
                                    with the link are resent, and the other Mac drops them:
                                    each arrives exactly once
  5. older_host_keeps_one_in_flight a host without the capability (DEBUG pretend-old-host)
                                    still gets every key in order, one request at a time

Writes a JSON report (default tests/supermux/artifacts/loopback_terminal_input_pipeline_e2e-<tag>.json)
with per-key latencies, and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_terminal_input_pipeline_e2e.py [--scratch DIR] [--timeout 30]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))

from loopback_terminal_input_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    Failure,
    Socket,
    TerminalInputE2E,
    socket_path_for_tag,
    wait_for,
)

# Logs every read as "<unix time> <hex>" so the test can time each key's arrival.
RECORDER = r'''
import binascii, os, sys, time, tty
out = sys.argv[1]
fd = sys.stdin.fileno()
tty.setraw(fd)
sys.stdout.write("REC-READY\r\n")
sys.stdout.flush()
with open(out, "ab", 0) as log:
    while True:
        data = os.read(fd, 4096)
        if not data:
            break
        log.write(b"%.6f %s\n" % (time.time(), binascii.hexlify(data)))
'''

ONE_WAY_MS = 250


class PipelineE2E(TerminalInputE2E):
    """Reuses the input suite's setup (loopback link, source, mirror, focus,
    reattach) with a timestamping recorder."""

    def recorder_running(self) -> Dict[str, Any]:
        (self.scratch / "recorder.py").write_text(RECORDER)
        return super().recorder_running()

    # -- recorder log -----------------------------------------------------------

    def arrivals(self) -> List[Tuple[float, bytes]]:
        """Every byte the recorder got, with the time of the read that brought it."""
        try:
            lines = self.log_path.read_text().splitlines()
        except FileNotFoundError:
            return []
        out: List[Tuple[float, bytes]] = []
        for line in lines:
            stamp, _, payload = line.partition(" ")
            for byte in bytes.fromhex(payload.strip()):
                out.append((float(stamp), bytes([byte])))
        return out

    def received_hex(self) -> str:
        return b"".join(byte for _, byte in self.arrivals()).hex()

    # -- drivers ----------------------------------------------------------------

    def latency(self, to_host_ms: int = 0, to_viewer_ms: int = 0) -> None:
        self.sock.call("supermux.devices.terminal_input.latency",
                       {"to_host_ms": to_host_ms, "to_viewer_ms": to_viewer_ms})

    def stats(self, reset: bool = False) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.terminal_input.stats", {"reset": reset}) or {}

    def type_keys(self, text: str, spacing_s: float = 0.03) -> List[float]:
        """Presses each character as its own key event in the mirror; returns press times."""
        pressed: List[float] = []
        for char in text:
            pressed.append(time.time())
            self.sock.call("debug.shortcut.simulate", {"combo": char})
            time.sleep(spacing_s)
        return pressed

    def wait_for_text(self, start: int, text: str, timeout_s: float) -> List[Tuple[float, bytes]]:
        """Waits until the recorder got at least len(text) bytes after `start`."""
        def got() -> Optional[List[Tuple[float, bytes]]]:
            new = self.arrivals()[start:]
            return new if len(new) >= len(text) else None
        try:
            return wait_for(f"the recorder to receive {text!r}", got, timeout_s, 0.05)
        except Failure:
            new = b"".join(byte for _, byte in self.arrivals()[start:])
            raise Failure(f"expected {text!r}, the program received {new!r}")

    def exactly_once(self, start: int, text: str, settle_s: float = 2.0) -> Dict[str, Any]:
        """The recorder got `text` once, in order, and nothing more for `settle_s`."""
        self.wait_for_text(start, text, self.timeout)
        time.sleep(settle_s)
        got = b"".join(byte for _, byte in self.arrivals()[start:])
        if got != text.encode():
            raise Failure(f"expected {text!r} exactly once, the program received {got!r}")
        return {"received": got.decode()}

    # -- steps ------------------------------------------------------------------

    def slow_link_typing_is_pipelined(self) -> Dict[str, Any]:
        text = "pipeline"
        self.mirror_focused()
        self.latency(to_host_ms=ONE_WAY_MS)
        try:
            self.stats(reset=True)
            start = len(self.arrivals())
            pressed = self.type_keys(text)
            arrived = self.wait_for_text(start, text, self.timeout)
            stats = self.stats()
        finally:
            self.latency()
        got = b"".join(byte for _, byte in arrived)
        latencies = [round((arrived[i][0] - pressed[i]) * 1000) for i in range(len(text))]
        total_ms = round((arrived[len(text) - 1][0] - pressed[0]) * 1000)
        typing_ms = round((pressed[-1] - pressed[0]) * 1000)
        facts = {"one_way_ms": ONE_WAY_MS, "per_key_latency_ms": latencies, "max_latency_ms": max(latencies),
                 "total_ms": total_ms, "typing_ms": typing_ms, "stats": stats, "received": got.decode(errors="replace")}
        self.facts["slow_link"] = facts
        if got[:len(text)] != text.encode():
            raise Failure(f"expected {text!r} in order, the program received {got!r}")
        if stats.get("max_in_flight", 0) < 2:
            raise Failure(f"only {stats.get('max_in_flight')} input request(s) were in flight at once: {facts}")
        if max(latencies) > ONE_WAY_MS * 1.5:
            raise Failure(f"a key waited for an earlier key's reply: max latency {max(latencies)} ms "
                          f"> 1.5 x {ONE_WAY_MS} ms one-way: {facts}")
        return facts

    def drop_link_and_restore(self) -> None:
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        time.sleep(1.0)
        self.latency()
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        wait_for("the loopback link to reconnect", lambda: self.device().get("link_state") == "connected", self.timeout)
        wait_for("the mirror to re-attach", lambda: "REC-READY" in self.mirror_text(), self.timeout)

    def lost_requests_resent_after_reconnect(self) -> Dict[str, Any]:
        """Requests still on their way when the link drops are lost with it."""
        text = "lost42"
        self.mirror_focused()
        self.stats(reset=True)
        start = len(self.arrivals())
        self.latency(to_host_ms=3000)
        try:
            self.type_keys(text)
            time.sleep(0.3)
            if self.arrivals()[start:]:
                raise Failure("keys arrived before the link dropped; the latency did not hold them")
            self.drop_link_and_restore()
        finally:
            self.latency()
        result = self.exactly_once(start, text)
        return {**result, "stats": self.stats()}

    def applied_input_not_duplicated_after_reconnect(self) -> Dict[str, Any]:
        """The other Mac applied the keys, but its replies are lost with the link."""
        text = "dup77"
        self.mirror_focused()
        self.stats(reset=True)
        start = len(self.arrivals())
        self.latency(to_viewer_ms=3000)
        try:
            self.type_keys(text)
            self.wait_for_text(start, text, self.timeout)
            self.drop_link_and_restore()
        finally:
            self.latency()
        result = self.exactly_once(start, text)
        stats = self.stats()
        if stats.get("resends", 0) < 1:
            raise Failure(f"the unacknowledged keys were never resent: {stats}")
        return {**result, "stats": stats}

    def older_host_keeps_one_in_flight(self) -> Dict[str, Any]:
        text = "legacy"
        self.sock.call("supermux.devices.terminal_input.pretend_old_host", {"enabled": True})
        try:
            self.reattach()
            self.latency(to_host_ms=ONE_WAY_MS)
            try:
                self.stats(reset=True)
                start = len(self.arrivals())
                self.type_keys(text)
                result = self.exactly_once(start, text, settle_s=0.5)
                stats = self.stats()
            finally:
                self.latency()
        finally:
            self.sock.call("supermux.devices.terminal_input.pretend_old_host", {"enabled": False})
        if stats.get("max_in_flight") != 1 or stats.get("pipelined_requests"):
            raise Failure(f"an older host must get one request at a time without delivery ids: {stats}")
        return {**result, "stats": stats}

    def restore_pipeline(self) -> Dict[str, Any]:
        """Re-attach to the (no longer pretending) host and type once more."""
        self.reattach()
        start = len(self.arrivals())
        self.type_keys("ok")
        return self.exactly_once(start, "ok", settle_s=0.5)

    # -- run --------------------------------------------------------------------

    def cleanup(self) -> None:
        try:
            self.latency()
        except Failure:
            pass
        super().cleanup()

    def run(self) -> bool:
        ok = (self.step("setup", self.setup)
              and self.step("source_gets_mirror", self.source_gets_mirror)
              and self.step("recorder_running", self.recorder_running)
              and self.step("mirror_focused", self.mirror_focused))
        if ok:
            ok = self.step("slow_link_typing_is_pipelined", self.slow_link_typing_is_pipelined) and ok
            ok = self.step("lost_requests_resent_after_reconnect", self.lost_requests_resent_after_reconnect) and ok
            ok = self.step("applied_input_not_duplicated_after_reconnect",
                           self.applied_input_not_duplicated_after_reconnect) and ok
            ok = self.step("older_host_keeps_one_in_flight", self.older_host_keeps_one_in_flight) and ok
            ok = self.step("pipeline_restored", self.restore_pipeline) and ok
        self.facts["received_total"] = bytes.fromhex(self.received_hex()).decode(errors="replace")
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock)")
    parser.add_argument("--scratch", help="scratch directory for the recorder and its log")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait before a check gives up")
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
        test = PipelineE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-terminal-input-pipeline-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_terminal_input_pipeline_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
