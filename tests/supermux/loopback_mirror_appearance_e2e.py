#!/usr/bin/env python3
"""End-to-end test: a device mirror looks like a local pane with this Mac's appearance.

Remote (device-mirror) tabs ignored a translucent terminal background: every
replay from the other Mac carried that Mac's default colors as OSC 10/11/12 and
an OSC 4 palette, so each mirror pane got a pane-local background override and
painted its own fill (opaque-looking, the host's colors) instead of sharing the
window's translucent backdrop the way a local pane does. A mirror must use this
Mac's terminal appearance; only colors a program on the other Mac set itself are
mirrored. Against one tagged DEBUG build running the loopback device ("Loopback
Mac" = this same app's own mobile host):

  1. setup                               auto-mirror on, the loopback linked and fetched; a source
                                         workspace prints a marker
  2. precondition_translucent            this Mac's Ghostty background is translucent (skipped,
                                         not failed, when it is opaque: the driver checks still run)
  3. local_control                       the source's local pane: no override, the shared backdrop
                                         paints it; its pane fill is sampled as the baseline
  4. mirror_matches_local                the source's auto-mirror: same driver fields as the local
                                         pane, no colors applied from the replay, and the same fill
  5. mirror_after_resync                 the same after a fresh replay (link stop + restore)
  6. authored_color_propagates           a program's OSC 11 on the source shows on the mirror, live
                                         and after a fresh replay (the authored-colors sidecar)
  7. authored_reset_restores_translucency  the program's OSC 111 brings the mirror back to the
                                         shared backdrop, live and after a fresh replay
  8. live_reset_during_gap_settles       a program's OSC 11 reaches the mirror only live (no replay
                                         carries it); its OSC 111 lands while the link is down, and the
                                         reconnect replay alone must bring the mirror back to this Mac's
                                         theme (each replay settles every color, not a delta)
  9. restored_mirror_matches_local       (with --app-path) quit + relaunch: the restored background
                                         mirror matches the local pane when selected

The hard proof of the fix is the mirror driver's `applied_remote_colors == {}`
and `last_replay_color_osc == false` (`supermux.devices.mirror.terminal_background`):
in loopback both ends share one Ghostty config, so a host color equal to this
Mac's default could look right by accident. Pixel fills come from window
screenshots (`debug.window.screenshot`), the modal RGBA of the pane's inset area.

Writes a JSON report (default tests/supermux/artifacts/loopback_mirror_appearance_e2e-<tag>.json)
with every driver payload and fill sample, and keeps the sampled screenshots next to it.
Exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_appearance_e2e.py \
      [--app-path "<App path printed by reload.sh>" --projects-file /tmp/<tag>/projects.json] \
      [--timeout 30] [--settle-timeout 10] [--fill-tolerance 6] [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import time
import uuid
import zlib
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

LOOPBACK_DEVICE_ID = "5e1f10b0-0000-4000-8000-000000000001"
REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = REPO_ROOT / "tests" / "supermux" / "artifacts"
AUTHORED_BACKGROUND = "#202830"


class Failure(Exception):
    """A check failed; the message says which and why."""


class Skip(Exception):
    """A step cannot say anything on this machine; the message says why."""


class Socket:
    """Newline-delimited JSON client for the cmux v2 control socket."""

    def __init__(self, path: str, timeout_s: float = 30.0) -> None:
        self.path = path
        self.timeout_s = timeout_s
        self._sock: Optional[socket.socket] = None
        self._buffer = b""
        self._next_id = 1

    def connect(self) -> "Socket":
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout_s)
        sock.connect(self.path)
        self._sock = sock
        self._buffer = b""
        return self

    def close(self) -> None:
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
            raise Failure(f"{method}: mismatched response id")
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
            chunk = self._sock.recv(65536)
            if not chunk:
                raise Failure("socket closed by the app")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        return line.decode("utf-8", errors="replace")


def socket_path_for_tag(tag: str) -> str:
    slug = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", tag.strip().lower())).strip("-")
    return f"/tmp/cmux-debug-{slug}.sock"


def up(identifier: Any) -> str:
    return str(identifier or "").strip().upper()


def wait_for(description: str, probe: Callable[[], Any], timeout_s: float, interval_s: float = 0.4) -> Any:
    deadline = time.monotonic() + timeout_s
    last: Optional[str] = None
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value:
                return value
        except Failure as error:
            last = str(error)
        time.sleep(interval_s)
    raise Failure(f"timed out after {timeout_s:.0f}s waiting for {description}" + (f" (last: {last})" if last else ""))


# -- pixels -------------------------------------------------------------------

def decode_png(path: str) -> Tuple[int, int, int, List[bytes]]:
    """(width, height, bytes per pixel, rows) of an 8-bit RGB/RGBA PNG."""
    data = Path(path).read_bytes()
    pos, idat, width, height, color_type = 8, b"", 0, 0, 0
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, _, color_type = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    raw, bpp = zlib.decompress(idat), (4 if color_type == 6 else 3)
    stride, rows, previous, offset = width * bpp, [], bytearray(width * bpp), 0
    for _ in range(height):
        kind, line = raw[offset], bytearray(raw[offset + 1:offset + 1 + stride])
        offset += 1 + stride
        for x in range(stride):
            left = line[x - bpp] if x >= bpp else 0
            above, corner = previous[x], (previous[x - bpp] if x >= bpp else 0)
            if kind == 1:
                line[x] = (line[x] + left) & 255
            elif kind == 2:
                line[x] = (line[x] + above) & 255
            elif kind == 3:
                line[x] = (line[x] + (left + above) // 2) & 255
            elif kind == 4:
                guess = left + above - corner
                pa, pb, pc = abs(guess - left), abs(guess - above), abs(guess - corner)
                line[x] = (line[x] + (left if pa <= pb and pa <= pc else above if pb <= pc else corner)) & 255
        rows.append(bytes(line))
        previous = line
    return width, height, bpp, rows


def fill_stats(path: str, left: int, top: int, width: int, height: int) -> Dict[str, Any]:
    """The rectangle's most common RGBA (the pane fill) and how many pixels differ clearly (text)."""
    png_width, png_height, bpp, rows = decode_png(path)
    colors: Counter = Counter()
    for y in range(max(0, top), min(png_height, top + height)):
        row = rows[y]
        for x in range(max(0, left), min(png_width, left + width)):
            pixel = row[x * bpp:x * bpp + bpp]
            colors[pixel if bpp == 4 else pixel + b"\xff"] += 1
    if not colors:
        return {"ink": 0, "fill_rgba": None}
    fill = colors.most_common(1)[0][0]
    luma = lambda c: 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]  # noqa: E731
    ink = sum(n for c, n in colors.items() if abs(luma(c) - luma(fill)) > 48)
    return {"ink": ink, "fill_rgba": list(fill), "fill_share": round(colors[fill] / sum(colors.values()), 3)}


