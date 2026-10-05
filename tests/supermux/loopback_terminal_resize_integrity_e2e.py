#!/usr/bin/env python3
"""Loopback E2E: a streaming device mirror never garbles while its terminal resizes.

The bug (2026-10-04, Release of main @ f71a249528d): a remote workspace terminal
running Claude Code showed lines wrapped at the wrong column, word fragments at
line starts and single characters stranded at a fixed right-hand column: bytes
the program wrote for one grid were parsed by the mirror at another.

One tagged DEBUG build acts as both Macs (LOOPBACK-HARNESS.md). A source
terminal runs a generator that prints numbered lines wider than any grid and
redraws an ink-style status block in place with relative cursor moves (what
Claude Code does), while the suite keeps changing the terminal's grid: a fake
phone (40x12, 60x20), a fake second Mac (100x30) and clears, through
`mobile.terminal.viewport` on this control socket, plus one link drop and
restore. At quiescence the mirror must show what the source shows: the same
physical rows (history AND screen), grid and cursor, read from both
terminals' render grids (`mobile.terminal.replay` on this control socket; see
`grid_rows` for why not `surface.read_text`).

  1. setup                          the loopback linked, a source workspace and its mirror
  2. resize_storm_mirror_matches    the generator under ~16 grid changes and a link drop;
                                    afterwards source and mirror text are identical
  3. quiet_resizes_mirror_matches   a still screen resized three times (no output between):
                                    the mirror still equals the source
  4. dragged_window_replays_few_times
                                    20 grid steps 40 ms apart (a window dragged on the other
                                    Mac) while output flows. A second connection samples the
                                    source's real grid (the `governor` driver's `surface_grid`,
                                    Ghostty's own size) every 25 ms from the drag's start until
                                    the replays are counted: the grid changes that reached the
                                    PTY (`applied_grid_changes`). Three checks (`drag_verdict`),
                                    and the mirror equals the source:
                                    - the drag reaches the PTY: one of its own grids (rows 24,
                                      cols 50-80) is the governor's applied target at its end;
                                    - the governor bounds the PTY: at most 2 + ceil(drag / 400 ms)
                                      grid changes (the cold cap, one per 400 ms cap window, the
                                      leave), not one per step;
                                    - the mirror replays per applied grid, not per step: at most
                                      2 x `applied_grid_changes` + 2 full replays. Each grid that
                                      lands costs its replay, plus a re-anchor when the next grid
                                      lands while that replay is in flight (verdict `behind`);
                                      the + 2 is the confirmation replay once output is quiet and
                                      a pane-geometry commit after the leave that restores the
                                      pane's pixel box (a host grid generation at the same
                                      cols x rows, which the sampler cannot see).
                                    Per-step replays fail either way: 20 replays against the ~8
                                    that 3 applied grids allow, or, with an ungoverned PTY, ~20
                                    applied grids against a governor bound of ~5.
                                    History: until 2026-10-05 the budget was 4 (the governor was
                                    wedged by the previous step's clear, so the drag never reached
                                    the PTY); then a fixed 6, which failed on the stream's own
                                    variance (5, 6, 7 replays). At 6a16a4ac47e the PTY took 3
                                    grids in each of 7 runs while the mirror replayed 4-6 times, so
                                    `applied_grid_changes` + 2 failed one run in seven (6 replays:
                                    three `behind` re-anchors on the first cap, then the
                                    pane-geometry commit)

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_terminal_resize_integrity_e2e.py [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import re
import socket
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

LOOPBACK_DEVICE_ID = "5e1f10b0-0000-4000-8000-000000000001"
LOOPBACK_MACHINE_PREFIX = f"device:{LOOPBACK_DEVICE_ID}@"
REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = REPO_ROOT / "tests" / "supermux" / "artifacts"

# The source program: numbered lines wider than every grid, and every few lines
# an ink-style block (three status lines) erased with a relative cursor move and
# redrawn, the way Claude Code repaints its prompt area.
GENERATOR = r'''
import sys, time
lines = int(sys.argv[1]); nonce = sys.argv[2]
out = sys.stdout
block = 0
for i in range(1, lines + 1):
    if block:
        out.write("\x1b[%dA\r\x1b[J" % block)
    out.write("L%05d %s %s\n" % (i, nonce, ("abcdefghij" * 14)[: 60 + (i * 7) % 90]))
    block = 0
    if i % 3 == 0:
        for k in range(3):
            out.write("  status %05d.%d %s\n" % (i, k, "xyz-" * (5 + (i + k) % 9)))
        block = 3
    out.flush()
    time.sleep(0.004)
if block:
    out.write("\x1b[%dA\r\x1b[J" % block)
out.write("GEN_DONE_%s_%d\n" % (nonce, 6 * 7))
out.flush()
'''
GENERATOR_LINES = 2500


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


class GridSampler:
    """The source terminal's real grid (the `governor` driver's `surface_grid`,
    Ghostty's own size) sampled on a second connection every `interval_s`
    while a step runs: the grid changes that really reached the PTY. The
    governor applies a cap at most once per 400 ms window and a leave at
    once, so a 25 ms sample sees each of them."""

    def __init__(self, socket_path: str, surface_id: str, interval_s: float = 0.025) -> None:
        self.socket_path = socket_path
        self.surface_id = surface_id
        self.interval_s = interval_s
        self.samples: List[tuple] = []
        self.error: Optional[str] = None
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def __enter__(self) -> "GridSampler":
        self._thread.start()
        # The grid before the step's first change must be on record, or that change goes unseen.
        deadline = time.monotonic() + 10
        while not self.samples and self.error is None and time.monotonic() < deadline:
            time.sleep(0.01)
        return self

    def __exit__(self, *_: Any) -> None:
        self._stop.set()
        self._thread.join(timeout=15)

    def _run(self) -> None:
        try:
            with SocketClient(self.socket_path, timeout_s=15) as client:
                while not self._stop.is_set():
                    reply = client.call("supermux.devices.terminal_sizing.governor", {"surface_id": self.surface_id}) or {}
                    grid = reply.get("surface_grid") or {}
                    if grid.get("cols") is not None and grid.get("rows") is not None:
                        self.samples.append((time.monotonic(), (int(grid["cols"]), int(grid["rows"]))))
                    self._stop.wait(self.interval_s)
        except (Failure, OSError, ValueError) as error:
            self.error = str(error)

    def grids(self) -> List[tuple]:
        """Each grid the PTY took, in order (consecutive repeats collapsed)."""
        seen: List[tuple] = []
        for _, grid in self.samples:
            if not seen or seen[-1] != grid:
                seen.append(grid)
        return seen

    def facts(self) -> Dict[str, Any]:
        times = [t for t, _ in self.samples]
        gaps = [b - a for a, b in zip(times, times[1:])]
        grids = self.grids()
        return {
            "applied_grid_changes": max(len(grids) - 1, 0),
            "applied_grids": [list(grid) for grid in grids],
            "grid_samples": len(self.samples),
            "longest_sample_gap_ms": round(max(gaps) * 1000) if gaps else None,
            "sampler_error": self.error,
        }


def drag_verdict(applied: Optional[Dict[str, Any]], changes: int, replays: int, governor_bound: int,
                 steps: int) -> Optional[str]:
    """What is wrong with a drag (None when nothing): `applied` is the
    governor's target at the drag's end, `changes` the grid changes the PTY
    took, `replays` the mirror's full replays (module docstring, step 4)."""
    applied = applied or {}
    # One of the drag's own grids (rows 24, cols 50-80) must be on the PTY, not an earlier step's cap.
    if applied.get("kind") != "cap" or applied.get("rows") != 24 or not 50 <= int(applied.get("cols", 0)) <= 80:
        return f"the drag never reached the PTY (governor applied {applied})"
    if changes > governor_bound:
        return f"{changes} grid changes reached the PTY for one drag of {steps} steps (governor bound {governor_bound})"
    if replays > 2 * changes + 2:
        return f"{replays} full replays for {changes} applied grid changes ({steps} steps)"
    return None


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


