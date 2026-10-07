#!/usr/bin/env python3
"""End-to-end test: a lone modifier key leaves another Mac's terminal where you scrolled it.

Reading back through a device mirror's scrollback, pressing Cmd on its own (or Shift,
Option, Control) threw the view back to the bottom. The mirror forwards every key press
to the Mac that runs the terminal, and a forwarded key goes through Ghostty's text-input
path, which scrolls to the bottom for every keystroke it sees, modifier or not. A
terminal on this Mac never moves for a modifier: Ghostty's own key path skips them.

This suite runs against one tagged DEBUG build with the loopback device ("Loopback Mac" =
this app's own mobile host), so the source workspace is the "other Mac" and its auto
mirror is the viewer. Scrolls are real wheel events posted to the app
(`supermux.devices.terminal_sizing.local_scroll`); keys are real CGEvents posted to the
app's process, so they take the same `flagsChanged` / `keyDown` path a keyboard does.

  1. setup                          auto-mirror on, the loopback linked and fetched
  2. mirror_shows_long_output       a background source prints long output; its mirror shows the end
  3. mirror_scrolled_up             the mirror, focused and scrolled up, shows older lines
  4. <modifier>_keeps_scrollback    Cmd, Shift, Option and Control pressed and released alone
                                    leave the mirror's view where it was
  5. keystroke_returns_to_bottom    control: a Right-arrow press still brings the mirror back to
                                    the live bottom (keys reach it, and keystrokes still follow)

Writes a JSON report (default tests/supermux/artifacts/loopback_mirror_scrollback_e2e-<tag>.json)
with the mirror's top visible line before and after each key, and exits non-zero on any
failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_scrollback_e2e.py [--timeout 30] [--report PATH]
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import json
import os
import struct
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_auto_mirror_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    Failure,
    Socket,
    socket_path_for_tag,
    up,
    wait_for,
)

SIZING = "supermux.devices.terminal_sizing."
OUTPUT_LINES = 1500
SCROLL_LINES = 40
# How long a key gets to move the view before the view counts as kept.
SETTLE_S = 1.5

# Virtual key code and the press's modifier flags (device-independent mask plus the
# left-side device bit a real keyboard sets, and NX_NONCOALESCEDMASK).
MODIFIERS = {
    "command": (0x37, 0x100000 | 0x08 | 0x100),
    "shift": (0x38, 0x020000 | 0x02 | 0x100),
    "option": (0x3A, 0x080000 | 0x20 | 0x100),
    "control": (0x3B, 0x040000 | 0x01 | 0x100),
}
RIGHT_ARROW = 0x7C
NO_MODIFIERS = 0x100


class KeyPoster:
    """Posts keyboard CGEvents straight to one process, as the window server would."""

    def __init__(self, pid: int) -> None:
        self.pid = pid
        cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
        cf = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
        cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
        cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
        cg.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        cg.CGEventPostToPid.argtypes = [ctypes.c_int32, ctypes.c_void_p]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        self.cg, self.cf = cg, cf

    def post(self, keycode: int, down: bool, flags: int) -> None:
        event = self.cg.CGEventCreateKeyboardEvent(None, keycode, down)
        if not event:
            raise Failure(f"could not create a key event for key code {keycode}")
        self.cg.CGEventSetFlags(event, flags)
        self.cg.CGEventPostToPid(self.pid, event)
        self.cf.CFRelease(event)

    def tap_modifier(self, name: str) -> None:
        keycode, flags = MODIFIERS[name]
        self.post(keycode, True, flags)
        time.sleep(0.15)
        self.post(keycode, False, NO_MODIFIERS)

    def tap_key(self, keycode: int) -> None:
        self.post(keycode, True, NO_MODIFIERS)
        time.sleep(0.05)
        self.post(keycode, False, NO_MODIFIERS)


def socket_peer_pid(sock: Socket) -> int:
    """The app's pid: the process on the other end of its control socket (LOCAL_PEERPID)."""
    assert sock._sock is not None
    return struct.unpack("i", sock._sock.getsockopt(0, 0x002, 4))[0]