# -- test ---------------------------------------------------------------------

class MirrorAppearanceE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "fill_tolerance": args.fill_tolerance}
        self.machine = ""
        self.created: List[str] = []
        self.report_stem = Path(args.report_path).with_suffix("")
        self.local: Dict[str, Any] = {}
        self.baseline_fill: Optional[List[int]] = None

    # -- reads ----------------------------------------------------------------

    def device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device in supermux.devices.list (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def mirror_of(self, source_id: str) -> str:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        mirrors = [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(source_id)]
        return str(mirrors[0]["workspace_id"]) if len(mirrors) == 1 else ""

    def terminal(self, workspace_id: str) -> str:
        surfaces = (self.sock.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        terminals = [s["id"] for s in surfaces if s.get("type") == "terminal"]
        return str(terminals[0]) if terminals else ""

    def screen_text(self, workspace_id: str, surface_id: str) -> str:
        result = self.sock.call("surface.read_text", {"workspace_id": workspace_id, "surface_id": surface_id}) or {}
        return str(result.get("text") or "")

    def background(self, surface_id: str) -> Dict[str, Any]:
        """The DEBUG driver: how this terminal paints its background."""
        return self.sock.call("supermux.devices.mirror.terminal_background", {"surface_id": surface_id}) or {}

    def pane_rect(self, surface_id: str) -> Optional[Dict[str, float]]:
        """The terminal's frame in top-left window points, with the window size."""
        for row in (self.sock.call("debug.terminals", {}) or {}).get("terminals") or []:
            if up(row.get("surface_id")) != up(surface_id) or not row.get("hosted_view_in_window"):
                continue
            frame, window = row.get("hosted_view_frame_in_window") or {}, row.get("window_frame") or {}
            if frame.get("width", 0) <= 1 or frame.get("height", 0) <= 1 or not window.get("height"):
                return None
            top = window["height"] - frame["y"] - frame["height"]
            return {"x": frame["x"], "top": top, "width": frame["width"], "height": frame["height"], "window_width": window["width"]}
        return None

    @property
    def translucent(self) -> bool:
        return float(self.local.get("app_background_opacity") or 1.0) < 0.999

    # -- actions --------------------------------------------------------------

    def create_workspace(self, label: str) -> str:
        title = f"appearance-{label}-{self.nonce}"
        result = self.sock.call("workspace.create", {"title": title, "focus": False}) or {}
        workspace_id = result.get("workspace_id") or result.get("created_workspace_id")
        if not workspace_id:
            raise Failure(f"workspace.create returned no id: {result}")
        self.sock.call("workspace.rename", {"workspace_id": workspace_id, "title": title})
        self.created.append(str(workspace_id))
        return str(workspace_id)

    def run_in(self, workspace_id: str, command: str, label: str) -> Tuple[str, str]:
        """Runs `command` in the workspace's terminal, then echoes a marker only the shell's
        output (not the typed line) contains; returns (surface, marker) once it is on screen."""
        surface = wait_for(f"a terminal in {workspace_id}", lambda: self.terminal(workspace_id), self.timeout)
        marker = f"LOOK_{label}_42_{self.nonce}"
        text = f"{command}echo LOOK_{label}_$((6*7))_{self.nonce}\n"
        self.sock.call("surface.send_text", {"workspace_id": workspace_id, "surface_id": surface, "text": text})
        wait_for(f"'{marker}' on {workspace_id}'s screen", lambda: marker in self.screen_text(workspace_id, surface), self.timeout)
        return surface, marker

    def sample_fill(self, workspace_id: str, surface_id: str, label: str,
                    accept: Callable[[Dict[str, Any]], Optional[str]]) -> Dict[str, Any]:
        """Selects the workspace and samples its pane until `accept` returns no complaint
        (or the draw timeout passes). Keeps the last screenshot next to the report."""
        self.sock.call("workspace.select", {"workspace_id": workspace_id})
        last: Dict[str, Any] = {}

        def sampled() -> Optional[Dict[str, Any]]:
            nonlocal last
            rect = self.pane_rect(surface_id)
            if rect is None:
                raise Failure("the terminal is not in a window yet")
            shot = self.sock.call("debug.window.screenshot", {"label": f"mirror-appearance-{label}"}) or {}
            path = str(shot.get("path") or "")
            if not path:
                raise Failure(f"debug.window.screenshot returned no path: {shot}")
            scale = decode_png(path)[0] / rect["window_width"]
            inset = 10  # clear of the pane's focus / notification ring
            stats = fill_stats(
                path,
                int((rect["x"] + inset) * scale), int((rect["top"] + inset) * scale),
                int((rect["width"] - 2 * inset) * scale), int((rect["height"] - 2 * inset) * scale),
            )
            last = {"screenshot": path, **stats}
            if stats["ink"] < self.args.min_ink:
                raise Failure(f"the pane shows no text yet (ink {stats['ink']})")
            complaint = accept(stats)
            if complaint:
                raise Failure(complaint)
            return last

        try:
            result = wait_for(f"{label}'s pane fill", sampled, self.args.draw_timeout, interval_s=0.75)
        except Failure as error:
            raise Failure(f"{error}; last sample {self.keep_screenshot(last, label)}") from None
        return self.keep_screenshot(result, label)

    def keep_screenshot(self, sample: Dict[str, Any], label: str) -> Dict[str, Any]:
        if not sample.get("screenshot"):
            return sample
        kept = self.report_stem.parent / f"{self.report_stem.name}-{label}.png"
        kept.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(sample["screenshot"], kept)
        return {**sample, "screenshot": str(kept)}

    def matches_baseline(self, stats: Dict[str, Any]) -> Optional[str]:
        fill, base = stats.get("fill_rgba"), self.baseline_fill
        if fill is None or base is None:
            return "no fill sampled"
        worst = max(abs(a - b) for a, b in zip(fill, base))
        if worst > self.args.fill_tolerance:
            return f"pane fill rgba {fill} differs from the local pane's {base} by {worst}"
        return None

    def settle(self, description: str, surface_id: str, check: Callable[[Dict[str, Any]], List[str]]) -> Dict[str, Any]:
        """Polls the driver until `check` finds nothing wrong; fails with the last problems."""
        def probe() -> Optional[Dict[str, Any]]:
            payload = self.background(surface_id)
            problems = check(payload)
            if problems:
                raise Failure("; ".join(problems) + f" — driver: {json.dumps(payload, sort_keys=True)}")
            return payload
        return wait_for(description, probe, self.args.settle_timeout)

    def like_local(self, mirror: Dict[str, Any]) -> List[str]:
        """Everything that makes a mirror pane paint differently from the local pane."""
        local, problems = self.local, []
        if mirror.get("is_mirror") is not True:
            problems.append("the surface is not a device mirror")
        if mirror.get("background_override") is not None:
            problems.append(f"background_override={mirror.get('background_override')} (a local pane has none)")
        if mirror.get("fill_owner") != local.get("fill_owner"):
            problems.append(f"fill_owner={mirror.get('fill_owner')} (local: {local.get('fill_owner')})")
        if abs(float(mirror.get("host_layer_alpha") or 0) - float(local.get("host_layer_alpha") or 0)) > 0.01:
            problems.append(f"host_layer_alpha={mirror.get('host_layer_alpha')} (local: {local.get('host_layer_alpha')})")
        if bool(mirror.get("backdrop_cutout_present")) != bool(local.get("backdrop_cutout_present")):
            problems.append(f"backdrop_cutout_present={mirror.get('backdrop_cutout_present')}")
        if mirror.get("applied_remote_colors") != {}:
            problems.append(f"applied_remote_colors={mirror.get('applied_remote_colors')} (want {{}}: no program set a color)")
        if mirror.get("last_replay_color_osc") is not False:
            problems.append(f"last_replay_color_osc={mirror.get('last_replay_color_osc')} (want false: the replay carries no color state)")
        return problems

    def resync(self, surface_id: str, during_gap: Optional[Callable[[], Any]] = None) -> Dict[str, Any]:
        """Forces a fresh replay into the mirror: holds the link down, then redials it.
        `during_gap` runs while the link is down and the mirror detached, so nothing it
        does on the source reaches the mirror live; only the reconnect replay can carry it."""
        before = self.background(surface_id).get("replays")
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        try:
            # Informational: the replay counter below is what proves a fresh replay.
            detached = bool(wait_for("the mirror to detach",
                                     lambda: self.background(surface_id).get("mirror_phase") != "attached", 5, interval_s=0.2))
        except Failure:
            detached = False
        try:
            if during_gap is not None:
                if not detached:
                    raise Failure("the mirror never detached, so the gap's bytes could still reach it live")
                during_gap()
        finally:
            self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        wait_for("the loopback link to reconnect", lambda: self.device().get("link_state") == "connected", self.timeout)

        def reattached() -> bool:
            payload = self.background(surface_id)
            fresh = before is None or (payload.get("replays") or 0) > before
            return payload.get("mirror_phase") == "attached" and fresh

        wait_for("the mirror to re-attach on a fresh replay", reattached, self.timeout)
        time.sleep(1.0)  # color changes reach the view on the next main-queue turn
        return {"replays_before": before, "replays_after": self.background(surface_id).get("replays"), "saw_detach": detached}

    # -- steps ----------------------------------------------------------------

    def step(self, name: str, action: Callable[[], Optional[Dict[str, Any]]]) -> bool:
        started = time.monotonic()
        record: Dict[str, Any] = {"name": name}
        try:
            record.update(action() or {})
            record["ok"] = True
        except Skip as reason:
            record["ok"] = None
            record["skipped"] = str(reason)
        except Failure as error:
            record["ok"] = False
            record["error"] = str(error)
        record["seconds"] = round(time.monotonic() - started, 2)
        self.steps.append(record)
        label = {True: "PASS", False: "FAIL", None: "SKIP"}[record["ok"]]
        detail = record.get("error") or record.get("skipped")
        print(f"{label} {name} ({record['seconds']}s){': ' + detail if detail else ''}", file=sys.stderr)
        return record["ok"] is not False

    def setup(self) -> Dict[str, Any]:
        self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True})

        def ready() -> Optional[Dict[str, Any]]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        self.machine = wait_for("the loopback device to connect", ready, self.timeout)["machine"]
        if "source" not in self.facts:
            source = self.create_workspace("source")
            surface, marker = self.run_in(source, "", "SOURCE")
            self.facts.update({"source": source, "source_surface": surface, "source_marker": marker})
        return {"machine": self.machine, "source": self.facts["source"]}

    def precondition_translucent(self) -> Dict[str, Any]:
        self.local = self.background(self.facts["source_surface"])
        opacity = self.local.get("app_background_opacity")
        if not self.translucent:
            raise Skip(f"this Mac's Ghostty background-opacity is {opacity}: the pixel checks cannot tell a "
                       "pane-local fill from the shared backdrop (the driver checks still run)")
        return {"app_background_opacity": opacity, "app_background_hex": self.local.get("app_background_hex")}

    def local_control(self) -> Dict[str, Any]:
        source, surface = self.facts["source"], self.facts["source_surface"]

        def control(payload: Dict[str, Any]) -> List[str]:
            problems = []
            if payload.get("is_mirror"):
                problems.append("the source terminal reports is_mirror")
            if payload.get("background_override") is not None:
                problems.append(f"the local pane has background_override={payload.get('background_override')}")
            if self.translucent and payload.get("fill_owner") != "shared":
                problems.append(f"the local pane's fill_owner is {payload.get('fill_owner')}, not the shared backdrop")
            if float(payload.get("host_layer_alpha") or 0) > 0.01 and self.translucent:
                problems.append(f"the local pane's host layer paints alpha {payload.get('host_layer_alpha')}")
            if payload.get("backdrop_cutout_present"):
                problems.append("the local pane cut itself out of the shared backdrop")
            return problems

        self.local = self.settle("the local pane's background", surface, control)
        sample = self.sample_fill(source, surface, "local", lambda stats: None if stats.get("fill_rgba") else "no fill")
        self.baseline_fill = sample["fill_rgba"]
        return {"driver": self.local, "fill": sample}

    def mirror_matches_local(self) -> Dict[str, Any]:
        source, marker = self.facts["source"], self.facts["source_marker"]
        mirror = wait_for("the source's auto-mirror", lambda: self.mirror_of(source), self.timeout)
        surface = wait_for("the mirror's terminal", lambda: self.terminal(mirror), self.timeout)
        self.facts.update({"mirror": mirror, "mirror_surface": surface})
        wait_for("the marker on the mirror's screen", lambda: marker in self.screen_text(mirror, surface), self.timeout)
        return self.assert_mirror_like_local(mirror, surface, "mirror")

    def assert_mirror_like_local(self, mirror: str, surface: str, label: str) -> Dict[str, Any]:
        driver = self.settle(f"{label} to paint like the local pane", surface, self.like_local)
        fill = self.sample_fill(mirror, surface, label, self.matches_baseline)
        return {"mirror": mirror, "driver": driver, "fill": fill}

    def mirror_after_resync(self) -> Dict[str, Any]:
        mirror, surface = self.facts["mirror"], self.facts["mirror_surface"]
        resync = self.resync(surface)
        wait_for("the marker after the replay", lambda: self.facts["source_marker"] in self.screen_text(mirror, surface), self.timeout)
        return {"resync": resync, **self.assert_mirror_like_local(mirror, surface, "mirror-after-resync")}

    def authored_color_propagates(self) -> Dict[str, Any]:
        source, mirror, surface = self.facts["source"], self.facts["mirror"], self.facts["mirror_surface"]
        self.run_in(source, f"printf '\\033]11;{AUTHORED_BACKGROUND}\\007'; ", "AUTHORED")

        def authored(payload: Dict[str, Any]) -> List[str]:
            override = str(payload.get("background_override") or "").lower()
            return [] if override == AUTHORED_BACKGROUND else [f"background_override={payload.get('background_override')} (want {AUTHORED_BACKGROUND})"]

        live = self.settle("the program's OSC 11 on the mirror", surface, authored)
        resync = self.resync(surface)

        def replayed(payload: Dict[str, Any]) -> List[str]:
            problems = authored(payload)
            applied = payload.get("applied_remote_colors")
            if not isinstance(applied, dict) or str(applied.get("bg") or "").lower() != AUTHORED_BACKGROUND:
                problems.append(f"applied_remote_colors={applied} (want bg {AUTHORED_BACKGROUND} from the replay's sidecar)")
            return problems

        after = self.settle("the authored background after a fresh replay", surface, replayed)
        return {"mirror": mirror, "live": live, "resync": resync, "after_resync": after}

    def authored_reset_restores_translucency(self) -> Dict[str, Any]:
        source, mirror, surface = self.facts["source"], self.facts["mirror"], self.facts["mirror_surface"]
        self.run_in(source, "printf '\\033]111\\007'; ", "RESET")

        def restored(payload: Dict[str, Any]) -> List[str]:
            problems = []
            if payload.get("background_override") is not None:
                problems.append(f"background_override={payload.get('background_override')} after OSC 111 (want null)")
            if payload.get("fill_owner") != self.local.get("fill_owner"):
                problems.append(f"fill_owner={payload.get('fill_owner')} (local: {self.local.get('fill_owner')})")
            return problems

        live = self.settle("the mirror to drop its override after OSC 111", surface, restored)
        resync = self.resync(surface)
        after = self.settle("the mirror to stay on this Mac's theme after a fresh replay", surface, self.like_local)
        fill = self.sample_fill(mirror, surface, "mirror-after-reset", self.matches_baseline)
        return {"mirror": mirror, "live": live, "resync": resync, "after_resync": after, "fill": fill}

    def live_reset_during_gap_settles(self) -> Dict[str, Any]:
        source, mirror, surface = self.facts["source"], self.facts["mirror"], self.facts["mirror_surface"]
        self.run_in(source, f"printf '\\033]11;{AUTHORED_BACKGROUND}\\007'; ", "GAPSET")

        def live_only(payload: Dict[str, Any]) -> List[str]:
            problems = []
            override = str(payload.get("background_override") or "").lower()
            if override != AUTHORED_BACKGROUND:
                problems.append(f"background_override={payload.get('background_override')} (want {AUTHORED_BACKGROUND}, live)")
            if payload.get("applied_remote_colors") != {}:
                problems.append(f"applied_remote_colors={payload.get('applied_remote_colors')} "
                                "(want {}: the color must have arrived live, not from a replay)")
            return problems

        live = self.settle("the program's OSC 11 on the mirror, live only", surface, live_only)
        resync = self.resync(surface, during_gap=lambda: self.run_in(source, "printf '\\033]111\\007'; ", "GAPRESET"))
        wait_for("the gap's marker after the replay",
                 lambda: f"LOOK_GAPRESET_42_{self.nonce}" in self.screen_text(mirror, surface), self.timeout)
        after = self.settle("the reconnect replay to reset the live-set background", surface, self.like_local)
        fill = self.sample_fill(mirror, surface, "mirror-after-gap-reset", self.matches_baseline)
        return {"mirror": mirror, "live": live, "resync": resync, "after_resync": after, "fill": fill}

    def restored_mirror_matches_local(self) -> Dict[str, Any]:
        app = self.args.app_path
        bundle_id = plistlib.loads((Path(app) / "Contents" / "Info.plist").read_bytes())["CFBundleIdentifier"]
        source, marker = self.facts["source"], self.facts["source_marker"]
        # Leave the source selected, so the mirror restores in the background.
        self.sock.call("workspace.select", {"workspace_id": source})
        time.sleep(1.0)
        self.sock.close()
        subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to quit'], check=False, capture_output=True)
        wait_for("the app to quit", lambda: not self.app_running(bundle_id), 60, interval_s=0.5)
        env_args = ["--env", "SUPERMUX_DEBUG_LOOPBACK_DEVICE=1"]
        if self.args.projects_file:
            env_args += ["--env", f"SUPERMUX_PROJECTS_FILE={self.args.projects_file}"]
        subprocess.run(["open", "-g", *env_args, app], check=True)
        wait_for("the relaunched app's socket", self.socket_alive, 60)
        self.sock.connect()
        self.setup()
        mirror = wait_for("the restored mirror", lambda: self.mirror_of(source), self.timeout)
        surface = wait_for("the restored mirror's terminal", lambda: self.terminal(mirror), self.timeout)
        wait_for("the marker on the restored mirror", lambda: marker in self.screen_text(mirror, surface), self.timeout)
        return self.assert_mirror_like_local(mirror, surface, "restored-mirror")

    def app_running(self, bundle_id: str) -> bool:
        script = f'application id "{bundle_id}" is running'
        result = subprocess.run(["osascript", "-e", script], check=False, capture_output=True, text=True)
        return result.stdout.strip() == "true"

    def socket_alive(self) -> bool:
        probe = Socket(self.sock.path, timeout_s=3)
        try:
            probe.connect()
            probe.call("supermux.devices.list", {})
            return True
        except (OSError, Failure):
            return False
        finally:
            probe.close()

    # -- run ------------------------------------------------------------------

    def cleanup(self) -> None:
        if self.args.keep:
            return
        for workspace_id in self.created:
            try:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except (Failure, OSError) as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        ok = (self.step("setup", self.setup)
              and self.step("precondition_translucent", self.precondition_translucent)
              and self.step("local_control", self.local_control))
        if ok:
            mirror_ok = self.step("mirror_matches_local", self.mirror_matches_local)
            ok = mirror_ok and ok
            if "mirror_surface" in self.facts:
                ok = self.step("mirror_after_resync", self.mirror_after_resync) and ok
                ok = self.step("authored_color_propagates", self.authored_color_propagates) and ok
                ok = self.step("authored_reset_restores_translucency", self.authored_reset_restores_translucency) and ok
                ok = self.step("live_reset_during_gap_settles", self.live_reset_during_gap_settles) and ok
            if self.args.app_path:
                ok = self.step("restored_mirror_matches_local", self.restored_mirror_matches_local) and ok
            else:
                self.steps.append({"name": "restored_mirror_matches_local", "ok": None, "skipped": "pass --app-path to run"})
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per wait")
    parser.add_argument("--settle-timeout", type=float, default=10.0, help="seconds a pane's background may take to settle")
    parser.add_argument("--draw-timeout", type=float, default=8.0, help="seconds a selected terminal may take to draw")
    parser.add_argument("--min-ink", type=int, default=200, help="text pixels a drawn pane must show")
    parser.add_argument("--fill-tolerance", type=int, default=6, help="max per-channel RGBA difference from the local fill")
    parser.add_argument("--app-path", help="the tagged .app to quit and relaunch for the restore check")
    parser.add_argument("--projects-file", help="SUPERMUX_PROJECTS_FILE for the relaunch (a scratch projects file)")
    parser.add_argument("--keep", action="store_true", help="leave the test workspaces open")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    args.report_path = args.report or str(ARTIFACTS_DIR / f"loopback_mirror_appearance_e2e-{args.tag or 'socket'}.json")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = MirrorAppearanceE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-mirror-appearance-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
