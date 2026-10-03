#!/usr/bin/env python3
"""End-to-end test: another Mac's terminal acts like a terminal on this Mac.

A device mirror is a local Ghostty surface fed with the other Mac's PTY output. Several
things a local terminal does stayed local to the mirror or were refused there:

- Cmd-click on a file path was refused (only SSH terminals resolved remote paths), so a
  path an agent printed could not be opened.
- Cmd+K cleared only this Mac's view: the other Mac kept the scrollback, and the next
  replay brought it all back.
- Ctrl+V with an image on this Mac's clipboard reached the other Mac as a bare Ctrl+V,
  so Claude Code or Codex there read THAT Mac's clipboard instead of the image copied here.

This suite runs against one tagged DEBUG build with the loopback device ("Loopback Mac"
= this app's own mobile host), so the source workspace is the "other Mac" and its auto
mirror is the viewer. It snapshots this Mac's general pasteboard first and restores it last.

  1. setup                          auto-mirror on, the loopback linked and fetched
  2. clipboard_saved                the user's clipboard is snapshotted (restored at the end)
  3. source_gets_mirror             a background source workspace gets its mirror
  4. title_matches_source           after the program sets a title (OSC 2) the mirror's tab is
                                    titled as the source Mac's own tab
  5. cmd_click_file_opens_preview   a Cmd-click on a relative `path:line` in the mirror (the
                                    terminal link coordinator, as a click runs it) resolves it
                                    against the source terminal's folder and opens the other
                                    Mac's file in a read-only preview with its exact bytes;
                                    nothing is opened on this Mac
  6. cmd_click_directory_ignored    a Cmd-click on a folder opens nothing (no preview, nothing
                                    handed to macOS)
  7. cmd_k_clears_source_scrollback Cmd+K in the mirror clears the source terminal's own
                                    scrollback, and a re-attach (a replay) does not bring it back
  8. focus_recorder_running         a recorder (focus reporting, mode 1004, and bracketed paste
                                    on) logs every byte the source terminal receives
  9. focus_out_reaches_remote       the mirror losing focus sends ESC [ O to the program once
 10. focus_in_reaches_remote        the mirror gaining focus sends ESC [ I to the program once
 11. ctrl_v_text_passes_through     Ctrl+V with text on the clipboard reaches the program as
                                    Ctrl+V (0x16), unchanged
 12. ctrl_v_image_uploads           Ctrl+V with only an image on the clipboard uploads it to the
                                    owning Mac and pastes that path (as Cmd+V does)

Writes a JSON report (default tests/supermux/artifacts/loopback_terminal_polish_e2e-<tag>.json)
and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_terminal_polish_e2e.py [--scratch DIR] [--timeout 30] [--report PATH]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_terminal_clipboard_e2e import (  # noqa: E402
    PASTE_END,
    PASTE_START,
    TerminalClipboardE2E,
    tiny_png,
)
from loopback_terminal_input_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    Failure,
    Socket,
    socket_path_for_tag,
    up,
    wait_for,
)

# Logs every byte the terminal gets as hex, with focus reporting (mode 1004) and
# bracketed paste on, as Claude Code and vim turn them on.
FOCUS_RECORDER = r'''
import binascii, os, sys, tty
out = sys.argv[1]
fd = sys.stdin.fileno()
tty.setraw(fd)
sys.stdout.write("\x1b[?1004h\x1b[?2004hFOCUS-READY\r\n")
sys.stdout.flush()
with open(out, "ab", 0) as log:
    while True:
        data = os.read(fd, 4096)
        if not data:
            break
        log.write(binascii.hexlify(data) + b"\n")
'''

FOCUS_IN, FOCUS_OUT = "1b5b49", "1b5b4f"


class TerminalPolishE2E(TerminalClipboardE2E):
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        super().__init__(sock, args)
        self.project: Optional[Path] = None
        self.other_id = ""

    # -- drivers ----------------------------------------------------------------

    def send_source(self, text: str) -> None:
        self.sock.call("surface.send_text", {"workspace_id": self.source_id, "surface_id": self.source_surface,
                                             "text": text})

    def read(self, workspace_id: str, surface_id: str, scrollback: bool = True) -> str:
        result = self.sock.call("surface.read_text", {"workspace_id": workspace_id, "surface_id": surface_id,
                                                      "scrollback": scrollback}) or {}
        return str(result.get("text") or "")

    def files(self, action: str, **params: Any) -> Dict[str, Any]:
        payload = {"workspace_id": self.mirror_id, "action": action, **params}
        return self.sock.call("supermux.devices.mirror.files", payload, timeout_s=60) or {}

    def link_open(self, text: str) -> Dict[str, Any]:
        """A Cmd-click on `text` in the mirror's terminal, through the terminal link
        coordinator a click runs; anything handed to macOS is captured, never opened."""
        return self.sock.call("supermux.devices.mirror.link_open", {
            "workspace_id": self.mirror_id, "surface_id": self.mirror_surface,
            "url": text, "destination": "setting",
        }) or {}

    def previews(self, remote_path: str) -> list:
        return (self.files("preview", path=remote_path).get("panels") or [])

    def focus_counts(self, hex_text: str) -> Dict[str, int]:
        return {"in": hex_text.count(FOCUS_IN), "out": hex_text.count(FOCUS_OUT)}

    def select_other_workspace(self) -> None:
        if not self.other_id:
            created = self.sock.call("workspace.create", {"title": f"other-{self.nonce}", "focus": False}) or {}
            self.other_id = up(created.get("workspace_id") or created.get("created_workspace_id"))
        self.sock.call("workspace.select", {"workspace_id": self.other_id})

    # -- steps ------------------------------------------------------------------

    def tab_title(self, workspace_id: str, surface_id: str) -> str:
        surfaces = (self.sock.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        row = next((s for s in surfaces if up(s.get("id")) == surface_id), None)
        return str((row or {}).get("title") or "")

    def title_matches_source(self) -> Dict[str, Any]:
        """A title the program sets (OSC 2) leaves the mirror's tab titled as the source
        Mac's own tab: device records own a mirror's tab names, so the mirror shows what
        the other Mac shows for that terminal."""
        title = f"T-{self.nonce}"
        wait_for("the mirror to show the source's shell", lambda: self.mirror_text().strip(), self.timeout)
        # The sleep keeps the shell from setting its own title at the next prompt.
        self.send_source(f"printf '\\033]2;{title}\\007'; sleep 6\n")
        time.sleep(3.0)

        def same() -> Dict[str, str]:
            source = self.tab_title(self.source_id, self.source_surface)
            mirror = self.tab_title(self.mirror_id, self.mirror_surface)
            if not source or source != mirror:
                raise Failure(f"the mirror's tab is titled {mirror!r}, the source's {source!r}")
            return {"source_title": source, "mirror_title": mirror}

        titles = wait_for("the mirror's tab title to match the source's", same, 10)
        time.sleep(3.5)  # the sleep ends
        return titles

    def cmd_click_file_opens_preview(self) -> Dict[str, Any]:
        self.project = self.scratch.resolve() / f"project-{self.nonce}"
        (self.project / "sub").mkdir(parents=True, exist_ok=True)
        notes = self.project / "sub" / "notes.txt"
        notes.write_text(f"line one {self.nonce}\nline two\n")
        self.send_source(f"cd '{self.project}' && echo CD-DONE-{self.nonce}\n")
        wait_for("the cd in the mirror", lambda: f"CD-DONE-{self.nonce}" in self.mirror_text(), self.timeout)

        def rooted() -> Dict[str, Any]:
            state = self.files("state")
            if os.path.realpath(str(state.get("root_path") or "")) != os.path.realpath(self.project):
                raise Failure(f"the mirror's folder is {state.get('root_path')}")
            return state

        wait_for("the mirror to know the source terminal's folder", rooted, self.timeout)
        reply = self.link_open("sub/notes.txt:2")
        if reply.get("external_url"):
            raise Failure(f"the click handed {reply['external_url']} to this Mac: {reply}")
        want = hashlib.sha256(notes.read_bytes()).hexdigest()
        remote_path = str(notes)

        def opened() -> list:
            panels = self.previews(remote_path) or self.previews(os.path.realpath(remote_path))
            if not panels:
                raise Failure(f"no preview of {remote_path} (click reply {reply})")
            if [p.get("sha256") for p in panels] != [want]:
                raise Failure(f"the preview shows other bytes: {panels} (expected {want})")
            return panels

        panels = wait_for("the other Mac's file in a read-only preview", opened, self.timeout)
        return {"click": reply, "preview": panels}

    def mirror_tabs(self) -> set:
        surfaces = (self.sock.call("surface.list", {"workspace_id": self.mirror_id}) or {}).get("surfaces") or []
        return {up(s.get("id")) for s in surfaces}

    def cmd_click_directory_ignored(self) -> Dict[str, Any]:
        before = self.mirror_tabs()
        reply = self.link_open("sub")
        time.sleep(1.5)
        after = self.mirror_tabs()
        if reply.get("external_url"):
            raise Failure(f"the folder click handed {reply['external_url']} to this Mac")
        if after - before:
            raise Failure(f"the folder click opened tabs {sorted(after - before)}")
        return {"click": reply}

    def cmd_k_clears_source_scrollback(self) -> Dict[str, Any]:
        marker = f"SCROLL-{self.nonce}"
        self.send_source(f"for i in $(seq 1 150); do echo {marker}-$i; done; echo FILLED-{self.nonce}\n")
        wait_for("the filled output in the mirror", lambda: f"FILLED-{self.nonce}" in self.mirror_text(), self.timeout)
        first = f"{marker}-3\n"
        if first not in self.read(self.source_id, self.source_surface):
            raise Failure("the source terminal's scrollback does not hold the early lines to clear")
        self.mirror_focused()
        self.press("cmd+k")

        def source_cleared() -> bool:
            text = self.read(self.source_id, self.source_surface)
            if first in text:
                raise Failure("the source terminal still holds the scrollback")
            return True

        wait_for("the source terminal's scrollback to clear", source_cleared, 10)
        if first in self.read(self.mirror_id, self.mirror_surface):
            raise Failure("the mirror's own view still holds the scrollback")
        # A re-attach replays the source terminal into the mirror: the scrollback stays gone.
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        time.sleep(1.0)
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        wait_for("the loopback link to reconnect", lambda: self.device().get("link_state") == "connected", self.timeout)
        time.sleep(3.0)
        if first in self.read(self.mirror_id, self.mirror_surface):
            raise Failure("the replay after a re-attach brought the scrollback back")
        return {"cleared": True}

    def focus_recorder_running(self) -> Dict[str, Any]:
        (self.scratch / "focus_recorder.py").write_text(FOCUS_RECORDER)
        self.send_source(f"python3 {self.scratch / 'focus_recorder.py'} {self.log_path}\n")
        wait_for("the recorder in the mirror", lambda: "FOCUS-READY" in self.mirror_text(), self.timeout)
        wait_for("the recorder's log file", lambda: self.log_path.exists(), self.timeout)
        self.mirror_focused()
        time.sleep(1.0)
        return {"log": str(self.log_path)}

    def focus_out_reaches_remote(self) -> Dict[str, Any]:
        before = self.received_hex()
        self.select_other_workspace()
        time.sleep(1.5)
        got = self.focus_counts(self.received_hex()[len(before):])
        if got != {"in": 0, "out": 1}:
            raise Failure(f"the mirror losing focus reached the program as {got} (want one ESC [ O)")
        return {"focus_reports": got}

    def focus_in_reaches_remote(self) -> Dict[str, Any]:
        before = self.received_hex()
        self.mirror_focused()
        time.sleep(1.0)
        got = self.focus_counts(self.received_hex()[len(before):])
        if got != {"in": 1, "out": 0}:
            raise Failure(f"the mirror gaining focus reached the program as {got} (want one ESC [ I)")
        return {"focus_reports": got}

    def ctrl_v_text_passes_through(self) -> Dict[str, Any]:
        self.clipboard("write_text", text=f"ctrl-v-text-{self.nonce}")
        self.mirror_focused()
        got = self.received_bytes_after(lambda: self.press("ctrl+v"))
        if got != b"\x16":
            raise Failure(f"Ctrl+V with text on the clipboard reached the program as {got!r}, not 0x16")
        return {"received": got.hex()}

    def ctrl_v_image_uploads(self) -> Dict[str, Any]:
        png = tiny_png(int(self.nonce[2:6], 16))
        source = self.scratch / f"ctrlv-{self.nonce}.png"
        source.write_bytes(png)
        self.clipboard("write_png", path=str(source))
        self.mirror_focused()
        received = self.received_bytes_after(lambda: self.press("ctrl+v"), settle_s=1.5)
        if received == b"\x16":
            raise Failure("Ctrl+V of an image reached the other Mac as a bare Ctrl+V (it reads its own clipboard)")
        if not (received.startswith(PASTE_START) and received.endswith(PASTE_END)):
            raise Failure(f"Ctrl+V of an image typed {received!r}, not one bracketed paste of a path")
        return self.uploaded_file(received, png, "paste")

    # -- run --------------------------------------------------------------------

    def cleanup(self) -> None:
        if self.other_id and not self.keep:
            try:
                self.sock.call("workspace.close", {"workspace_id": self.other_id, "force": True})
            except Failure as error:
                self.facts.setdefault("cleanup_errors", []).append(f"close other: {error}")
        super().cleanup()

    def run(self) -> bool:
        ok = False
        try:
            ok = (self.step("setup", self.setup)
                  and self.step("clipboard_saved", self.clipboard_saved)
                  and self.step("source_gets_mirror", self.source_gets_mirror))
            if ok:
                ok = self.step("title_matches_source", self.title_matches_source) and ok
                if self.step("cmd_click_file_opens_preview", self.cmd_click_file_opens_preview):
                    ok = self.step("cmd_click_directory_ignored", self.cmd_click_directory_ignored) and ok
                else:
                    ok = False
                ok = self.step("cmd_k_clears_source_scrollback", self.cmd_k_clears_source_scrollback) and ok
                if self.step("focus_recorder_running", self.focus_recorder_running):
                    ok = self.step("focus_out_reaches_remote", self.focus_out_reaches_remote) and ok
                    ok = self.step("focus_in_reaches_remote", self.focus_in_reaches_remote) and ok
                    ok = self.step("ctrl_v_text_passes_through", self.ctrl_v_text_passes_through) and ok
                    ok = self.step("ctrl_v_image_uploads", self.ctrl_v_image_uploads) and ok
                else:
                    ok = False
        finally:
            self.facts["received_hex_total"] = self.received_hex()
            self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock)")
    parser.add_argument("--scratch", help="scratch directory for the recorder, its log and the test files")
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
        test = TerminalPolishE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-terminal-polish-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_terminal_polish_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
