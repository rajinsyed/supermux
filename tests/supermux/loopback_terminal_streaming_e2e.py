#!/usr/bin/env python3
"""Loopback E2E: a device mirror streams its terminal like a local one.

One tagged DEBUG build acts as both Macs (LOOPBACK-HARNESS.md). The suite
opens a mirror of one source terminal (the WATCHED terminal) and keeps a second
source terminal without any mirror (the UNWATCHED terminal), then checks:

  1. burst_arrives_complete_without_replay: `seq 1 200000` in the watched
     terminal, while the unwatched terminal floods (`seq 1 3000000`), reaches
     the mirror without a single full replay (render-grid re-anchor) of the
     watched terminal, and the mirror's last 2000 lines equal the source's.
  2. unwatched_terminal_bytes_not_sent: `seq 1 50000` in the unwatched
     terminal sends none of its bytes over the link (the viewer's per-surface
     byte counter, `supermux.devices.terminal_stream.stats`), while the watched
     terminal's bytes are counted.
  3. reanchor_resumes_from_bytes: a forced re-anchor of the mirror pane (the
     DEBUG `terminal_close.replay`, what a dropped chunk starts) resumes from the
     mirror's byte position instead of a full replay.
  4. remote_resize_reanchors: the source grid changes twice (a fake phone
     reports a small viewport, then a less small one); the mirror re-anchors
     on each (`grid_resyncs`, a full replay at the new grid: bytes written for
     one grid are never drawn into another; until 2026-10-04 a resize only
     re-pinned and output around it garbled, see
     loopback_terminal_resize_integrity_e2e.py) and output after each resize
     still arrives.
  5. scrollback_survives_link_drop: 3000 numbered lines, then the link drops
     and comes back while the source prints more; afterwards the mirror still
     has every one of the 3000 lines (a full replay used to cut history to ~240
     rows) and the output printed while the link was down.
  6. older_host_keeps_upstream_path: the host plays a build without
     `supermux.terminal_stream.v1` (DEBUG `terminal_stream.pretend_old_host`);
     after a reconnect the mirror attaches and streams the old way (topic-wide
     bytes, the unwatched terminal's included), then streams again once the
     host is current.

Full replays are counted from the host's own DEBUG log line
(`mobile.terminal.replay surface=<id8> renderGrid=`), which every build writes,
so the counts compare against the unmodified base build.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_terminal_streaming_e2e.py [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

LOOPBACK_DEVICE_ID = "5e1f10b0-0000-4000-8000-000000000001"
LOOPBACK_MACHINE_PREFIX = f"device:{LOOPBACK_DEVICE_ID}@"
REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = REPO_ROOT / "tests" / "supermux" / "artifacts"
BURST_LINES = 200000
FLOOD_LINES = 3000000
UNWATCHED_LINES = 50000
HISTORY_LINES = 3000
TAIL_LINES = 2000


class Failure(Exception):
    """A check failed; the message says which and why."""


class SocketClient:
    """Minimal newline-delimited JSON client for the cmux v2 control socket."""

    def __init__(self, path: str, timeout_s: float = 60.0) -> None:
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

    def call(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Any:
        assert self._sock is not None, "not connected"
        request_id = self._next_id
        self._next_id += 1
        line = json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n"
        self._sock.sendall(line.encode("utf-8"))
        response = json.loads(self._read_line(timeout_s or self.timeout_s))
        if response.get("id") != request_id:
            raise Failure(f"{method}: mismatched response id {response.get('id')} != {request_id}")
        if response.get("ok") is True:
            return response.get("result")
        error = response.get("error") or {}
        raise Failure(f"{method}: {error.get('code', 'error')}: {error.get('message', 'unknown error')}")

    def _read_line(self, timeout_s: float) -> str:
        assert self._sock is not None
        deadline = time.monotonic() + timeout_s
        while b"\n" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Failure("socket response timed out")
            self._sock.settimeout(remaining)
            chunk = self._sock.recv(1 << 20)
            if not chunk:
                raise Failure("socket closed by the app")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        return line.decode("utf-8", errors="replace")


def slug(tag: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", tag.strip().lower())).strip("-")


def wait_for(description: str, probe: Callable[[], Any], timeout_s: float, interval_s: float = 0.5) -> Any:
    deadline = time.monotonic() + timeout_s
    last_error: Optional[str] = None
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value:
                return value
        except Failure as error:
            last_error = str(error)
        time.sleep(interval_s)
    suffix = f" (last error: {last_error})" if last_error else ""
    raise Failure(f"timed out after {timeout_s:.0f}s waiting for {description}{suffix}")


def norm(identifier: Any) -> str:
    return str(identifier or "").strip().lower()


def text_lines(text: str) -> List[str]:
    lines = [line.rstrip() for line in text.replace("\r\n", "\n").split("\n")]
    while lines and not lines[-1]:
        lines.pop()
    return lines


class StreamingE2E:
    def __init__(self, client: SocketClient, log_path: Path, timeout_s: float) -> None:
        self.client = client
        self.log_path = log_path
        self.timeout_s = timeout_s
        self.nonce = uuid.uuid4().hex[:8]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "debug_log": str(log_path)}
        self.workspaces: List[str] = []
        self.viewport_reports: List[Dict[str, Any]] = []

    # -- socket helpers -------------------------------------------------------

    def catalog(self) -> Dict[str, Any]:
        return self.client.call("surface.catalog", {}) or {}

    def machine(self) -> str:
        return self.facts["machine"]

    def read_text(self, workspace_id: str, surface_id: str) -> str:
        result = self.client.call(
            "surface.read_text",
            {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True},
            timeout_s=120,
        ) or {}
        return str(result.get("text") or "")

    def send_text(self, workspace_id: str, surface_id: str, text: str) -> None:
        self.client.call("surface.send_text", {"workspace_id": workspace_id, "surface_id": surface_id, "text": text})

    def link(self, action: str, **extra: Any) -> Dict[str, Any]:
        return self.client.call("supermux.devices.link", {"machine": self.machine(), "action": action, **extra}) or {}

    def stats(self) -> Dict[str, Any]:
        return self.client.call("supermux.devices.terminal_stream.stats", {"machine": self.machine()}) or {}

    def pane_stats(self) -> Dict[str, Any]:
        for pane in self.stats().get("panes") or []:
            if norm(pane.get("panel_id")) == norm(self.facts["mirror_surface_id"]):
                return pane
        raise Failure(f"no stream stats for the mirror pane {self.facts['mirror_surface_id']}")

    def link_bytes(self, remote_surface_id: str) -> int:
        received = self.stats().get("bytes_received_by_surface") or {}
        return int(next((v for k, v in received.items() if norm(k) == norm(remote_surface_id)), 0))

    def full_replays(self, surface_id: str) -> int:
        """Host-side full replays of one source terminal, from the DEBUG log."""
        needle = f"mobile.terminal.replay surface={surface_id.upper()[:8]} renderGrid="
        needle_lower = f"mobile.terminal.replay surface={surface_id.lower()[:8]} renderGrid="
        try:
            with self.log_path.open("r", encoding="utf-8", errors="replace") as handle:
                return sum(1 for line in handle if needle in line or needle_lower in line)
        except OSError as error:
            raise Failure(f"cannot read the debug log {self.log_path}: {error}")

    def settled_full_replays(self, surface_id: str) -> int:
        time.sleep(1.5)  # the debug log is written asynchronously
        return self.full_replays(surface_id)

    def mirror_pane(self) -> Dict[str, Any]:
        inspected = self.client.call(
            "supermux.devices.terminal_close.inspect", {"workspace_id": self.facts["mirror_workspace_id"]}
        ) or {}
        for pane in inspected.get("panes") or []:
            if norm(pane.get("panel_id")) == norm(self.facts["mirror_surface_id"]):
                return pane
        raise Failure(f"the mirror pane is not in {inspected}")

    def wait_attached(self) -> None:
        wait_for("the mirror pane to be attached", lambda: self.mirror_pane().get("attached"), self.timeout_s)

    def wait_text(self, description: str, workspace_id: str, surface_id: str, needle: str, timeout_s: float) -> str:
        holder: Dict[str, str] = {}

        def probe() -> bool:
            holder["text"] = self.read_text(workspace_id, surface_id)
            return needle in holder["text"]

        wait_for(description, probe, timeout_s, interval_s=1.0)
        return holder["text"]

    def grid(self, surface_id: str) -> Optional[tuple]:
        state = (self.client.call("terminal.size_state", {"surface_id": surface_id}) or {}).get("size_state") or {}
        if state.get("cols") is None or state.get("rows") is None:
            return None
        return (int(state["cols"]), int(state["rows"]))

    # -- steps ----------------------------------------------------------------

    def step(self, name: str, action: Callable[[], Dict[str, Any]], required: bool = False) -> bool:
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
        if required and not record["ok"]:
            raise Failure(f"{name}: {record['error']}")
        return bool(record["ok"])

    def setup(self) -> Dict[str, Any]:
        def connected() -> Optional[Dict[str, Any]]:
            for machine in self.catalog().get("machines") or []:
                if str(machine.get("id", "")).startswith(LOOPBACK_MACHINE_PREFIX) and machine.get("link_state") == "connected":
                    return machine
            return None

        machine = wait_for("the loopback device to connect", connected, self.timeout_s)
        self.facts["machine"] = machine["id"]
        listed = self.client.call("supermux.devices.list", {}) or {}
        self.facts["auto_mirror_was"] = listed.get("auto_mirror")
        if listed.get("auto_mirror"):
            self.client.call("supermux.devices.set_auto_mirror", {"enabled": False})

        watched_ws, watched_surface = self.create_source("stream-watched")
        unwatched_ws, unwatched_surface = self.create_source("stream-unwatched")
        result = self.client.call(
            "vm.workspace_open", {"id": self.machine(), "workspace_id": watched_ws, "focus": False}, timeout_s=120
        ) or {}
        mirror_id, surfaces = result.get("workspace_id"), result.get("surface_ids") or []
        if not mirror_id or not surfaces:
            raise Failure(f"vm.workspace_open did not open a mirror: {result}")
        self.workspaces.insert(0, str(mirror_id))
        self.facts.update({
            "watched_workspace_id": watched_ws, "watched_surface_id": watched_surface,
            "unwatched_workspace_id": unwatched_ws, "unwatched_surface_id": unwatched_surface,
            "mirror_workspace_id": str(mirror_id), "mirror_surface_id": surfaces[0],
        })
        self.wait_attached()
        marker = f"STREAM_READY_{self.nonce}"
        self.send_text(watched_ws, watched_surface, f"echo STREAM_READY_{'$'}{{X:-}}{self.nonce}\n")
        self.wait_text("the ready marker in the mirror", str(mirror_id), surfaces[0], marker, self.timeout_s)
        return {k: self.facts[k] for k in ("watched_surface_id", "unwatched_surface_id", "mirror_surface_id")}

    def create_source(self, label: str) -> tuple:
        title = f"{label}-{self.nonce}"
        result = self.client.call("workspace.create", {"title": title, "focus": False}) or {}
        workspace_id = result.get("workspace_id")
        if not workspace_id:
            raise Failure(f"workspace.create returned no workspace_id: {result}")
        self.workspaces.append(str(workspace_id))
        self.client.call("workspace.rename", {"workspace_id": workspace_id, "title": title})
        surfaces = (self.client.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        terminal = next((s["id"] for s in surfaces if s.get("type") == "terminal"), None)
        if not terminal:
            raise Failure(f"{title} has no terminal: {surfaces}")
        return str(workspace_id), str(terminal)

    def check_burst(self) -> Dict[str, Any]:
        f = self.facts
        before = self.settled_full_replays(f["watched_surface_id"])
        done = f"STREAM_DONE_123_{self.nonce}"
        flood_done = f"FLOOD_DONE_99_{self.nonce}"
        started = time.monotonic()
        # A busy terminal nobody mirrors floods the same Mac meanwhile.
        self.send_text(f["unwatched_workspace_id"], f["unwatched_surface_id"],
                       f"seq 1 {FLOOD_LINES}; echo FLOOD_DONE_$((9*11))_{self.nonce}\n")
        self.send_text(f["watched_workspace_id"], f["watched_surface_id"],
                       f"seq 1 {BURST_LINES}; echo STREAM_DONE_$((3*41))_{self.nonce}\n")
        self.wait_text("the burst's end in the SOURCE", f["watched_workspace_id"], f["watched_surface_id"], done, 180)
        source_done_s = round(time.monotonic() - started, 2)
        mirror_text = self.wait_text("the burst's end in the MIRROR", f["mirror_workspace_id"], f["mirror_surface_id"], done, 180)
        mirror_done_s = round(time.monotonic() - started, 2)
        self.wait_text("the flood's end in its SOURCE", f["unwatched_workspace_id"], f["unwatched_surface_id"], flood_done, 300)
        after = self.settled_full_replays(f["watched_surface_id"])
        source_lines = text_lines(self.read_text(f["watched_workspace_id"], f["watched_surface_id"]))
        mirror_lines = text_lines(mirror_text)
        tail = min(TAIL_LINES, len(source_lines), len(mirror_lines))
        mismatch = next((i for i in range(1, tail + 1) if source_lines[-i] != mirror_lines[-i]), None)
        result = {
            "full_replays_during_burst": after - before,
            "source_done_s": source_done_s,
            "mirror_done_s": mirror_done_s,
            "compared_tail_lines": tail,
        }
        if after != before:
            raise Failure(f"{after - before} full replay(s) of the watched terminal during the burst: {result}")
        if tail < TAIL_LINES:
            raise Failure(f"only {tail} lines to compare: {result}")
        if mismatch is not None:
            raise Failure(
                f"the mirror's tail differs from the source's {mismatch} lines from the end:"
                f" source={source_lines[-mismatch]!r} mirror={mirror_lines[-mismatch]!r}"
            )
        if str(BURST_LINES) not in mirror_lines:
            raise Failure(f"the mirror has no line {BURST_LINES}")
        return result

    def check_unwatched(self) -> Dict[str, Any]:
        f = self.facts
        stats = self.stats()
        unwatched_before = self.link_bytes(f["unwatched_surface_id"])
        watched_before = self.link_bytes(f["watched_surface_id"])
        done = f"UNWATCHED_DONE_42_{self.nonce}"
        self.send_text(f["unwatched_workspace_id"], f["unwatched_surface_id"],
                       f"seq 1 {UNWATCHED_LINES}; echo UNWATCHED_DONE_$((6*7))_{self.nonce}\n")
        self.wait_text("the unwatched burst's end in its SOURCE", f["unwatched_workspace_id"], f["unwatched_surface_id"], done, 120)
        marker = f"WATCHED_AFTER_64_{self.nonce}"
        self.send_text(f["watched_workspace_id"], f["watched_surface_id"], f"echo WATCHED_AFTER_$((8*8))_{self.nonce}\n")
        self.wait_text("watched output in the MIRROR", f["mirror_workspace_id"], f["mirror_surface_id"], marker, self.timeout_s)
        time.sleep(1.0)
        unwatched_after = self.link_bytes(f["unwatched_surface_id"])
        watched_after = self.link_bytes(f["watched_surface_id"])
        result = {
            "unwatched_bytes_received": unwatched_after - unwatched_before,
            "watched_bytes_received": watched_after - watched_before,
            "watching": stats.get("watching"),
            "supported": stats.get("supported"),
        }
        if unwatched_after != unwatched_before:
            raise Failure(f"the unwatched terminal's bytes crossed the link: {result}")
        if watched_after <= watched_before:
            raise Failure(f"the watched terminal's bytes were not counted, so the counter proves nothing: {result}")
        return result

    def report_viewport(self, cols: int, rows: int, clear: bool = False) -> None:
        f = self.facts
        generation = len(self.viewport_reports) + 1
        params: Dict[str, Any] = {
            "workspace_id": f["watched_workspace_id"], "surface_id": f["watched_surface_id"],
            "client_id": f"e2e-phone-{self.nonce}", "viewport_generation": generation,
        }
        if clear:
            params["clear"] = True
        else:
            params.update({"viewport_columns": cols, "viewport_rows": rows, "device_kind": "phone",
                           "device_id": f"e2e-phone-{self.nonce}", "device_name": "E2E phone"})
        self.client.call("mobile.terminal.viewport", params)
        self.viewport_reports.append(params)

    def check_resize(self) -> Dict[str, Any]:
        f = self.facts
        original = self.grid(f["watched_surface_id"])
        if original is None:
            raise Failure("the watched terminal reports no grid")
        before = self.settled_full_replays(f["watched_surface_id"])
        resyncs_before = int(self.pane_stats().get("grid_resyncs", 0))
        # Fit everyone sizes to the smallest counting viewer, so the fake
        # phone's viewport decides the grid (the panes count only on screen).
        smallest = (max(20, original[0] - 17), max(6, original[1] - 5))
        self.report_viewport(*smallest)
        shrunk = wait_for("the source grid to shrink", lambda: (g := self.grid(f["watched_surface_id"])) == smallest and g, self.timeout_s)
        marker1 = f"AFTER_SHRINK_9_{self.nonce}"
        self.send_text(f["watched_workspace_id"], f["watched_surface_id"], f"echo AFTER_SHRINK_$((3*3))_{self.nonce}\n")
        self.wait_text("output after the shrink in the MIRROR", f["mirror_workspace_id"], f["mirror_surface_id"], marker1, self.timeout_s)
        larger = (smallest[0] + 7, smallest[1] + 2)
        self.report_viewport(*larger)
        restored = wait_for("the source grid to grow", lambda: (g := self.grid(f["watched_surface_id"])) == larger and g, self.timeout_s)
        marker2 = f"AFTER_GROW_16_{self.nonce}"
        self.send_text(f["watched_workspace_id"], f["watched_surface_id"], f"echo AFTER_GROW_$((4*4))_{self.nonce}\n")
        self.wait_text("output after the growth in the MIRROR", f["mirror_workspace_id"], f["mirror_surface_id"], marker2, self.timeout_s)
        after = self.settled_full_replays(f["watched_surface_id"])
        resyncs = int(self.pane_stats().get("grid_resyncs", 0)) - resyncs_before
        result = {"grids": [list(original), list(shrunk), list(restored)], "full_replays": after - before,
                  "grid_resyncs": resyncs}
        if resyncs < 2 or after - before < 2:
            raise Failure(f"the mirror did not re-anchor on each remote resize: {result}")
        return result

    def check_reanchor(self) -> Dict[str, Any]:
        f = self.facts
        stats_before = self.pane_stats()
        before = self.settled_full_replays(f["watched_surface_id"])
        self.client.call("supermux.devices.terminal_close.replay",
                         {"workspace_id": f["mirror_workspace_id"], "panel_id": f["mirror_surface_id"]})
        time.sleep(0.5)
        self.wait_attached()
        marker = f"AFTER_REANCHOR_25_{self.nonce}"
        self.send_text(f["watched_workspace_id"], f["watched_surface_id"], f"echo AFTER_REANCHOR_$((5*5))_{self.nonce}\n")
        self.wait_text("output after the re-anchor in the MIRROR", f["mirror_workspace_id"], f["mirror_surface_id"], marker, self.timeout_s)
        after = self.settled_full_replays(f["watched_surface_id"])
        stats_after = self.pane_stats()
        result = {
            "full_replays": after - before,
            "resumes": int(stats_after.get("resumes", 0)) - int(stats_before.get("resumes", 0)),
        }
        if after != before:
            raise Failure(f"the re-anchor was a full replay: {result}")
        if result["resumes"] < 1:
            raise Failure(f"the re-anchor did not resume from the byte position: {result}")
        return result

    def check_link_drop(self) -> Dict[str, Any]:
        f = self.facts
        prefix = f"HIST_{self.nonce}_"
        self.send_text(f["watched_workspace_id"], f["watched_surface_id"], f"seq -f '{prefix}%g' 1 {HISTORY_LINES}\n")
        last = f"{prefix}{HISTORY_LINES}"
        self.wait_text("the history in the MIRROR", f["mirror_workspace_id"], f["mirror_surface_id"], last, 120)
        self.link("stop")
        wait_for("the mirror pane to detach", lambda: not self.mirror_pane().get("attached"), self.timeout_s)
        during = f"DURING_DROP_77_{self.nonce}"
        self.send_text(f["watched_workspace_id"], f["watched_surface_id"], f"echo DURING_DROP_$((7*11))_{self.nonce}\n")
        self.wait_text("the during-drop output in the SOURCE", f["watched_workspace_id"], f["watched_surface_id"], during, self.timeout_s)
        self.link("restore")
        self.wait_attached()
        text = self.wait_text("the during-drop output in the MIRROR", f["mirror_workspace_id"], f["mirror_surface_id"], during, 60)
        present = {line for line in text_lines(text) if line.startswith(prefix)}
        missing = [n for n in range(1, HISTORY_LINES + 1) if f"{prefix}{n}" not in present]
        result = {"history_lines_kept": HISTORY_LINES - len(missing)}
        if missing:
            raise Failure(f"{len(missing)} of {HISTORY_LINES} history lines are gone after the reconnect "
                          f"(first missing: {missing[0]}): {result}")
        return result

    def check_older_host(self) -> Dict[str, Any]:
        f = self.facts
        self.client.call("supermux.devices.terminal_stream.pretend_old_host", {"enabled": True})
        try:
            self.link("stop")
            self.link("restore")
            self.wait_attached()
            marker = f"OLD_HOST_36_{self.nonce}"
            self.send_text(f["watched_workspace_id"], f["watched_surface_id"], f"echo OLD_HOST_$((6*6))_{self.nonce}\n")
            self.wait_text("output from an older host in the MIRROR", f["mirror_workspace_id"], f["mirror_surface_id"], marker, self.timeout_s)
            before = self.link_bytes(f["unwatched_surface_id"])
            done = f"OLD_UNWATCHED_49_{self.nonce}"
            self.send_text(f["unwatched_workspace_id"], f["unwatched_surface_id"], f"echo OLD_UNWATCHED_$((7*7))_{self.nonce}\n")
            self.wait_text("the unwatched output in its SOURCE", f["unwatched_workspace_id"], f["unwatched_surface_id"], done, self.timeout_s)
            wait_for("an older host's topic-wide bytes", lambda: self.link_bytes(f["unwatched_surface_id"]) > before, self.timeout_s)
            old = {"streaming": self.pane_stats().get("streaming"), "supported": self.stats().get("supported")}
            if old["streaming"] or old["supported"]:
                raise Failure(f"the mirror streamed although the host does not: {old}")
        finally:
            self.client.call("supermux.devices.terminal_stream.pretend_old_host", {"enabled": False})
            self.link("stop")
            self.link("restore")
        self.wait_attached()
        marker = f"NEW_HOST_81_{self.nonce}"
        self.send_text(f["watched_workspace_id"], f["watched_surface_id"], f"echo NEW_HOST_$((9*9))_{self.nonce}\n")
        self.wait_text("output from the current host in the MIRROR", f["mirror_workspace_id"], f["mirror_surface_id"], marker, self.timeout_s)
        wait_for("the mirror to stream again", lambda: self.pane_stats().get("streaming"), self.timeout_s)
        return {"older_host": old}

    def cleanup(self) -> None:
        f = self.facts
        try:
            self.client.call("supermux.devices.terminal_stream.pretend_old_host", {"enabled": False})
        except Failure:
            pass
        if self.viewport_reports and not self.viewport_reports[-1].get("clear"):
            try:
                self.report_viewport(0, 0, clear=True)
            except Failure as error:
                f.setdefault("cleanup_errors", []).append(str(error))
        try:
            if f.get("machine") and self.link("status").get("phase") != "connected":
                self.link("restore")
        except Failure as error:
            f.setdefault("cleanup_errors", []).append(str(error))
        for workspace_id in self.workspaces:
            try:
                self.client.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except Failure as error:
                f.setdefault("cleanup_errors", []).append(str(error))
        if f.get("auto_mirror_was"):
            try:
                self.client.call("supermux.devices.set_auto_mirror", {"enabled": True})
            except Failure as error:
                f.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        try:
            self.step("setup", self.setup, required=True)
            self.step("burst_arrives_complete_without_replay", self.check_burst)
            self.step("unwatched_terminal_bytes_not_sent", self.check_unwatched)
            # The re-anchor runs before the resizes: the other Mac announces a new
            # grid only with its next output (device.terminal.grid), so right after
            # a resize the mirror may still hold the previous grid, and a resume
            # at a grid the mirror does not have rightly falls back to a replay.
            self.step("reanchor_resumes_from_bytes", self.check_reanchor)
            self.step("remote_resize_reanchors", self.check_resize)
            self.step("scrollback_survives_link_drop", self.check_link_drop)
            self.step("older_host_keeps_upstream_path", self.check_older_host)
        except Failure:
            pass
        except (OSError, ValueError) as error:
            self.steps.append({"name": "transport", "ok": False, "error": str(error)})
        finally:
            self.cleanup()
            try:
                self.facts["final_stats"] = self.stats()
            except Failure as error:
                self.facts["final_stats"] = str(error)
        return all(step.get("ok") for step in self.steps)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tag's socket (default /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH)")
    parser.add_argument("--log", help="the tag's debug log (default /tmp/cmux-debug-<tag>.log)")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    tag_slug = slug(args.tag or "socket")
    socket_path = args.socket or f"/tmp/cmux-debug-{tag_slug}.sock"
    log_path = Path(args.log or f"/tmp/cmux-debug-{tag_slug}.log")

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with SocketClient(socket_path) as client:
            suite = StreamingE2E(client, log_path, timeout_s=args.timeout)
            passed = suite.run()
            steps, facts = suite.steps, suite.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-terminal-streaming",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_terminal_streaming_e2e-{tag_slug}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
