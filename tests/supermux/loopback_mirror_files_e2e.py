#!/usr/bin/env python3
"""End-to-end test: a device mirror's Files panel shows the other Mac's files.

A mirror of another Mac's workspace used to show "Remote files unavailable: They are
on <Mac>." because no file-explorer provider could read another Mac's disk over the
device link. This suite runs against one tagged DEBUG build with the loopback device
("Loopback Mac" = this app's own mobile host), so a source workspace here is "the
other Mac" and its auto-mirror is the viewer. The panel is driven through the DEBUG
`supermux.devices.mirror.files` driver, which syncs a Files store exactly like the
right sidebar (resolver, provider, follow-the-folder observation, live refresh), and
what the mirror shows is compared with what THIS Mac's own panel shows for the same
folder (the loopback's files are on this disk too):

  1. device_connected                the loopback is linked and advertises supermux.files_read.v1
  2. scratch_tree                    a git repo with dotfiles, a nested match, an image, a 9 MiB
                                     file, a symlink out of the folder (-> /etc) and a sibling
                                     "outside" folder; README.md modified, NOTES.txt untracked
  3. source_and_mirror               a source workspace in that folder gets its mirror, whose
                                     target names the folder
  4. files_panel_lists_remote_root   the mirror's Files panel is the device provider at that
                                     folder and lists exactly what the local panel lists there
                                     (hidden files included, same order)
  5. expand_folder                   expanding src/ lists what the local panel lists
  6. symlink_escape_not_browsable    the symlink out of the folder cannot be expanded (an error
                                     naming the Mac, never /etc's entries)
  7. git_decorations_match_local     the mirror's git colors equal the local panel's
  8. open_file_preview               opening README.md (double-click path) opens a read-only
                                     preview in the mirror with the file's exact bytes; after
                                     the file changes there, opening it again reuses that preview,
                                     which shows the new bytes, and no error alert comes up
  9. large_file_capped               the 9 MiB file is refused (previews stop at 8 MB); opened
                                     the double-click way, the refusal is a sheet that names the
                                     limit while the app keeps answering, and OK dismisses it
 10. search_finds_remote_match       Find searches the other Mac (one hit, src/nested/deep.txt:1);
                                     a query that looks like an rg flag is only a pattern
 11. confinement_probes              raw files.* RPCs: `..`, a symlink escape, a directory read,
                                     a wrong expected_root and git internals are refused (git
                                     internals are readable, as in the local panel, never mutable);
                                     chunked reads, hidden listing and git status answer
 11b. named_pipe_read_refused        files.read of a named pipe in the folder is refused at once
                                     (it never waits for a writer) and the link stays up
 12. root_follows_remote_cd          `cd src` in the source terminal re-roots the mirror's panel,
                                     `cd ..` brings it back
 13. live_refresh                    a file created in the folder appears with no action
 13b. file_operations_on_the_other_mac
                                     the panel's context menu offers New File, New Folder,
                                     Rename, Duplicate and Move to Trash for a row (New File and
                                     New Folder for the empty area), and each runs on the other
                                     Mac's disk and the panel lists the result (git internals
                                     stay refused)
 13c. file_op_error_with_panel_hidden
                                     a Duplicate the other Mac refuses (.git/HEAD), run by a Files
                                     panel that has left its window (hidden while the operation
                                     ran), reports the failure as a sheet on the main window while
                                     the app keeps answering, and OK dismisses it
 14. link_drop_is_honest             with the link down the panel names the Mac and says it is not
                                     connected, with no rows; the redial brings the rows back
 15. older_host_fallback             (with --app-path) relaunched with the capability suppressed,
                                     the panel says to update Supermux on the Mac

Writes a JSON report (default tests/supermux/artifacts/loopback_mirror_files_e2e-<tag>.json, and
a copy there when --report points elsewhere) plus a window screenshot of the panel, and exits
non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_files_e2e.py --scratch /tmp/<tag>/files \\
      [--app-path "<App path printed by reload.sh>" --projects-file /tmp/<tag>/projects.json] \\
      [--timeout 30] [--report PATH]
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

LOOPBACK_DEVICE_ID = "5e1f10b0-0000-4000-8000-000000000001"
FILES_READ_CAPABILITY = "supermux.files_read.v1"
DEVICE_NAME = "Loopback Mac"
REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = REPO_ROOT / "tests" / "supermux" / "artifacts"
SUITE = "loopback_mirror_files_e2e"
BIG_FILE_BYTES = 9 * 1024 * 1024


class Failure(Exception):
    """A check failed; the message says which and why."""


class Skipped(Exception):
    """A check could not run (an earlier step it needs failed)."""


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

    def raw(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Dict[str, Any]:
        """The whole response object (`ok`, `result` or `error`)."""
        for attempt in range(2):
            try:
                return self._raw_once(method, params, timeout_s)
            except (BrokenPipeError, ConnectionResetError):
                if attempt:
                    raise
                # The app drops a connection that sat idle; dial again once.
                self.close()
                self.connect()
        raise Failure("unreachable")

    def call(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Any:
        response = self.raw(method, params, timeout_s)
        if response.get("ok") is True:
            return response.get("result")
        error = response.get("error") or {}
        raise Failure(f"{method}: {error.get('code', 'error')}: {error.get('message', 'unknown error')}")

    def _raw_once(self, method: str, params: Optional[Dict[str, Any]], timeout_s: Optional[float]) -> Dict[str, Any]:
        assert self._sock is not None, "not connected"
        request_id = self._next_id
        self._next_id += 1
        line = json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n"
        self._sock.sendall(line.encode("utf-8"))
        response = json.loads(self._read_line(timeout_s or self.timeout_s))
        if response.get("id") != request_id:
            raise Failure(f"{method}: mismatched response id")
        return response

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


def real(path: Any) -> str:
    return os.path.realpath(str(path or ""))


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


def git(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-c", "user.email=e2e@supermux.invalid", "-c", "user.name=Supermux E2E", *args],
        cwd=cwd, capture_output=True, text=True, check=True,
    )
    return result.stdout


def shape(rows: List[Dict[str, Any]]) -> List[Tuple[str, bool]]:
    """What a panel lists, in order: (name, is_directory)."""
    return [(str(row.get("name")), bool(row.get("is_directory"))) for row in rows or []]


def brief(state: Dict[str, Any]) -> Dict[str, Any]:
    """A state without its row tree, for failure messages."""
    return {key: value for key, value in state.items() if key not in ("rows", "git_status")} | {
        "row_names": [row.get("name") for row in state.get("rows") or []],
    }


class MirrorFilesE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.tag = args.tag or ""
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.base = Path(args.scratch or f"/tmp/supermux-mirror-files-{self.nonce}") / self.nonce
        self.root = self.base / "root"
        self.needle = f"needle-{self.nonce}"
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.report_stem = Path(args.report_path).with_suffix("")
        self.machine = ""
        self.source_id = ""
        self.mirror_id = ""
        self.remote_root = ""
        self.created: List[str] = []

    # -- reads ----------------------------------------------------------------

    def device(self, include_capabilities: bool = False) -> Dict[str, Any]:
        listing = self.sock.call("supermux.devices.list", {"include_capabilities": include_capabilities}, timeout_s=40) or {}
        for device in listing.get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device in supermux.devices.list (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def mirror_of(self, source_id: str) -> str:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        mirrors = [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(source_id)]
        return str(mirrors[0]["workspace_id"]) if len(mirrors) == 1 else ""

    def inspect(self, workspace_id: str) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.mirror.inspect", {"workspace_id": workspace_id}) or {}

    def files(self, action: str, timeout_s: float = 60, **params: Any) -> Dict[str, Any]:
        payload = {"workspace_id": self.mirror_id, "action": action, **params}
        return self.sock.call("supermux.devices.mirror.files", payload, timeout_s=timeout_s) or {}

    def state(self) -> Dict[str, Any]:
        return self.files("state")

    def device_state(self) -> Dict[str, Any]:
        """The mirror's panel once it shows the device provider, loaded."""
        state = self.state()
        resolved = state.get("resolved") or {}
        if resolved.get("kind") != "device" or state.get("provider_kind") != "device":
            raise Failure(f"panel is not on the device provider: {brief(state)}")
        if state.get("status_message") or state.get("is_loading") or not state.get("rows"):
            raise Failure(f"panel not loaded: {brief(state)}")
        return state

    def local_rows(self, path: Path) -> List[Dict[str, Any]]:
        return (self.files("local_rows", path=str(path)) or {}).get("rows") or []

    def remote(self, method: str, params: Dict[str, Any], timeout_s: int = 60) -> Tuple[Optional[Dict[str, Any]], Optional[str], str]:
        """One RPC to the loopback Mac's host over the device link: (result, error code, message)."""
        response = self.sock.raw("supermux.devices.request", {
            "machine": self.machine, "method": method, "params": params, "timeout_seconds": timeout_s,
        }, timeout_s=timeout_s + 10)
        if response.get("ok") is True:
            return ((response.get("result") or {}).get("result") or {}), None, ""
        error = response.get("error") or {}
        return None, str(error.get("code") or "error"), str(error.get("message") or "")

    def require(self, *names: str) -> None:
        for name in names:
            if not getattr(self, name):
                raise Skipped(f"needs {name} from an earlier step")

    def row(self, state: Dict[str, Any], name: str) -> Dict[str, Any]:
        for row in state.get("rows") or []:
            if row.get("name") == name:
                return row
        raise Failure(f"no {name} row: {[r.get('name') for r in state.get('rows') or []]}")

    def screenshot(self, label: str) -> Optional[str]:
        """Best effort: the app's window, copied next to the report."""
        try:
            shot = self.sock.call("debug.window.screenshot", {"label": f"mirror-files-{label}"}) or {}
        except Failure:
            return None
        path = str(shot.get("path") or "")
        if not path or not Path(path).exists():
            return None
        kept = self.report_stem.parent / f"{self.report_stem.name}-{label}.png"
        kept.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, kept)
        return str(kept)

    def cli(self, *args: str) -> None:
        """Best effort: the tagged app's CLI (for the right sidebar's mode)."""
        env = dict(os.environ, CMUX_TAG=self.tag)
        subprocess.run([str(REPO_ROOT / "scripts" / "cmux-debug-cli.sh"), *args],
                       capture_output=True, text=True, env=env, timeout=30, check=False)

    # -- steps ----------------------------------------------------------------

    def step(self, name: str, action: Callable[[], Optional[Dict[str, Any]]]) -> bool:
        started = time.monotonic()
        record: Dict[str, Any] = {"name": name}
        try:
            record.update(action() or {})
            record["ok"] = True
        except Skipped as skipped:
            record["ok"] = None
            record["skipped"] = str(skipped)
        except (Failure, subprocess.CalledProcessError, OSError) as error:
            record["ok"] = False
            record["error"] = str(error)
        record["seconds"] = round(time.monotonic() - started, 2)
        self.steps.append(record)
        label = {True: "PASS", False: "FAIL", None: "SKIP"}[record["ok"]]
        detail = record.get("error") or record.get("skipped")
        print(f"{label} {name} ({record['seconds']}s){': ' + detail if detail else ''}", file=sys.stderr)
        return record["ok"] is not False

    def device_connected(self) -> Dict[str, Any]:
        self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True})

        def ready() -> Dict[str, Any]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        self.machine = wait_for("the loopback device to connect", ready, self.timeout)["machine"]
        capabilities = self.device(include_capabilities=True).get("capabilities") or []
        self.facts.update(machine=self.machine, capabilities=capabilities)
        if FILES_READ_CAPABILITY not in capabilities:
            raise Failure(f"the loopback host does not advertise {FILES_READ_CAPABILITY}: {capabilities}")
        return {"machine": self.machine}

    def scratch_tree(self) -> Dict[str, Any]:
        root, outside = self.root, self.base / "outside"
        (root / "src" / "nested").mkdir(parents=True)
        outside.mkdir(parents=True)
        (outside / "secret.txt").write_text(f"secret-{self.nonce}\n")
        (root / "README.md").write_text("# files\n\nline one\n")
        (root / "src" / "main.swift").write_text('print("hello")\n')
        (root / "src" / "nested" / "deep.txt").write_text(f"{self.needle} is here\n")
        (root / ".env.example").write_text("KEY=value\n")
        (root / "image.png").write_bytes(base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
        with open(root / "big.bin", "wb") as handle:
            handle.write(os.urandom(BIG_FILE_BYTES))
        os.symlink("/etc", root / "link-out")
        git(root, "init", "-q", "-b", "main")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "initial")
        (root / "README.md").write_text(f"# files\n\nline one\nchanged-{self.nonce}\n")
        (root / "NOTES.txt").write_text("untracked\n")
        status = git(root, "status", "--porcelain").splitlines()
        self.facts.update(root=str(root), root_real=real(root))
        return {"root": str(root), "git_status": status}

    def source_and_mirror(self) -> Dict[str, Any]:
        self.require("machine")
        if not self.root.is_dir():
            raise Skipped("needs the scratch tree")
        created = self.sock.call("workspace.create", {"title": f"files-{self.nonce}", "cwd": str(self.root), "focus": False}) or {}
        source = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not source:
            raise Failure(f"workspace.create returned no id: {created}")
        self.created.append(source)
        self.source_id = source
        self.mirror_id = up(wait_for("the source's auto-mirror", lambda: self.mirror_of(source), self.timeout))

        def target() -> Dict[str, Any]:
            info = self.inspect(self.mirror_id).get("target") or {}
            if real(info.get("remote_directory")) != real(self.root):
                raise Failure(f"mirror target directory {info.get('remote_directory')!r}")
            return info

        info = wait_for("the mirror's target to name the folder", target, self.timeout)
        self.remote_root = str(info.get("remote_directory"))
        self.facts.update(source_id=self.source_id, mirror_id=self.mirror_id, remote_root=self.remote_root)
        return {"source": self.source_id, "mirror": self.mirror_id, "target": info}

    def files_panel_lists_remote_root(self) -> Dict[str, Any]:
        self.require("mirror_id")
        self.sock.call("workspace.select", {"workspace_id": self.mirror_id})
        self.cli("right-sidebar", "set", "files")
        state = wait_for("the mirror's Files panel to list the other Mac's folder", self.device_state, self.timeout)
        resolved = state.get("resolved") or {}
        problems = []
        if not resolved.get("is_available") or DEVICE_NAME not in str(resolved.get("display_target")):
            problems.append(f"resolver {resolved}")
        if real(state.get("root_path")) != real(self.root):
            problems.append(f"root {state.get('root_path')!r} != {self.root}")
        if state.get("search_scope") in ("unsupported", "local"):
            problems.append(f"search scope {state.get('search_scope')}")
        local = self.local_rows(self.root)
        if shape(state["rows"]) != shape(local):
            problems.append(f"rows {shape(state['rows'])} != local panel {shape(local)}")
        for name in (".git", ".env.example", "README.md", "src", "link-out", "big.bin"):
            if name not in [n for n, _ in shape(state["rows"])]:
                problems.append(f"{name} missing")
        if problems:
            raise Failure("; ".join(problems))
        time.sleep(1.0)
        return {"rows": shape(state["rows"]), "display_root_path": state.get("display_root_path"),
                "remote_identity": state.get("remote_identity"), "screenshot": self.screenshot("panel")}

    def expand_folder(self) -> Dict[str, Any]:
        self.require("mirror_id")
        src = self.row(self.device_state(), "src")
        node = (self.files("expand", path=src["path"]) or {}).get("node") or {}
        local = self.local_rows(self.root / "src")
        if node.get("error") or shape(node.get("children") or []) != shape(local):
            raise Failure(f"src/ children {shape(node.get('children') or [])} (error {node.get('error')!r}) != local {shape(local)}")
        return {"children": shape(node["children"])}

    def symlink_escape_not_browsable(self) -> Dict[str, Any]:
        self.require("mirror_id")
        link = self.row(self.device_state(), "link-out")
        node = (self.files("expand", path=link["path"]) or {}).get("node") or {}
        children = [c.get("name") for c in node.get("children") or []]
        if children or not node.get("error") or DEVICE_NAME not in str(node.get("error")):
            raise Failure(f"link-out -> /etc: children {children[:5]}, error {node.get('error')!r}")
        return {"error": node.get("error")}

    def git_decorations_match_local(self) -> Dict[str, Any]:
        self.require("mirror_id")
        local = (self.files("local_git_status", path=str(self.root)) or {}).get("git_status") or {}

        def matches() -> Dict[str, Any]:
            mirror = self.device_state().get("git_status") or {}
            if mirror != local:
                raise Failure(f"mirror {mirror} != local {local}")
            return mirror

        mirror = wait_for("the mirror's git colors to match the local panel", matches, self.timeout)
        if mirror.get("README.md") != "modified" or mirror.get("NOTES.txt") != "untracked":
            raise Failure(f"unexpected git status {mirror}")
        return {"git_status": mirror}

    def open_file_preview(self) -> Dict[str, Any]:
        self.require("mirror_id")
        readme = self.row(self.device_state(), "README.md")
        expected = hashlib.sha256((self.root / "README.md").read_bytes()).hexdigest()
        first = self.files("open", path=readme["path"])
        if not first.get("opened") or not first.get("read_only") or first.get("sha256") != expected:
            raise Failure(f"open README.md: {first} (expected sha256 {expected})")
        surfaces = (self.sock.call("surface.list", {"workspace_id": self.mirror_id}) or {}).get("surfaces") or []
        if up(first.get("panel_id")) not in [up(s.get("id")) for s in surfaces]:
            raise Failure(f"the preview {first.get('panel_id')} is not a tab of the mirror: {[s.get('id') for s in surfaces]}")
        # The file changes over there; opening it again refreshes the same preview
        # (the reuse path re-downloads into the read-only copy the panel shows).
        with (self.root / "README.md").open("a") as handle:
            handle.write(f"reopened-{self.nonce}\n")
        changed = hashlib.sha256((self.root / "README.md").read_bytes()).hexdigest()
        again = self.files("open", path=readme["path"])
        if up(again.get("panel_id")) != up(first.get("panel_id")) or again.get("panel_count") != 1:
            raise Failure(f"reopening made another preview: {again}")

        def refreshed() -> Dict[str, Any]:
            preview = self.files("preview", path=readme["path"])
            if (preview.get("alert") or {}).get("shown"):
                raise Failure(f"reopening showed an alert: {preview['alert']}")
            panels = preview.get("panels") or []
            if [p.get("sha256") for p in panels] != [changed]:
                raise Failure(f"the preview does not show the changed bytes yet: {panels} (expected {changed})")
            return preview

        try:
            shown = wait_for("the reused preview to show the changed file", refreshed, self.timeout)
        except Failure:
            self.dismiss_alert()
            raise
        time.sleep(1.0)
        return {"preview": first, "reopened": shown, "screenshot": self.screenshot("preview")}

    def dismiss_alert(self) -> None:
        """Best effort: answer an alert a failed step left up, so later steps can run."""
        try:
            self.files("dismiss_alert", timeout_s=10)
        except (Failure, OSError):
            pass

    def large_file_capped(self) -> Dict[str, Any]:
        self.require("mirror_id")
        big = self.row(self.device_state(), "big.bin")
        result = self.files("materialize", path=big["path"])
        if result.get("ok") or "8 MB" not in str(result.get("error")):
            raise Failure(f"9 MiB preview: {result}")
        # The double-click way the refusal is the coordinator's alert. It must not run
        # a nested modal session inside the open's main-actor task: that starves the
        # main queue, so every socket call (and every mirror) would wait for OK.
        started = self.files("open", path=big["path"], probe=False)
        if not started.get("started"):
            raise Failure(f"opening the 9 MiB file did not start: {started}")
        try:
            def alert_up() -> Dict[str, Any]:
                alert = self.files("alert", timeout_s=10)
                if not alert.get("shown"):
                    raise Failure(f"no alert yet: {alert}")
                return alert

            alert = wait_for("the 8 MB alert", alert_up, self.timeout)
            if "8 MB" not in " ".join(alert.get("texts") or []) or alert.get("presentation") != "sheet":
                raise Failure(f"the refusal alert: {alert}")
            answered = time.monotonic()
            self.sock.call("supermux.devices.list", {}, timeout_s=10)
            state = self.files("state", timeout_s=10)
            answered = round(time.monotonic() - answered, 2)
            if answered > 5 or not state.get("rows"):
                raise Failure(f"with the alert up the app took {answered}s to answer: {brief(state)}")
        finally:
            dismissed = self.files("dismiss_alert", timeout_s=10)
        if not dismissed.get("dismissed") or (self.files("alert", timeout_s=10) or {}).get("shown"):
            raise Failure(f"OK did not dismiss the alert: {dismissed}")
        return {"result": result, "alert": alert, "answered_seconds": answered}

    def search_finds_remote_match(self) -> Dict[str, Any]:
        self.require("mirror_id")
        self.device_state()
        self.cli("right-sidebar", "set", "find")
        found = self.files("search", query=self.needle)
        hits = [(r.get("relative_path"), r.get("line")) for r in found.get("results") or []]
        if found.get("scope") in ("unsupported", "local") or found.get("status") != "matches" or hits != [("src/nested/deep.txt", 1)]:
            raise Failure(f"search {self.needle}: {found}")
        flag = self.files("search", query="--version")
        if flag.get("status") != "no_matches":
            raise Failure(f"search '--version' was not a plain pattern: {flag}")
        self.cli("right-sidebar", "set", "files")
        return {"scope": found.get("scope"), "hits": hits}

    def confinement_probes(self) -> Dict[str, Any]:
        self.require("source_id", "remote_root")
        base = {"workspace_id": self.source_id, "expected_root": self.remote_root}
        read = "mobile.supermux.files.read"
        refused = [
            ("read ../outside/secret.txt", read, {"path": "../outside/secret.txt"}, "invalid_params"),
            ("read link-out/hosts", read, {"path": "link-out/hosts"}, "invalid_params"),
            ("list link-out", "mobile.supermux.files.list", {"path": "link-out", "show_hidden": True}, "invalid_params"),
            ("read a directory", read, {"path": "src"}, "invalid_params"),
            ("rename .git/HEAD", "mobile.supermux.files.rename", {"path": ".git/HEAD", "new_name": "HEAD2"}, "invalid_params"),
            ("read with a wrong expected_root", read, {"path": "README.md", "expected_root": str(self.base / "outside")}, "stale_root"),
        ]
        problems, outcomes = [], {}
        for label, method, params, code in refused:
            result, got, message = self.remote(method, {**base, **params})
            outcomes[label] = got or "ok"
            if got != code:
                problems.append(f"{label}: expected {code}, got {got or result} {message}")
        if (self.base / "outside" / "secret.txt").read_text() != f"secret-{self.nonce}\n" or not (self.root / ".git" / "HEAD").exists():
            problems.append("a refused probe touched the disk")

        readme = (self.root / "README.md").read_bytes()
        chunk, got, message = self.remote(read, {**base, "path": "README.md", "offset": 0, "length": 5})
        data = base64.b64decode((chunk or {}).get("data") or "")
        if got or data != readme[:5] or (chunk or {}).get("eof") is not False or (chunk or {}).get("size") != len(readme):
            problems.append(f"chunked read: {got} {message} {chunk}")
        head, got, message = self.remote(read, {**base, "path": ".git/HEAD"})
        if got or not base64.b64decode((head or {}).get("data") or "").startswith(b"ref:"):
            problems.append(f"read .git/HEAD (readable, like the local panel): {got} {message}")

        hidden, got, message = self.remote("mobile.supermux.files.list", {**base, "show_hidden": True})
        names = [e.get("name") for e in (hidden or {}).get("entries") or []]
        if got or ".env.example" not in names or ".git" not in names or not (hidden or {}).get("home"):
            problems.append(f"list show_hidden: {got} {message} {names} home={(hidden or {}).get('home')!r}")
        phone, got, message = self.remote("mobile.supermux.files.list", base)
        phone_names = [e.get("name") for e in (phone or {}).get("entries") or []]
        if got or any(name.startswith(".") for name in phone_names) or "README.md" not in phone_names:
            problems.append(f"list without show_hidden (the phone) must hide dotfiles: {got} {message} {phone_names}")

        status, got, message = self.remote("mobile.supermux.files.git_status", base)
        statuses = {e.get("path"): e.get("status") for e in (status or {}).get("statuses") or []}
        if got or not (status or {}).get("is_repository") or statuses.get("README.md") != "modified":
            problems.append(f"git_status: {got} {message} {status}")
        search, got, message = self.remote("mobile.supermux.files.search", {**base, "query": self.needle})
        paths = [r.get("path") for r in (search or {}).get("results") or []]
        if got or paths != ["src/nested/deep.txt"]:
            problems.append(f"search: {got} {message} {search}")
        if problems:
            raise Failure("; ".join(problems))
        return {"refused": outcomes}

    def named_pipe_read_refused(self) -> Dict[str, Any]:
        """A named pipe lists as a plain file, and opening it for reading waits for a writer.
        The host must refuse it at once: a read stuck in `open` misses the reply deadline, the
        link reconnects (every mirror of the Mac drops) and the host thread stays stuck."""
        self.require("source_id", "remote_root", "machine")
        pipe = self.root / f"pipe-{self.nonce}"
        os.mkfifo(pipe)
        base = {"workspace_id": self.source_id, "expected_root": self.remote_root}
        started = time.monotonic()
        try:
            _, got, message = self.remote("mobile.supermux.files.read", {**base, "path": pipe.name}, timeout_s=10)
        finally:
            seconds = round(time.monotonic() - started, 2)
            self.release_pipe(pipe)
        link = self.device().get("link_state")
        if got != "invalid_params" or seconds > 5 or link != "connected":
            raise Failure(f"read of a named pipe: {got} {message!r} after {seconds}s, link {link}")
        return {"code": got, "seconds": seconds}

    def release_pipe(self, pipe: Path) -> None:
        """Opens the pipe's write end once, freeing a host read stuck in `open`, then removes the
        pipe and waits for the link (a missed deadline makes it reconnect)."""
        try:
            os.close(os.open(pipe, os.O_WRONLY | os.O_NONBLOCK))
        except OSError:
            pass  # No reader is waiting, so nothing on the host is stuck.
        pipe.unlink(missing_ok=True)
        wait_for("the link to be connected", lambda: self.device().get("link_state") == "connected", self.timeout * 2)

    def root_follows_remote_cd(self) -> Dict[str, Any]:
        self.require("mirror_id", "source_id")
        surfaces = (self.sock.call("surface.list", {"workspace_id": self.source_id}) or {}).get("surfaces") or []
        terminals = [s["id"] for s in surfaces if s.get("type") == "terminal"]
        if not terminals:
            raise Failure("the source has no terminal")
        local_src = shape(self.local_rows(self.root / "src"))

        def rooted_at(path: Path, rows: Optional[List[Tuple[str, bool]]] = None) -> Callable[[], Dict[str, Any]]:
            def probe() -> Dict[str, Any]:
                state = self.device_state()
                if real(state.get("root_path")) != real(path) or (rows is not None and shape(state["rows"]) != rows):
                    raise Failure(f"panel at {state.get('root_path')} with {shape(state['rows'])}")
                return state
            return probe

        self.sock.call("surface.send_text", {"workspace_id": self.source_id, "surface_id": terminals[0], "text": "cd src\n"})
        moved = wait_for("the mirror's panel to follow `cd src`", rooted_at(self.root / "src", local_src), self.timeout)
        self.sock.call("surface.send_text", {"workspace_id": self.source_id, "surface_id": terminals[0], "text": "cd ..\n"})
        back = wait_for("the mirror's panel to follow `cd ..`", rooted_at(self.root), self.timeout)
        return {"moved_to": moved.get("root_path"), "back_to": back.get("root_path")}

    def live_refresh(self) -> Dict[str, Any]:
        self.require("mirror_id")
        self.device_state()
        name = f"new-{self.nonce}.txt"
        (self.root / name).write_text("fresh\n")
        started = time.monotonic()

        def listed() -> bool:
            return name in [n for n, _ in shape(self.device_state()["rows"])]

        wait_for(f"{name} to appear in the mirror's panel", listed, self.args.refresh_timeout, interval_s=0.25)
        return {"seconds_to_appear": round(time.monotonic() - started, 2)}

    def file_operations_on_the_other_mac(self) -> Dict[str, Any]:
        self.require("mirror_id")
        state = self.device_state()
        base = str(state["root_path"]).rstrip("/")
        expected = ["supermuxNewFile:", "supermuxNewFolder:", "supermuxRename:", "supermuxDuplicate:", "supermuxMoveToTrash:"]
        row_menu = self.files("menu", path=self.row(state, "src")["path"]).get("items")
        root_menu = self.files("menu").get("items")
        problems = []
        if row_menu != expected:
            problems.append(f"row menu {row_menu} != {expected}")
        if root_menu != expected[:2]:
            problems.append(f"empty-area menu {root_menu} != {expected[:2]}")

        def run(op: str, entry: str, **params: Any) -> Dict[str, Any]:
            result = self.files("operation", op=op, path=f"{base}/{entry}", **params)
            if not result.get("ok"):
                problems.append(f"{op} {entry}: {result}")
            return result

        def rows_include(name: str, present: bool = True) -> Callable[[], bool]:
            return lambda: (name in [n for n, _ in shape(self.device_state()["rows"])]) == present

        made, folder = f"made-{self.nonce}.txt", f"dir-{self.nonce}"
        renamed, copy = f"renamed-{self.nonce}.txt", f"renamed-{self.nonce} copy.txt"
        run("new_file", made)
        run("new_folder", folder)
        if not (self.root / made).is_file() or not (self.root / folder).is_dir():
            problems.append("New File / New Folder did not create on the other Mac's disk")
        else:
            wait_for(f"{made} in the panel", rows_include(made), self.timeout)
        run("rename", made, name=renamed)
        run("duplicate", renamed)
        if (self.root / made).exists() or not (self.root / renamed).is_file() or not (self.root / copy).is_file():
            problems.append(f"Rename / Duplicate: {sorted(p.name for p in self.root.iterdir())}")
        for name in (copy, renamed, folder):
            run("trash", name)
        if any((self.root / name).exists() for name in (copy, renamed, folder)):
            problems.append("Move to Trash left entries on the other Mac's disk")
        else:
            wait_for(f"{renamed} to leave the panel", rows_include(renamed, present=False), self.timeout)
        refused = self.files("operation", op="rename", path=f"{base}/.git/HEAD", name="HEAD2")
        if refused.get("ok") or not (self.root / ".git" / "HEAD").exists():
            problems.append(f"renaming .git/HEAD was not refused: {refused}")
        if problems:
            raise Failure("; ".join(problems))
        return {"row_menu": row_menu, "root_menu": root_menu, "git_internals": refused.get("error")}

    def file_op_error_with_panel_hidden(self) -> Dict[str, Any]:
        """A failed file operation must not run a nested modal inside the operation's
        main-actor task. With the panel's window gone (the Files panel or the right sidebar
        hidden while a slow operation ran on the other Mac) the error alert fell back to a bare
        `runModal()`, which starves the main queue: every socket call and mirror waits for OK."""
        self.require("mirror_id")
        base = str(self.device_state()["root_path"]).rstrip("/")
        self.files("expand", path=f"{base}/.git")
        started = self.files("menu_action", path=f"{base}/.git/HEAD", item="supermuxDuplicate:")
        if not started.get("started") or started.get("has_window"):
            raise Failure(f"the hidden panel's Duplicate did not start: {started}")
        problems: List[str] = []
        try:
            def alert_up() -> Dict[str, Any]:
                alert = self.files("alert", timeout_s=10)
                if not alert.get("shown"):
                    raise Failure(f"no alert yet: {alert}")
                return alert

            alert = wait_for("the Duplicate failure alert", alert_up, self.timeout)
            if alert.get("presentation") != "sheet":
                problems.append(f"the failure alert is not a sheet on the main window: {alert}")
            answered = time.monotonic()
            self.sock.call("supermux.devices.list", {}, timeout_s=10)
            answered = round(time.monotonic() - answered, 2)
            if answered > 5:
                problems.append(f"with the alert up the app took {answered}s to answer")
        finally:
            dismissed = self.files("dismiss_alert", timeout_s=10)
        if not dismissed.get("dismissed") or (self.files("alert", timeout_s=10) or {}).get("shown"):
            problems.append(f"OK did not dismiss the alert: {dismissed}")
        if (self.root / ".git" / "HEAD copy").exists():
            problems.append("the refused Duplicate wrote into .git on the other Mac")
        if problems:
            raise Failure("; ".join(problems))
        return {"alert": alert, "answered_seconds": answered}

    def link_drop_is_honest(self) -> Dict[str, Any]:
        self.require("mirror_id", "machine")
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        try:
            def honest() -> Dict[str, Any]:
                state = self.state()
                message = str(state.get("status_message") or "")
                if DEVICE_NAME not in message or "not connected" not in message or state.get("rows"):
                    raise Failure(f"link down: {brief(state)}")
                return state

            down = wait_for("the panel to say the Mac is not connected", honest, self.timeout)
        finally:
            self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        back = wait_for("the rows to come back after the redial", self.device_state, self.timeout * 2)
        return {"link_down_message": down.get("status_message"), "rows_after_redial": len(back.get("rows") or [])}

    def older_host_fallback(self) -> Dict[str, Any]:
        if not self.args.app_path:
            raise Skipped("pass --app-path to relaunch with the capability suppressed")
        self.require("machine")
        self.relaunch({"CMUX_DEBUG_SUPPRESS_MOBILE_CAPS": FILES_READ_CAPABILITY})
        self.device_connected_without_files_read()
        created = self.sock.call("workspace.create", {"title": f"files-old-{self.nonce}", "cwd": str(self.root), "focus": False}) or {}
        source = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not source:
            raise Failure(f"workspace.create returned no id: {created}")
        self.created.append(source)
        self.mirror_id = up(wait_for("the new source's auto-mirror", lambda: self.mirror_of(source), self.timeout))

        def hinted() -> Dict[str, Any]:
            state = self.state()
            resolved = state.get("resolved") or {}
            detail = str(resolved.get("detail") or "")
            if resolved.get("kind") != "remote" or resolved.get("is_available") or "Update Supermux" not in detail or DEVICE_NAME not in detail:
                raise Failure(f"older host: {brief(state)}")
            if state.get("rows"):
                raise Failure(f"older host listed rows: {brief(state)}")
            return state

        state = wait_for("the panel to ask to update Supermux on the Mac", hinted, self.timeout)
        return {"status_message": state.get("status_message"), "resolved": state.get("resolved")}

    def device_connected_without_files_read(self) -> None:
        def ready() -> Dict[str, Any]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')}")
            return device

        self.machine = wait_for("the loopback device to reconnect", ready, self.timeout)["machine"]
        capabilities = self.device(include_capabilities=True).get("capabilities") or []
        if FILES_READ_CAPABILITY in capabilities:
            raise Failure(f"the suppressed host still advertises {FILES_READ_CAPABILITY}")

    # -- relaunch ---------------------------------------------------------------

    def relaunch(self, extra_env: Dict[str, str]) -> None:
        app = self.args.app_path
        bundle_id = plistlib.loads((Path(app) / "Contents" / "Info.plist").read_bytes())["CFBundleIdentifier"]
        self.files("unmount")
        self.sock.close()
        subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to quit'], check=False, capture_output=True)
        wait_for("the app to quit", lambda: not self.app_running(bundle_id), 60, interval_s=0.5)
        env = {"SUPERMUX_DEBUG_LOOPBACK_DEVICE": "1", **extra_env}
        if self.args.projects_file:
            env["SUPERMUX_PROJECTS_FILE"] = self.args.projects_file
        if self.args.push_state_dir:
            env["SUPERMUX_PHONE_PUSH_STATE_DIR"] = self.args.push_state_dir
        env_args = [arg for key, value in env.items() for arg in ("--env", f"{key}={value}")]
        subprocess.run(["open", "-g", *env_args, app], check=True)
        wait_for("the relaunched app's socket", self.socket_alive, 60)
        self.sock.connect()

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
        if self.mirror_id:
            try:
                self.files("unmount")
            except (Failure, OSError):
                pass
        for workspace_id in self.created:
            try:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except (Failure, OSError) as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        # Every step runs; one that needs an earlier step's result is skipped
        # (`require`) instead of failing again for the same reason.
        for name, action in [
            ("device_connected", self.device_connected),
            ("scratch_tree", self.scratch_tree),
            ("source_and_mirror", self.source_and_mirror),
            ("files_panel_lists_remote_root", self.files_panel_lists_remote_root),
            ("expand_folder", self.expand_folder),
            ("symlink_escape_not_browsable", self.symlink_escape_not_browsable),
            ("git_decorations_match_local", self.git_decorations_match_local),
            ("open_file_preview", self.open_file_preview),
            ("large_file_capped", self.large_file_capped),
            ("search_finds_remote_match", self.search_finds_remote_match),
            ("confinement_probes", self.confinement_probes),
            ("named_pipe_read_refused", self.named_pipe_read_refused),
            ("root_follows_remote_cd", self.root_follows_remote_cd),
            ("live_refresh", self.live_refresh),
            ("file_operations_on_the_other_mac", self.file_operations_on_the_other_mac),
            ("file_op_error_with_panel_hidden", self.file_op_error_with_panel_hidden),
            ("link_drop_is_honest", self.link_drop_is_honest),
            ("older_host_fallback", self.older_host_fallback),
        ]:
            self.step(name, action)
        self.cleanup()
        return all(step.get("ok") is not False for step in self.steps)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    parser.add_argument("--scratch", help="scratch directory for the test folder (a nonce subfolder is made)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per wait")
    parser.add_argument("--refresh-timeout", type=float, default=6.0, help="seconds a new file may take to appear")
    parser.add_argument("--app-path", help="the tagged .app to relaunch for the older-host check")
    parser.add_argument("--projects-file", help="SUPERMUX_PROJECTS_FILE for the relaunch (a scratch projects file)")
    parser.add_argument("--push-state-dir", help="SUPERMUX_PHONE_PUSH_STATE_DIR for the relaunch")
    parser.add_argument("--keep", action="store_true", help="leave the test workspaces open")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    artifact = ARTIFACTS_DIR / f"{SUITE}-{args.tag or 'socket'}.json"
    args.report_path = args.report or str(artifact)
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = MirrorFilesE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-mirror-files-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    text = json.dumps(report, indent=2) + "\n"
    for report_path in {Path(args.report_path), artifact}:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(text, encoding="utf-8")
    print(text)
    print(f"report: {args.report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
