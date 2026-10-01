#!/usr/bin/env python3
"""End-to-end test: typing into another Mac's terminal behaves exactly like local typing,
and that terminal takes the size of the Mac you view it from.

A device mirror used to send its OWN Ghostty's encoding of each key as text, and the
other Mac re-parsed that text: Esc arrived as Escape plus a literal "[27u" under the
kitty keyboard protocol (Claude Code), a mouse drag arrived as Esc presses plus junk,
and modified keys printed garbage. The other Mac's terminal also stayed at the size of
its own hidden pane (small for a tab never shown there) instead of the viewer's.

This suite runs against one tagged DEBUG build with the loopback device ("Loopback Mac"
= this app's own mobile host), so the source workspace is the "other Mac" and its auto
mirror is the viewer. A recorder program in the SOURCE terminal turns on the kitty
keyboard protocol (flag 1, as Claude Code does), SGR mouse tracking and bracketed paste,
then logs every byte it receives as hex. Keys are pressed for real through the mirror's
Ghostty view (debug.shortcut.simulate / debug.type), so they take the same path a
keyboard does:

  1. setup                         auto-mirror on, the loopback linked and fetched
  2. source_gets_mirror            a background source workspace gets its mirror
  3. recorder_running              the recorder runs in the source and the mirror shows it
  4. mirror_focused                the mirror's terminal is the app's first responder
  5. key_<name>                    each key reaches the program exactly as the source Mac's
                                   own Ghostty encodes it (Esc -> CSI 27 u, no "[27u" text)
  6. mouse_drag_is_mouse_reports   a drag reaches the program as SGR mouse reports only
  7. keys_survive_reattach         after the link drops and the mirror re-attaches (a
                                   replay resets the mirror's keyboard flags), Shift+Enter
                                   still arrives as CSI 13;2 u
  8. hidden_source_pane_does_not_count
                                   the source Mac's hidden pane does not hold the grid
                                   down: the terminal takes the viewing mirror's grid
  9. hidden_mirror_does_not_count  a mirror that is not on screen stops counting

Writes a JSON report (default tests/supermux/artifacts/loopback_terminal_input_e2e-<tag>.json)
with expected and received hex per key, and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_terminal_input_e2e.py [--scratch DIR] [--timeout 30] [--report PATH]
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
REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = REPO_ROOT / "tests" / "supermux" / "artifacts"

RECORDER = r'''
import binascii, os, sys, termios, tty
out = sys.argv[1]
fd = sys.stdin.fileno()
tty.setraw(fd)
# kitty keyboard flag 1 (disambiguate, what Claude Code pushes), button+drag mouse
# tracking with SGR reports, bracketed paste.
sys.stdout.write("\x1b[>1u\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?2004hREC-READY\r\n")
sys.stdout.flush()
with open(out, "ab", 0) as log:
    while True:
        data = os.read(fd, 4096)
        if not data:
            break
        log.write(binascii.hexlify(data) + b"\n")
'''

# Key combo -> the bytes the SOURCE Mac's own Ghostty sends for it with kitty flag 1 on.
KEYS = [
    ("escape", "escape", "1b5b323775"),
    ("shift_enter", "shift+enter", "1b5b31333b3275"),
    ("ctrl_c", "ctrl+c", "1b5b39393b3575"),
    ("up", "up", "1b5b41"),
    ("shift_up", "shift+up", "1b5b313b3241"),
    ("tab", "tab", "09"),
    ("backspace", "backspace", "7f"),
]
SGR_MOUSE_STREAM = re.compile(r"^(1b5b3c(3[0-9]|3b)+(4d|6d))+$")


class Failure(Exception):
    """A check failed; the message says which and why."""


class RateLimited(Exception):
    def __init__(self, retry_after_s: float) -> None:
        super().__init__(f"rate limited for {retry_after_s}s")
        self.retry_after_s = max(0.05, retry_after_s)


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
        return self

    def close(self) -> None:
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    def call(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Any:
        for _ in range(20):
            try:
                return self._call_once(method, params, timeout_s)
            except RateLimited as limited:
                time.sleep(limited.retry_after_s)
        return self._call_once(method, params, timeout_s)

    def _call_once(self, method: str, params: Optional[Dict[str, Any]], timeout_s: Optional[float]) -> Any:
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
        if error.get("code") == "rate_limited":
            raise RateLimited(((error.get("data") or {}).get("retry_after_ms") or 100) / 1000.0)
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


def wait_for(description: str, probe: Callable[[], Any], timeout_s: float, interval_s: float = 0.3) -> Any:
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


class TerminalInputE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.timeout = args.timeout
        self.keep = args.keep
        self.nonce = uuid.uuid4().hex[:6]
        self.scratch = Path(args.scratch or f"/tmp/supermux-terminal-input-{self.nonce}")
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.machine = ""
        self.source_id = ""
        self.mirror_id = ""
        self.source_surface = ""
        self.mirror_surface = ""
        self.log_path = self.scratch / "input.hex"

    # -- reads ----------------------------------------------------------------

    def device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device in supermux.devices.list (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def mirrors_of_source(self) -> List[Dict[str, Any]]:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        return [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(self.source_id)]

    def surfaces(self, workspace_id: str) -> List[str]:
        panes = (self.sock.call("pane.list", {"workspace_id": workspace_id}) or {}).get("panes") or []
        return [up(surface) for pane in panes for surface in pane.get("surface_ids") or []]

    def mirror_panel_for(self, source_surface: str) -> Optional[str]:
        for projection in (self.sock.call("surface.catalog", {}) or {}).get("projections") or []:
            resource = str(projection.get("resource", ""))
            if up(projection.get("workspace_id")) == up(self.mirror_id) and up(resource.rsplit("/", 1)[-1]) == up(source_surface):
                return up(projection.get("panel_id"))
        return None

    def mirror_text(self) -> str:
        result = self.sock.call("surface.read_text", {"workspace_id": self.mirror_id, "surface_id": self.mirror_surface}) or {}
        return str(result.get("text") or "")

    def received_hex(self) -> str:
        try:
            return "".join(self.log_path.read_text().split())
        except FileNotFoundError:
            return ""

    def size_state(self, surface_id: str) -> Dict[str, Any]:
        payload = self.sock.call("terminal.size_state", {"surface_id": surface_id}) or {}
        return payload.get("size_state") or {}

    @staticmethod
    def participants(state: Dict[str, Any]) -> List[Dict[str, Any]]:
        rows = []
        for row in state.get("participants") or []:
            participant = row.get("participant") if isinstance(row.get("participant"), dict) else row
            rows.append({
                "id": participant.get("id"),
                "device_kind": participant.get("device_kind"),
                "viewport": participant.get("viewport"),
                "counts": row.get("counts"),
            })
        return rows

    @staticmethod
    def grid(state: Dict[str, Any]) -> Optional[tuple]:
        size = state.get("size") if isinstance(state.get("size"), dict) else state
        if size.get("cols") is None or size.get("rows") is None:
            return None
        return (int(size["cols"]), int(size["rows"]))

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
        print(f"{'PASS' if record['ok'] else 'FAIL'} {name} ({record['seconds']}s)"
              + ("" if record["ok"] else ": " + record["error"]), file=sys.stderr)
        return record["ok"]

    def setup(self) -> Dict[str, Any]:
        self.scratch.mkdir(parents=True, exist_ok=True)
        (self.scratch / "recorder.py").write_text(RECORDER)
        state = self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True}) or {}

        def ready() -> Optional[Dict[str, Any]]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        self.machine = wait_for("the loopback device to connect", ready, self.timeout)["machine"]
        self.facts["machine"] = self.machine
        return {"machine": self.machine, "auto_mirror": state.get("auto_mirror")}

    def source_gets_mirror(self) -> Dict[str, Any]:
        created = self.sock.call("workspace.create", {"title": f"input-{self.nonce}", "focus": False}) or {}
        self.source_id = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not self.source_id:
            raise Failure(f"workspace.create returned no id: {created}")
        self.mirror_id = up(wait_for("the auto-mirror of the source", lambda: (self.mirrors_of_source() or [None])[0],
                                     self.timeout)["workspace_id"])
        self.source_surface = wait_for("the source's terminal", lambda: self.surfaces(self.source_id), self.timeout)[0]
        self.mirror_surface = wait_for("the mirror to project the source's terminal",
                                       lambda: self.mirror_panel_for(self.source_surface), self.timeout)
        self.facts.update(source_workspace_id=self.source_id, mirror_workspace_id=self.mirror_id,
                          source_surface=self.source_surface, mirror_surface=self.mirror_surface)
        return {"source": self.source_id, "mirror": self.mirror_id}

    def recorder_running(self) -> Dict[str, Any]:
        command = f"python3 {self.scratch / 'recorder.py'} {self.log_path}\n"
        self.sock.call("surface.send_text", {"workspace_id": self.source_id, "surface_id": self.source_surface, "text": command})
        wait_for("the recorder's REC-READY in the mirror", lambda: "REC-READY" in self.mirror_text(), self.timeout)
        wait_for("the recorder's log file", lambda: self.log_path.exists(), self.timeout)
        return {"log": str(self.log_path)}

    def mirror_focused(self) -> Dict[str, Any]:
        self.sock.call("workspace.select", {"workspace_id": self.mirror_id})
        self.sock.call("surface.focus", {"workspace_id": self.mirror_id, "surface_id": self.mirror_surface})
        self.sock.call("debug.app.activate", {})

        def focused() -> bool:
            result = self.sock.call("debug.terminal.is_focused", {"surface_id": self.mirror_surface}) or {}
            if not result.get("focused"):
                self.sock.call("surface.focus", {"workspace_id": self.mirror_id, "surface_id": self.mirror_surface})
            return bool(result.get("focused"))

        wait_for("the mirror terminal to take keyboard focus", focused, self.timeout)
        time.sleep(0.5)
        return {}

    def received_after(self, send: Callable[[], None], settle_s: float = 0.8) -> str:
        """Bytes the recorder got for one input, as hex."""
        before = self.received_hex()
        send()
        wait_for("the recorder to receive the input", lambda: len(self.received_hex()) > len(before), self.timeout, 0.1)
        time.sleep(settle_s)
        return self.received_hex()[len(before):]

    def key_check(self, combo: str, expected: str) -> Callable[[], Dict[str, Any]]:
        def run() -> Dict[str, Any]:
            got = self.received_after(lambda: self.sock.call("debug.shortcut.simulate", {"combo": combo}))
            if got != expected:
                raise Failure(f"{combo}: expected {expected}, the program received {got}")
            return {"combo": combo, "expected_hex": expected, "received_hex": got}
        return run

    def typed_text(self) -> Dict[str, Any]:
        expected = "hé".encode("utf-8").hex()
        got = self.received_after(lambda: self.sock.call("debug.type", {"text": "hé"}))
        if got != expected:
            raise Failure(f"typed text: expected {expected}, the program received {got}")
        return {"expected_hex": expected, "received_hex": got}

    def mouse_drag(self) -> Dict[str, Any]:
        got = self.received_after(lambda: self.sock.call("supermux.devices.terminal_mouse_drag", {
            "surface_id": self.mirror_surface, "from": [0.2, 0.5], "to": [0.5, 0.5],
        }))
        if not SGR_MOUSE_STREAM.match(got):
            raise Failure(f"a drag must arrive as SGR mouse reports only, the program received {got}")
        if not got.endswith("6d"):
            raise Failure(f"the drag's release report is missing: {got}")
        return {"received_hex": got}

    def keys_survive_reattach(self) -> Dict[str, Any]:
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        time.sleep(1.0)
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})

        def reconnected() -> bool:
            device = self.device()
            return device.get("link_state") == "connected"

        wait_for("the loopback link to reconnect", reconnected, self.timeout)
        wait_for("the mirror to re-attach (REC-READY replayed)", lambda: "REC-READY" in self.mirror_text(), self.timeout)
        time.sleep(1.5)
        self.mirror_focused()
        return self.key_check("shift+enter", "1b5b31333b3275")()

    def hidden_source_pane(self) -> Dict[str, Any]:
        """The mirror is on screen and the source is not: the mirror's grid wins."""
        self.sock.call("workspace.select", {"workspace_id": self.mirror_id})

        def follows_viewer() -> Optional[Dict[str, Any]]:
            state = self.size_state(self.source_surface)
            rows = self.participants(state)
            mac = next((r for r in rows if str(r["id"]).startswith("mac:")), None)
            viewer = next((r for r in rows if str(r["id"]).startswith("mobile:")), None)
            if not viewer or not viewer.get("viewport"):
                raise Failure(f"the viewing mirror is not a participant yet: {rows}")
            want = (int(viewer["viewport"]["cols"]), int(viewer["viewport"]["rows"]))
            if mac and mac.get("counts"):
                raise Failure(f"the source Mac's hidden pane still counts: {rows}, grid {self.grid(state)}")
            if self.grid(state) != want:
                raise Failure(f"grid {self.grid(state)} != the viewer's {want}: {rows}")
            return {"grid": list(want), "participants": rows}

        return wait_for("the source terminal to take the viewing mirror's grid", follows_viewer, self.timeout)

    def hidden_mirror(self) -> Dict[str, Any]:
        """Showing the source instead hides the mirror, which then stops counting."""
        self.sock.call("workspace.select", {"workspace_id": self.source_id})

        def stopped() -> Optional[Dict[str, Any]]:
            rows = self.participants(self.size_state(self.source_surface))
            viewer = next((r for r in rows if str(r["id"]).startswith("mobile:")), None)
            mac = next((r for r in rows if str(r["id"]).startswith("mac:")), None)
            if viewer and viewer.get("counts"):
                raise Failure(f"the hidden mirror still counts: {rows}")
            if not mac or not mac.get("counts"):
                raise Failure(f"the source pane on screen does not count: {rows}")
            return {"participants": rows}

        try:
            return wait_for("the hidden mirror to stop counting", stopped, self.timeout)
        finally:
            self.sock.call("workspace.select", {"workspace_id": self.mirror_id})

    # -- run ------------------------------------------------------------------

    def cleanup(self) -> None:
        if self.keep:
            return
        for workspace_id in (self.mirror_id, self.source_id):
            if not workspace_id:
                continue
            try:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except Failure as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        ok = (self.step("setup", self.setup)
              and self.step("source_gets_mirror", self.source_gets_mirror)
              and self.step("recorder_running", self.recorder_running)
              and self.step("mirror_focused", self.mirror_focused))
        if ok:
            for name, combo, expected in KEYS:
                ok = self.step(f"key_{name}", self.key_check(combo, expected)) and ok
            ok = self.step("typed_text", self.typed_text) and ok
            ok = self.step("mouse_drag_is_mouse_reports", self.mouse_drag) and ok
            ok = self.step("keys_survive_reattach", self.keys_survive_reattach) and ok
            ok = self.step("hidden_source_pane_does_not_count", self.hidden_source_pane) and ok
            ok = self.step("hidden_mirror_does_not_count", self.hidden_mirror) and ok
        self.facts["received_hex_total"] = self.received_hex()
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
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
        test = TerminalInputE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-terminal-input-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_terminal_input_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
