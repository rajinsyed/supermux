#!/usr/bin/env python3
"""End-to-end test: terminals that got their content while off screen draw when shown.

A terminal whose pane-local background (OSC 11) arrived while its pane was not
in the app's real window (a hidden bootstrap window or a detached workspace)
stayed blank when it was shown later: the buffer held the text, but the window
drew only the pane fill. Device mirrors hit it every time they open in the
background (auto-mirror) or are restored at launch, because the source Mac's
replay carries its colors. This suite checks what the user sees: it selects the
terminal and pixel-samples its pane in a window screenshot
(`debug.window.screenshot`), against one tagged DEBUG build running the
loopback device ("Loopback Mac" = this same app's own mobile host):

  1. setup                          auto-mirror on, the loopback linked and fetched
  2. source_draws                   control: a plain background workspace, selected, draws its text
  3. background_mirror_draws        its auto-mirror (opened in the background) draws when selected
  4. background_osc_terminal_draws  a background local terminal that set OSC 11 draws when selected
  5. restored_mirror_draws          (with --app-path) quit + relaunch: the restored mirror draws
                                    when selected

A pane counts as drawn when its sampled area holds at least --min-ink pixels
that differ clearly from the pane fill (text; a lone cursor stays below it).
Screenshots are copied next to the JSON report (default
tests/supermux/artifacts/loopback_mirror_render_e2e-<tag>.json). Exits non-zero
on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_render_e2e.py \
      [--app-path "<App path printed by reload.sh>" --projects-file /tmp/<tag>/projects.json] \
      [--timeout 30] [--min-ink 200] [--report PATH]
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


class Failure(Exception):
    """A check failed; the message says which and why."""


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


def ink_stats(path: str, left: int, top: int, width: int, height: int) -> Dict[str, Any]:
    """Pixels in the rectangle that differ clearly from its most common color."""
    png_width, png_height, bpp, rows = decode_png(path)
    colors: Counter = Counter()
    for y in range(max(0, top), min(png_height, top + height)):
        row = rows[y]
        for x in range(max(0, left), min(png_width, left + width)):
            colors[row[x * bpp:x * bpp + 3]] += 1
    if not colors:
        return {"ink": 0, "distinct": 0, "fill": None}
    fill = colors.most_common(1)[0][0]
    luma = lambda c: 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]  # noqa: E731
    ink = sum(n for c, n in colors.items() if abs(luma(c) - luma(fill)) > 48)
    return {"ink": ink, "distinct": len(colors), "fill": "#" + fill.hex()}


# -- test ---------------------------------------------------------------------

class MirrorRenderE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "min_ink": args.min_ink}
        self.machine = ""
        self.created: List[str] = []
        self.report_stem = Path(args.report_path).with_suffix("")

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

    # -- actions --------------------------------------------------------------

    def create_workspace(self, label: str) -> str:
        title = f"render-{label}-{self.nonce}"
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
        marker = f"RENDER_{label}_42_{self.nonce}"
        text = f"{command}echo RENDER_{label}_$((6*7))_{self.nonce}\n"
        self.sock.call("surface.send_text", {"workspace_id": workspace_id, "surface_id": surface, "text": text})
        wait_for(f"'{marker}' on {workspace_id}'s screen", lambda: marker in self.screen_text(workspace_id, surface), self.timeout)
        return surface, marker

    def assert_draws(self, workspace_id: str, surface_id: str, label: str) -> Dict[str, Any]:
        """Selects the workspace and waits until its terminal pane shows text in a window screenshot."""
        self.sock.call("workspace.select", {"workspace_id": workspace_id})
        last: Dict[str, Any] = {}

        def drawn() -> Optional[Dict[str, Any]]:
            nonlocal last
            rect = self.pane_rect(surface_id)
            if rect is None:
                raise Failure("the terminal is not in a window yet")
            shot = self.sock.call("debug.window.screenshot", {"label": f"mirror-render-{label}"}) or {}
            path = str(shot.get("path") or "")
            if not path:
                raise Failure(f"debug.window.screenshot returned no path: {shot}")
            scale = decode_png(path)[0] / rect["window_width"]
            inset = 10  # clear of the pane's focus / notification ring
            stats = ink_stats(
                path,
                int((rect["x"] + inset) * scale), int((rect["top"] + inset) * scale),
                int((rect["width"] - 2 * inset) * scale), int((rect["height"] - 2 * inset) * scale),
            )
            last = {"screenshot": path, **stats}
            return last if stats["ink"] >= self.args.min_ink else None

        try:
            result = wait_for(f"{label} to draw its text", drawn, self.args.draw_timeout, interval_s=0.75)
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

    # -- steps ----------------------------------------------------------------

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
        print(f"{'PASS' if record['ok'] else 'FAIL'} {name} ({record['seconds']}s){'' if record['ok'] else ': ' + record['error']}", file=sys.stderr)
        return record["ok"]

    def setup(self) -> Dict[str, Any]:
        self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True})

        def ready() -> Optional[Dict[str, Any]]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        self.machine = wait_for("the loopback device to connect", ready, self.timeout)["machine"]
        return {"machine": self.machine}

    def source_draws(self) -> Dict[str, Any]:
        source = self.create_workspace("source")
        surface, marker = self.run_in(source, "", "SOURCE")
        self.facts.update({"source": source, "source_marker": marker})
        return {"source": source, **self.assert_draws(source, surface, "source")}

    def background_mirror_draws(self) -> Dict[str, Any]:
        source, marker = self.facts["source"], self.facts["source_marker"]
        mirror = wait_for("the source's auto-mirror", lambda: self.mirror_of(source), self.timeout)
        surface = wait_for("the mirror's terminal", lambda: self.terminal(mirror), self.timeout)
        wait_for("the marker on the mirror's screen", lambda: marker in self.screen_text(mirror, surface), self.timeout)
        return {"mirror": mirror, **self.assert_draws(mirror, surface, "background-mirror")}

    def background_osc_terminal_draws(self) -> Dict[str, Any]:
        workspace = self.create_workspace("osc")
        surface, _ = self.run_in(workspace, "printf '\\033]11;#202830\\007'; ", "OSC")
        return {"workspace": workspace, **self.assert_draws(workspace, surface, "background-osc-terminal")}

    def restored_mirror_draws(self) -> Dict[str, Any]:
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
        return {"mirror": mirror, **self.assert_draws(mirror, surface, "restored-mirror")}

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
        ok = self.step("setup", self.setup) and self.step("source_draws", self.source_draws)
        if ok:
            ok = self.step("background_mirror_draws", self.background_mirror_draws) and ok
            ok = self.step("background_osc_terminal_draws", self.background_osc_terminal_draws) and ok
            if self.args.app_path:
                ok = self.step("restored_mirror_draws", self.restored_mirror_draws) and ok
            else:
                self.steps.append({"name": "restored_mirror_draws", "ok": None, "skipped": "pass --app-path to run"})
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per wait")
    parser.add_argument("--draw-timeout", type=float, default=8.0, help="seconds a selected terminal may take to draw")
    parser.add_argument("--min-ink", type=int, default=200, help="text pixels a drawn pane must show")
    parser.add_argument("--app-path", help="the tagged .app to quit and relaunch for the restore check")
    parser.add_argument("--projects-file", help="SUPERMUX_PROJECTS_FILE for the relaunch (a scratch projects file)")
    parser.add_argument("--keep", action="store_true", help="leave the test workspaces open")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    args.report_path = args.report or str(ARTIFACTS_DIR / f"loopback_mirror_render_e2e-{args.tag or 'socket'}.json")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = MirrorRenderE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-mirror-render-e2e",
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