class MirrorScrollbackE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.done_marker = f"SCROLLBACK_DONE_{self.nonce}"
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.created: List[str] = []
        self.machine = ""
        self.mirror_id = ""
        self.mirror_surface = ""
        self.keys = KeyPoster(socket_peer_pid(sock))

    # -- reads ----------------------------------------------------------------

    def terminal(self, workspace_id: str) -> str:
        surfaces = (self.sock.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        terminals = [s["id"] for s in surfaces if s.get("type") == "terminal"]
        return str(terminals[0]) if terminals else ""

    def mirror_of(self, source_id: str) -> str:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        mirrors = [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(source_id)]
        return str(mirrors[0]["workspace_id"]) if len(mirrors) == 1 else ""

    def visible_lines(self) -> List[str]:
        """The mirror's visible rows (its viewport, not its scrollback), blank rows dropped."""
        result = self.sock.call("surface.read_text", {"workspace_id": self.mirror_id, "surface_id": self.mirror_surface}) or {}
        return [line.strip() for line in str(result.get("text") or "").splitlines() if line.strip()]

    def top_line(self) -> str:
        lines = self.visible_lines()
        return lines[0] if lines else ""

    def at_bottom(self) -> bool:
        return any(self.done_marker in line for line in self.visible_lines())

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
            for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
                if device.get("is_loopback") and device.get("link_state") == "connected" and device.get("has_fetched_records"):
                    return device
            return None

        self.machine = wait_for("the loopback device to connect", ready, self.timeout)["machine"]
        return {"machine": self.machine}

    def mirror_shows_long_output(self) -> Dict[str, Any]:
        title = f"scrollback-{self.nonce}"
        result = self.sock.call("workspace.create", {"title": title, "focus": False}) or {}
        source_id = str(result.get("workspace_id") or result.get("created_workspace_id") or "")
        if not source_id:
            raise Failure(f"workspace.create returned no id: {result}")
        self.created.append(source_id)
        self.sock.call("workspace.rename", {"workspace_id": source_id, "title": title})
        source_surface = wait_for("the source's terminal", lambda: self.terminal(source_id), self.timeout)
        # The typed line splits the marker in two quoted halves: only the output carries it whole.
        text = f'seq -f "scrollback %g" 1 {OUTPUT_LINES}; echo "SCROLLBACK_DONE_""{self.nonce}"\n'
        self.sock.call("surface.send_text", {"workspace_id": source_id, "surface_id": source_surface, "text": text})
        self.mirror_id = wait_for("the source's auto-mirror", lambda: self.mirror_of(source_id), self.timeout)
        self.mirror_surface = wait_for("the mirror's terminal", lambda: self.terminal(self.mirror_id), self.timeout)
        wait_for("the end of the output on the mirror", self.at_bottom, self.timeout)
        self.facts.update(source=source_id, mirror=self.mirror_id, mirror_surface=self.mirror_surface)
        return {"mirror": self.mirror_id}

    def mirror_scrolled_up(self) -> Dict[str, Any]:
        self.sock.call("workspace.select", {"workspace_id": self.mirror_id})
        self.sock.call("surface.focus", {"workspace_id": self.mirror_id, "surface_id": self.mirror_surface})
        self.sock.call("debug.app.activate", {})

        def focused() -> bool:
            result = self.sock.call("debug.terminal.is_focused", {"surface_id": self.mirror_surface}) or {}
            if not result.get("focused"):
                self.sock.call("surface.focus", {"workspace_id": self.mirror_id, "surface_id": self.mirror_surface})
            return bool(result.get("focused"))

        wait_for("the mirror terminal to take keyboard focus", focused, self.timeout)
        self.scroll_up()
        return {"top_line": self.top_line()}

    def scroll_up(self) -> None:
        def scrolled() -> bool:
            if self.at_bottom():
                self.sock.call(SIZING + "local_scroll", {"surface_id": self.mirror_surface, "lines": SCROLL_LINES})
                return False
            return True

        wait_for("the mirror to show older lines", scrolled, self.timeout, interval_s=0.6)

    def modifier_keeps_scrollback(self, name: str) -> Dict[str, Any]:
        if self.at_bottom():
            self.scroll_up()
        before = self.top_line()
        self.keys.tap_modifier(name)
        deadline = time.monotonic() + SETTLE_S
        while time.monotonic() < deadline:
            after = self.top_line()
            if after != before:
                raise Failure(f"{name} alone moved the mirror's view: top line {before!r} -> {after!r}"
                              f"{' (the live bottom)' if self.at_bottom() else ''}")
            time.sleep(0.1)
        return {"top_line_before": before, "top_line_after": self.top_line()}

    def keystroke_returns_to_bottom(self) -> Dict[str, Any]:
        if self.at_bottom():
            self.scroll_up()
        before = self.top_line()
        self.keys.tap_key(RIGHT_ARROW)
        wait_for("a Right-arrow press to bring the mirror to the live bottom", self.at_bottom, self.timeout)
        return {"top_line_before": before, "top_line_after": self.top_line()}

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
              and self.step("mirror_shows_long_output", self.mirror_shows_long_output)
              and self.step("mirror_scrolled_up", self.mirror_scrolled_up))
        if ok:
            for name in MODIFIERS:
                ok = self.step(f"{name}_keeps_scrollback", lambda name=name: self.modifier_keeps_scrollback(name)) and ok
            ok = self.step("keystroke_returns_to_bottom", self.keystroke_returns_to_bottom) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per wait")
    parser.add_argument("--keep", action="store_true", help="leave the test workspace open")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    report_path = Path(args.report or ARTIFACTS_DIR / f"loopback_mirror_scrollback_e2e-{args.tag or 'socket'}.json")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = MirrorScrollbackE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except (OSError, Failure) as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-mirror-scrollback-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