def grid_rows(frame: Dict[str, Any]) -> Dict[str, Any]:
    """A render-grid frame as the physical rows a viewer sees: history, then
    the screen, each row's cells left to right (padding dropped), plus the
    grid and the cursor. `surface.read_text` would join soft-wrapped rows,
    and a replay paints rows as hard lines (it carries no wrap flags), so text
    reads differ where the rows are the same; the rows themselves do not."""
    def paint(spans: List[Dict[str, Any]], count: int) -> List[str]:
        rows = [""] * count
        for span in sorted(spans, key=lambda item: (int(item.get("row", 0)), int(item.get("column", 0)))):
            row = int(span.get("row", 0))
            if 0 <= row < count:
                rows[row] = rows[row].ljust(int(span.get("column", 0))) + str(span.get("text") or "")
        return [row.rstrip() for row in rows]

    history = paint(frame.get("scrollback_spans") or [], int(frame.get("scrollback_rows") or 0))
    screen = paint(frame.get("row_spans") or [], int(frame.get("rows") or 0))
    rows = history + screen
    while rows and not rows[-1]:
        rows.pop()
    cursor = frame.get("cursor") or {}
    return {
        "rows": rows,
        "grid": [frame.get("columns"), frame.get("rows")],
        "cursor": [cursor.get("row"), cursor.get("column")],
        "screen": frame.get("active_screen"),
    }


