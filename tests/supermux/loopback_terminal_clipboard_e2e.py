#!/usr/bin/env python3
"""End-to-end test: the clipboard works in another Mac's terminal as in a terminal on this Mac.

A device mirror is a local Ghostty surface fed with the other Mac's PTY output. It
used to drop every clipboard write that terminal asked for (a program's OSC 52 copy
from Claude Code, tmux or nvim, keyboard copy mode's yank), and a pasted image or a
dropped file typed the path of a file on THIS Mac (a temporary file for an image),
which names nothing on the Mac that runs the terminal.

This suite runs against one tagged DEBUG build with the loopback device ("Loopback Mac"
= this app's own mobile host), so the source workspace is the "other Mac" and its auto
mirror is the viewer. Both "Macs" are this app, so the source terminal's own Ghostty
also handles an OSC 52; the app's DEBUG record of each terminal's clipboard writes
(`supermux.devices.terminal_clipboard.writes`) tells the mirror's write from the
source's. The suite snapshots this Mac's general pasteboard first and restores it last.

  1. setup                          auto-mirror on, the loopback linked and fetched
  2. clipboard_saved                the user's clipboard is snapshotted (restored at the end)
  3. source_gets_mirror             a background source workspace gets its mirror
  4. osc52_copy_reaches_this_mac    a program's OSC 52 copy in the source terminal is
                                    written to this Mac's clipboard BY THE MIRROR
  5. recorder_running               a recorder (bracketed paste on) logs every byte the
                                    source terminal receives; its last line is a marker
  6. mirror_focused                 the mirror's terminal is the app's first responder
  7. cmd_v_text_reaches_remote      Cmd+V of plain text in the mirror reaches the program
                                    as one bracketed paste
  8. copy_mode_yank_reaches_clipboard
                                    keyboard copy mode (Cmd+Shift+M, then Y) in the mirror
                                    copies the marker line to this Mac's clipboard
  9. image_paste_uploads            Cmd+V of an image types a path under the owning Mac's
                                    ~/.cache/cmux/task-attachments, never a local temp path,
                                    and that file holds the image
 10. file_drop_uploads              a file dropped on the mirror is uploaded the same way
 11. old_host_types_nothing         when the owning Mac does not serve uploads
                                    (supermux.terminal_attachments.v1), an image paste types
                                    nothing and the upload-failed notification says to update

Writes a JSON report (default tests/supermux/artifacts/loopback_terminal_clipboard_e2e-<tag>.json)
and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_terminal_clipboard_e2e.py [--scratch DIR] [--timeout 30] [--report PATH]
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import struct
import sys
import time
import zlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_terminal_input_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    Failure,
    Socket,
    TerminalInputE2E,
    socket_path_for_tag,
    wait_for,
)

ATTACHMENTS_ROOT = Path.home() / ".cache" / "cmux" / "task-attachments"

# Logs every byte the terminal gets as hex. Bracketed paste on, so a paste arrives
# wrapped in ESC[200~ … ESC[201~. The cursor stays on the marker line, which is what
# copy mode's Y copies.
RECORDER = r'''
import binascii, os, sys, tty
out, marker = sys.argv[1], sys.argv[2]
fd = sys.stdin.fileno()
tty.setraw(fd)
sys.stdout.write("\x1b[?2004hREC-READY\r\n" + marker)
sys.stdout.flush()
with open(out, "ab", 0) as log:
    while True:
        data = os.read(fd, 4096)
        if not data:
            break
        log.write(binascii.hexlify(data) + b"\n")
'''

PASTE_START, PASTE_END = b"\x1b[200~", b"\x1b[201~"


def tiny_png(seed: int) -> bytes:
    """A 2x2 RGB PNG whose pixels depend on `seed`."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    pixel = bytes([seed & 0xFF, (seed >> 8) & 0xFF, 0x80])
    raw = b"".join(b"\x00" + pixel * 2 for _ in range(2))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def typed_path(received: bytes) -> str:
    """The one path a paste or drop typed: bracketed-paste markers dropped, shell escaping undone."""
    text = received.replace(PASTE_START, b"").replace(PASTE_END, b"").decode("utf-8", errors="replace").strip()
    if text.startswith("'") and text.endswith("'"):
        return text[1:-1].replace("'\\''", "'")
    return re.sub(r"\\(.)", r"\1", text)