def first_difference(source: List[str], mirror: List[str]) -> Optional[Dict[str, Any]]:
    """The first differing line counted from the END (the screen), with context."""
    for back in range(1, max(len(source), len(mirror)) + 1):
        s = source[-back] if back <= len(source) else None
        m = mirror[-back] if back <= len(mirror) else None
        if s != m:
            return {
                "lines_from_end": back,
                "source": s,
                "mirror": m,
                "source_context": source[max(0, len(source) - back - 3): len(source) - back + 4],
                "mirror_context": mirror[max(0, len(mirror) - back - 3): len(mirror) - back + 4],
            }
    return None


class ResizeIntegrityE2E:
    def __init__(self, client: SocketClient, timeout_s: float, seed: int) -> None:
        self.client = client
        self.timeout_s = timeout_s
        self.nonce = uuid.uuid4().hex[:8]
        self.random = random.Random(seed)
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "seed": seed}
        self.workspaces: List[str] = []
        self.generation = 0
        self.reported_clients: set = set()
        self.script_path = Path(f"/tmp/supermux-resize-integrity-{self.nonce}.py")

    # -- socket helpers -------------------------------------------------------

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

    def link(self, action: str) -> Dict[str, Any]:
        return self.client.call("supermux.devices.link", {"machine": self.machine(), "action": action}) or {}

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

    def grid(self) -> Optional[tuple]:
        state = (self.client.call("terminal.size_state", {"surface_id": self.facts["source_surface_id"]}) or {}).get("size_state") or {}
        if state.get("cols") is None or state.get("rows") is None:
            return None
        return (int(state["cols"]), int(state["rows"]))

    def report_viewport(self, client: str, kind: str, cols: int = 0, rows: int = 0, clear: bool = False) -> None:
        f = self.facts
        self.generation += 1
        client_id = f"e2e-{client}-{self.nonce}"
        params: Dict[str, Any] = {
            "workspace_id": f["source_workspace_id"], "surface_id": f["source_surface_id"],
            "client_id": client_id, "viewport_generation": self.generation,
        }
        if clear:
            params["clear"] = True
            self.reported_clients.discard(client)
        else:
            params.update({"viewport_columns": cols, "viewport_rows": rows, "device_kind": kind,
                           "device_id": client_id, "device_name": f"E2E {client}", "view_appeared": True})
            self.reported_clients.add(client)
        self.client.call("mobile.terminal.viewport", params)

    def governor_applied(self) -> Optional[Dict[str, Any]]:
        """The target the source's apply governor last put on the PTY (DEBUG driver)."""
        reply = self.client.call(
            "supermux.devices.terminal_sizing.governor", {"surface_id": self.facts["source_surface_id"]}
        ) or {}
        return (reply.get("governor") or {}).get("applied")

    def clear_viewports(self) -> None:
        for client in list(self.reported_clients):
            self.report_viewport(client, "phone", clear=True)

    def frame(self, workspace_id: str, surface_id: str) -> Dict[str, Any]:
        """The terminal's physical rows (`mobile.terminal.replay`'s render grid,
        10000 history rows: as deep as a mirror's replay)."""
        reply = self.client.call("mobile.terminal.replay", {
            "workspace_id": workspace_id, "surface_id": surface_id,
            "anchor": "screen", "max_scrollback_rows": 10000,
        }, timeout_s=120) or {}
        frame = reply.get("render_grid")
        if not isinstance(frame, dict):
            raise Failure(f"no render grid for {surface_id}: {sorted(reply)}")
        return grid_rows(frame)

    def compare(self, label: str) -> Dict[str, Any]:
        """Source and mirror at quiescence: the same rows, grid and cursor."""
        f = self.facts
        result: Dict[str, Any] = {}
        held: Dict[str, Any] = {}

        def settled() -> bool:
            source = self.frame(f["source_workspace_id"], f["source_surface_id"])
            mirror = self.frame(f["mirror_workspace_id"], f["mirror_surface_id"])
            held.update({"source": source, "mirror": mirror})
            result.update({
                "source_rows": len(source["rows"]), "mirror_rows": len(mirror["rows"]),
                "grid": source["grid"], "mirror_grid": mirror["grid"],
                "cursor": source["cursor"], "mirror_cursor": mirror["cursor"],
            })
            difference = first_difference(source["rows"], mirror["rows"])
            result["difference"] = difference
            return difference is None and source["grid"] == mirror["grid"] and source["cursor"] == mirror["cursor"] \
                and source["screen"] == mirror["screen"]

        try:
            wait_for(f"the mirror to equal the source ({label})", settled, 20, interval_s=2.0)
        except Failure:
            artifact = ARTIFACTS_DIR / f"resize-integrity-{label}-{self.nonce}"
            artifact.mkdir(parents=True, exist_ok=True)
            for side in ("source", "mirror"):
                rows = (held.get(side) or {}).get("rows") or []
                (artifact / f"{side}-rows.txt").write_text("\n".join(rows) + "\n", encoding="utf-8")
            result["artifact"] = str(artifact)
            raise Failure(f"the mirror differs from the source: {json.dumps(result)[:3000]}")
        return result

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
            for machine in (self.client.call("surface.catalog", {}) or {}).get("machines") or []:
                if str(machine.get("id", "")).startswith(LOOPBACK_MACHINE_PREFIX) and machine.get("link_state") == "connected":
                    return machine
            return None

        machine = wait_for("the loopback device to connect", connected, self.timeout_s)
        self.facts["machine"] = machine["id"]
        listed = self.client.call("supermux.devices.list", {}) or {}
        self.facts["auto_mirror_was"] = listed.get("auto_mirror")
        if listed.get("auto_mirror"):
            self.client.call("supermux.devices.set_auto_mirror", {"enabled": False})

        title = f"resize-integrity-{self.nonce}"
        created = self.client.call("workspace.create", {"title": title, "focus": False}) or {}
        workspace_id = created.get("workspace_id")
        if not workspace_id:
            raise Failure(f"workspace.create returned no workspace_id: {created}")
        self.workspaces.append(str(workspace_id))
        surfaces = (self.client.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        terminal = next((s["id"] for s in surfaces if s.get("type") == "terminal"), None)
        if not terminal:
            raise Failure(f"{title} has no terminal: {surfaces}")
        opened = self.client.call(
            "vm.workspace_open", {"id": self.machine(), "workspace_id": workspace_id, "focus": True}, timeout_s=120
        ) or {}
        mirror_id, mirror_surfaces = opened.get("workspace_id"), opened.get("surface_ids") or []
        if not mirror_id or not mirror_surfaces:
            raise Failure(f"vm.workspace_open did not open a mirror: {opened}")
        self.workspaces.insert(0, str(mirror_id))
        self.facts.update({
            "source_workspace_id": str(workspace_id), "source_surface_id": str(terminal),
            "mirror_workspace_id": str(mirror_id), "mirror_surface_id": str(mirror_surfaces[0]),
        })
        self.wait_attached()
        self.script_path.write_text(GENERATOR, encoding="utf-8")
        # A quiet prompt: nothing but the program's own output changes the screen.
        self.send_text(str(workspace_id), str(terminal), "PS1='$ '; PROMPT_COMMAND=; clear; echo READY_$((2*21))_" + self.nonce + "\n")
        self.wait_text("the ready marker in the mirror", str(mirror_id), str(mirror_surfaces[0]), f"READY_42_{self.nonce}", self.timeout_s)
        return {"grid": self.grid()}

    def storm(self) -> Dict[str, Any]:
        f = self.facts
        sizes = [("phone", "phone", 40, 12), ("phone", "phone", 60, 20), ("mac2", "mac", 100, 30)]
        done = f"GEN_DONE_{self.nonce}_42"
        self.send_text(f["source_workspace_id"], f["source_surface_id"],
                       f"python3 {self.script_path} {GENERATOR_LINES} {self.nonce}\n")
        grids: List[Any] = []
        dropped = False
        started = time.monotonic()
        changes = 0
        while changes < 16 and time.monotonic() - started < 60:
            choice = self.random.randrange(len(sizes) + 1)
            if choice == len(sizes):
                self.clear_viewports()
            else:
                client, kind, cols, rows = sizes[choice]
                self.report_viewport(client, kind, cols, rows)
            changes += 1
            time.sleep(self.random.uniform(0.25, 0.9))
            grids.append(self.grid())
            if changes == 8 and not dropped:
                self.link("stop")
                time.sleep(0.8)
                self.link("restore")
                dropped = True
        self.clear_viewports()
        self.wait_text("the generator's end in the SOURCE", f["source_workspace_id"], f["source_surface_id"], done, 180)
        self.wait_attached()
        self.wait_text("the generator's end in the MIRROR", f["mirror_workspace_id"], f["mirror_surface_id"], done, 120)
        time.sleep(1.5)
        result = self.compare("storm")
        distinct = len({tuple(g) for g in grids if g})
        result.update({"grid_changes_requested": changes, "distinct_grids_seen": distinct, "link_dropped": dropped})
        if distinct < 2:
            raise Failure(f"the grid never changed, so the step proves nothing: {result}")
        return result

    def quiet_resizes(self) -> Dict[str, Any]:
        f = self.facts
        self.send_text(f["source_workspace_id"], f["source_surface_id"], f"clear; seq -f 'QUIET_%g_{self.nonce}' 1 40\n")
        self.wait_text("the quiet lines in the MIRROR", f["mirror_workspace_id"], f["mirror_surface_id"], f"QUIET_40_{self.nonce}", self.timeout_s)
        seen = []
        for client, kind, cols, rows in [("phone", "phone", 40, 12), ("mac2", "mac", 100, 30), ("phone", "phone", 60, 20)]:
            self.report_viewport(client, kind, cols, rows)
            time.sleep(1.0)
            seen.append(self.grid())
        self.clear_viewports()
        time.sleep(1.5)
        result = self.compare("quiet")
        result["grids"] = seen
        return result

    def pane_stats(self) -> Dict[str, Any]:
        stats = self.client.call("supermux.devices.terminal_stream.stats", {"machine": self.machine()}) or {}
        for pane in stats.get("panes") or []:
            if norm(pane.get("panel_id")) == norm(self.facts["mirror_surface_id"]):
                return pane
        raise Failure(f"no stream stats for the mirror pane: {stats}")

    def drag(self) -> Dict[str, Any]:
        """A window dragged on the other Mac: many grid steps in quick
        succession while output flows cost a few replays, not one per step."""
        f = self.facts
        counters = ("full_replays", "grid_resyncs", "replay_confirmations", "replay_requests", "resumes", "gaps")
        before = {key: int(self.pane_stats().get(key, 0)) for key in counters}
        done = f"GEN_DONE_{self.nonce}_42"
        with GridSampler(self.client.path, f["source_surface_id"]) as sampler:
            self.send_text(f["source_workspace_id"], f["source_surface_id"], f"clear; python3 {self.script_path} 600 {self.nonce}\n")
            steps = 0
            drag_started = time.monotonic()
            for cols in list(range(50, 80, 3)) + list(range(80, 50, -3)):
                self.report_viewport("mac2", "mac", cols, 24)
                steps += 1
                time.sleep(0.04)
            applied = self.governor_applied()
            drag_seconds = time.monotonic() - drag_started
            self.clear_viewports()
            self.wait_text("the generator's end in the SOURCE", f["source_workspace_id"], f["source_surface_id"], done, 120)
            self.wait_text("the generator's end in the MIRROR", f["mirror_workspace_id"], f["mirror_surface_id"], done, 120)
            time.sleep(1.5)
            result = self.compare("drag")
            stats = self.pane_stats()
        stream = {key: int(stats.get(key, 0)) - before[key] for key in counters}
        replays = stream["full_replays"]
        sampled = sampler.facts()
        changes = sampled["applied_grid_changes"]
        # The cold cap, one cap per 400 ms window while the drag lasts, and the leave.
        governor_bound = 2 + math.ceil(drag_seconds / 0.4)
        result.update({"grid_steps": steps, "full_replays": replays, "governor_applied": applied,
                       "drag_seconds": round(drag_seconds, 2), "governor_bound": governor_bound,
                       "replay_bound": 2 * changes + 2, "stream": stream, **sampled})
        if sampled["sampler_error"] or sampled["grid_samples"] < 10:
            raise Failure(f"the grid sampler did not run, so the step proves nothing: {result}")
        problem = drag_verdict(applied, changes, replays, governor_bound, steps)
        if problem:
            raise Failure(f"{problem}: {result}")
        return result

    def cleanup(self) -> None:
        f = self.facts
        try:
            self.clear_viewports()
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
        try:
            self.script_path.unlink()
        except OSError:
            pass

    def run(self) -> bool:
        try:
            self.step("setup", self.setup, required=True)
            self.step("resize_storm_mirror_matches", self.storm)
            self.step("quiet_resizes_mirror_matches", self.quiet_resizes)
            self.step("dragged_window_replays_few_times", self.drag)
        except Failure:
            pass
        except (OSError, ValueError) as error:
            self.steps.append({"name": "transport", "ok": False, "error": str(error)})
        finally:
            self.cleanup()
        return all(step.get("ok") for step in self.steps)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tag's socket (default /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH)")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--seed", type=int, default=int(os.environ.get("CMUX_E2E_SEED", "7")))
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    tag_slug = slug(args.tag or "socket")
    socket_path = args.socket or f"/tmp/cmux-debug-{tag_slug}.sock"

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with SocketClient(socket_path) as client:
            suite = ResizeIntegrityE2E(client, timeout_s=args.timeout, seed=args.seed)
            passed = suite.run()
            steps, facts = suite.steps, suite.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-terminal-resize-integrity",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_terminal_resize_integrity_e2e-{tag_slug}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