class TerminalClipboardE2E(TerminalInputE2E):
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        super().__init__(sock, args)
        self.marker = f"COPY-LINE-{self.nonce}"
        self.uploaded: List[Path] = []
        self.clipboard_saved_ok = False

    # -- drivers ----------------------------------------------------------------

    def clipboard(self, action: str, **params: Any) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.terminal_clipboard.pasteboard", {"action": action, **params}) or {}

    def clipboard_text(self) -> str:
        return str(self.clipboard("read_text").get("text") or "")

    def mirror_writes(self, clear: bool = False) -> List[Dict[str, Any]]:
        reply = self.sock.call("supermux.devices.terminal_clipboard.writes",
                               {"surface_id": self.mirror_surface, "clear": clear}) or {}
        return reply.get("writes") or []

    def press(self, combo: str) -> None:
        self.sock.call("debug.shortcut.simulate", {"combo": combo})

    def received_bytes_after(self, send, settle_s: float = 0.8) -> bytes:
        return bytes.fromhex(self.received_after(send, settle_s))

    def accepted_standard_write(self) -> Optional[List[Dict[str, Any]]]:
        writes = self.mirror_writes()
        if any(w.get("accepted") and w.get("location") == "standard" for w in writes):
            return writes
        if writes:
            raise Failure(f"the mirror's terminal asked to write the clipboard and the write was dropped: {writes}")
        return None

    def uploaded_file(self, received: bytes, want: bytes, what: str) -> Dict[str, Any]:
        path = typed_path(received)
        if not path:
            raise Failure(f"the {what} typed nothing (received {received!r})")
        resolved = Path(path)
        if ATTACHMENTS_ROOT not in resolved.parents:
            raise Failure(f"the {what} typed {path!r}, not a file uploaded to the owning Mac's {ATTACHMENTS_ROOT}")
        if not resolved.is_file():
            raise Failure(f"the {what} typed {path!r}, which does not exist on the owning Mac")
        self.uploaded.append(resolved)
        got = resolved.read_bytes()
        if got != want:
            raise Failure(f"{path} holds {len(got)} bytes, not the {len(want)} bytes that were {what}d")
        return {"typed_path": path, "bytes": len(got)}

    # -- steps ------------------------------------------------------------------

    def clipboard_saved(self) -> Dict[str, Any]:
        reply = self.clipboard("snapshot")
        self.clipboard_saved_ok = True
        return {"items": reply.get("items")}

    def osc52_copy_reaches_this_mac(self) -> Dict[str, Any]:
        """A program's OSC 52 copy (what Claude Code, tmux and nvim send) in the other
        Mac's terminal lands on this Mac's clipboard, written by the mirror."""
        wait_for("the mirror to show the source's shell", lambda: self.mirror_text().strip(), self.timeout)
        self.mirror_writes(clear=True)
        text = f"osc52-{self.nonce}"
        payload = base64.b64encode(text.encode()).decode()
        command = f"printf '\\033]52;c;{payload}\\a'; echo OSC52-SENT-{self.nonce}\n"
        self.sock.call("surface.send_text", {"workspace_id": self.source_id, "surface_id": self.source_surface,
                                             "text": command})
        wait_for("the command's output in the mirror", lambda: f"OSC52-SENT-{self.nonce}" in self.mirror_text(),
                 self.timeout)
        writes = wait_for("the mirror's accepted clipboard write", self.accepted_standard_write, 10)
        wait_for("the copied text on this Mac's clipboard", lambda: self.clipboard_text() == text, 10)
        return {"mirror_writes": writes, "clipboard": text}

    def recorder_running(self) -> Dict[str, Any]:
        (self.scratch / "clipboard_recorder.py").write_text(RECORDER)
        command = f"python3 {self.scratch / 'clipboard_recorder.py'} {self.log_path} {self.marker}\n"
        self.sock.call("surface.send_text", {"workspace_id": self.source_id, "surface_id": self.source_surface,
                                             "text": command})
        wait_for("the recorder's marker in the mirror", lambda: self.marker in self.mirror_text(), self.timeout)
        wait_for("the recorder's log file", lambda: self.log_path.exists(), self.timeout)
        return {"log": str(self.log_path)}

    def cmd_v_text_reaches_remote(self) -> Dict[str, Any]:
        text = f"paste-{self.nonce} ok"
        self.clipboard("write_text", text=text)
        got = self.received_bytes_after(lambda: self.press("cmd+v"))
        want = PASTE_START + text.encode() + PASTE_END
        if got != want:
            raise Failure(f"Cmd+V of {text!r}: the program received {got!r}, expected {want!r}")
        return {"received": got.decode(errors="replace")}

    def copy_mode_yank_reaches_clipboard(self) -> Dict[str, Any]:
        self.clipboard("write_text", text=f"before-yank-{self.nonce}")
        self.mirror_writes(clear=True)
        self.press("cmd+shift+m")
        time.sleep(0.5)
        self.press("shift+y")
        writes = wait_for("the mirror's accepted clipboard write", self.accepted_standard_write, 10)
        copied = wait_for("the marker line on this Mac's clipboard",
                          lambda: self.clipboard_text() if self.marker in self.clipboard_text() else None, 10)
        return {"mirror_writes": writes, "clipboard": copied}

    def image_paste_uploads(self) -> Dict[str, Any]:
        png = tiny_png(int(self.nonce[:4], 16))
        source = self.scratch / f"clip-{self.nonce}.png"
        source.write_bytes(png)
        self.clipboard("write_png", path=str(source))
        self.mirror_focused()
        received = self.received_bytes_after(lambda: self.press("cmd+v"), settle_s=1.5)
        return self.uploaded_file(received, png, "paste")

    def file_drop_uploads(self) -> Dict[str, Any]:
        source = self.scratch / f"drop {self.nonce}.txt"
        content = f"dropped from this Mac {self.nonce}\n".encode()
        source.write_bytes(content)
        received = self.received_bytes_after(lambda: self.sock.call("debug.terminal.simulate_file_drop", {
            "surface_id": self.mirror_surface, "paths": [str(source)],
            "route": "text_destination", "payload": "file_urls",
        }, timeout_s=30), settle_s=1.5)
        return self.uploaded_file(received, content, "drop")

    def old_host_types_nothing(self) -> Dict[str, Any]:
        """An owning Mac without uploads: the paste types nothing (no local path) and
        the failure says to update Supermux there."""
        self.sock.call("supermux.devices.terminal_clipboard.old_host", {"enabled": True})
        self.sock.call("supermux.devices.notification_overrides", {"suppress_when_app_focused": False})
        try:
            self.reattach()  # capabilities are fetched once per connection
            png = tiny_png(0x0BAD)
            source = self.scratch / f"old-{self.nonce}.png"
            source.write_bytes(png)
            self.clipboard("write_png", path=str(source))
            before = self.received_hex()
            self.press("cmd+v")

            def update_notice() -> Optional[Dict[str, Any]]:
                records = (self.sock.call("supermux.devices.notification_records", {}) or {}).get("records") or []
                return next((r for r in records if "Update Supermux" in str(r.get("body", ""))), None)

            notice = wait_for("the upload-failed notification", update_notice, self.timeout)
            time.sleep(1.5)
            typed = self.received_hex()[len(before):]
            if typed:
                raise Failure(f"the paste typed {bytes.fromhex(typed)!r} although the owning Mac cannot take the file")
            return {"notification": {k: notice.get(k) for k in ("title", "subtitle", "body")}}
        finally:
            self.sock.call("supermux.devices.terminal_clipboard.old_host", {"enabled": False})
            self.sock.call("supermux.devices.notification_overrides", {"suppress_when_app_focused": "live"})

    # -- run --------------------------------------------------------------------

    def cleanup(self) -> None:
        if self.clipboard_saved_ok:
            try:
                self.clipboard("restore")
            except Failure as error:
                self.facts.setdefault("cleanup_errors", []).append(f"clipboard restore: {error}")
        for path in self.uploaded:
            if ATTACHMENTS_ROOT in path.parents and path.parent != ATTACHMENTS_ROOT:
                shutil.rmtree(path.parent, ignore_errors=True)
        super().cleanup()

    def run(self) -> bool:
        ok = False
        try:
            ok = (self.step("setup", self.setup)
                  and self.step("clipboard_saved", self.clipboard_saved)
                  and self.step("source_gets_mirror", self.source_gets_mirror))
            if ok:
                ok = self.step("osc52_copy_reaches_this_mac", self.osc52_copy_reaches_this_mac) and ok
                ready = (self.step("recorder_running", self.recorder_running)
                         and self.step("mirror_focused", self.mirror_focused))
                ok = ok and ready
                if ready:
                    ok = self.step("cmd_v_text_reaches_remote", self.cmd_v_text_reaches_remote) and ok
                    ok = self.step("copy_mode_yank_reaches_clipboard", self.copy_mode_yank_reaches_clipboard) and ok
                    ok = self.step("image_paste_uploads", self.image_paste_uploads) and ok
                    ok = self.step("file_drop_uploads", self.file_drop_uploads) and ok
                    ok = self.step("old_host_types_nothing", self.old_host_types_nothing) and ok
        finally:
            self.facts["received_hex_total"] = self.received_hex()
            self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock)")
    parser.add_argument("--scratch", help="scratch directory for the recorder, its log and the pasted files")
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
        test = TerminalClipboardE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-terminal-clipboard-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_terminal_clipboard_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
