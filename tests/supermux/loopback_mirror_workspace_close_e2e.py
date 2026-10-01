#!/usr/bin/env python3
"""End-to-end test: closing a device-mirror workspace closes it on its Mac, like a local one.

A user close of a mirror (sidebar ×, context menu Close, ⌘⇧W, a multi-close)
used to show the fork's own "Close “X”?" prompt (Close on <Mac> / Hide Here /
Cancel) before anything else. The user wants it to close the way a local
workspace closes: this Mac's own confirmations only (pinned, running process,
settings, the batch "Close workspaces?"), then the mirror closes here at once
and the workspace closes on its Mac (`workspace.close` with `force`). A close
made while that Mac is offline is kept and sent once the Mac is back, even
after a relaunch; auto-mirror never shows that workspace again meanwhile.

This suite drives the real device path against ONE tagged DEBUG build running
the loopback device ("Loopback Mac" = this same app's own mobile host), so every
local workspace is also a remote workspace with its own mirror. Closes go
through the DEBUG `supermux.devices.user_close` driver, which runs upstream's
user close (`closeWorkspaceWithConfirmation` / `closeWorkspacesWithConfirmation`)
with every confirmation pre-answered and logged, so no modal shows:

  1. setup                                    auto-mirror on, the loopback linked and fetched
  W1. idle_mirror_close_closes_on_mac          close an idle mirror -> no prompt at all; the
                                               mirror goes, its workspace closes on the Mac, it
                                               is not hidden and nothing reopens
  W2. busy_mirror_close_forces                 the source runs a program (Claude stand-in); close
                                               its mirror -> no fork prompt, the source closes
  W3. batch_close_mixed                        Close on two mirrors and a local workspace -> at
                                               most upstream's "Close workspaces?", all three go,
                                               both sources close on the Mac
  W4. pinned_mirror_uses_pinned_prompt         a pinned source's mirror: Cancel in "Close pinned
                                               workspace?" keeps both; Close closes both (the
                                               other Mac unpins it to close it)
  W5. offline_mirror_close_lands_on_reconnect  link down, close a mirror -> gone at once, no
                                               prompt, the source stays and the close is pending;
                                               on reconnect the source closes, nothing reopens
  W6. phone_wire_contract                      (guard) workspace.close on a busy workspace answers
                                               confirmation_required without force, closes with it
  W7. offline_close_survives_relaunch          (with --app-path) link down, close a mirror, quit
                                               and relaunch -> the source closes once the loopback
                                               is back, the mirror never reopens

The busy terminal runs a stand-in for Claude Code (alternate screen, kitty
keyboard flags, a marker line, a sleeping child). Writes a JSON report (default
tests/supermux/artifacts/loopback_mirror_workspace_close_e2e-<tag>.json) and
exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_workspace_close_e2e.py \
      [--app-path "<App path printed by reload.sh>" --projects-file /tmp/<tag>/projects.json] \
      [--timeout 30] [--close-timeout 10] [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import socket
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

LOOPBACK_DEVICE_ID = "5e1f10b0-0000-4000-8000-000000000001"
REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = REPO_ROOT / "tests" / "supermux" / "artifacts"


class Failure(Exception):
    """A check failed; the message says which and why."""


class Skipped(Exception):
    """The step needs an argument this run did not get."""


class RateLimited(Exception):
    """The socket's polling limiter refused a read; retry after the hint."""

    def __init__(self, retry_after_s: float) -> None:
        super().__init__(f"rate limited for {retry_after_s}s")
        self.retry_after_s = max(0.05, retry_after_s)


class SocketError(Failure):
    """The app answered a request with an error; `code` is its error code."""

    def __init__(self, method: str, code: str, message: str) -> None:
        super().__init__(f"{method}: {code}: {message}")
        self.code = code


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
        """One request; waits out the socket's per-connection polling limit."""
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
        raise SocketError(method, str(error.get("code", "error")), str(error.get("message", "unknown error")))

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


def wait_for(description: str, probe: Callable[[], Any], timeout_s: float, interval_s: float = 0.25) -> Any:
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


def holds(probe: Callable[[], Optional[str]], seconds: float, interval_s: float = 0.25) -> Optional[str]:
    """Samples `probe` for `seconds`; returns the first problem it reports, else None."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        problem = probe()
        if problem:
            return problem
        time.sleep(interval_s)
    return None


class MirrorWorkspaceCloseE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.close_timeout = args.close_timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.machine = ""
        self.created: List[str] = []
        self.link_stopped = False

    # -- reads ----------------------------------------------------------------

    def device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device in supermux.devices.list (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def bindings(self) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.bindings", {}) or {}

    def mirrors_of(self, source: str) -> List[Dict[str, Any]]:
        rows = self.bindings().get("mirrors") or []
        return [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(source)]

    def local_ids(self) -> set:
        return {up(w.get("workspace_id")) for w in self.bindings().get("local_workspaces") or []}

    def is_open(self, workspace_id: str) -> bool:
        return up(workspace_id) in self.local_ids()

    def hidden_state(self) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.hidden", {}) or {}

    def hidden(self) -> set:
        return {up(h.get("remote_workspace_id")) for h in self.hidden_state().get("hidden") or []}

    def pending(self) -> set:
        """Remote workspaces whose close waits for their Mac (empty before the fix: no such state)."""
        return {up(h.get("remote_workspace_id")) for h in self.hidden_state().get("pending_remote_closes") or []}

    def surfaces(self, workspace_id: str) -> List[str]:
        panes = (self.sock.call("pane.list", {"workspace_id": workspace_id}) or {}).get("panes") or []
        return [up(surface) for pane in panes for surface in pane.get("surface_ids") or []]

    def read_text(self, workspace_id: str, surface: str) -> str:
        result = self.sock.call("surface.read_text", {"workspace_id": workspace_id, "surface_id": surface}) or {}
        return str(result.get("text") or "")

    def needs_confirm(self, workspace_id: str, terminal: str) -> bool:
        result = self.sock.call("supermux.devices.terminal_close.needs_confirm",
                                {"workspace_id": workspace_id, "surface_id": terminal}) or {}
        return bool(result.get("needs_confirm"))

    def error_code(self, method: str, params: Dict[str, Any], timeout_s: float = 40) -> str:
        """`ok`, or the error code the app answered with."""
        try:
            self.sock.call(method, params, timeout_s=timeout_s)
            return "ok"
        except SocketError as error:
            return error.code

    # -- actions --------------------------------------------------------------

    def create_workspace(self, label: str, window_id: Optional[str] = None) -> str:
        title = f"ws-close-{label}-{self.nonce}"
        params: Dict[str, Any] = {"title": title, "focus": False}
        if window_id:
            params["window_id"] = window_id
        created = self.sock.call("workspace.create", params) or {}
        workspace_id = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not workspace_id:
            raise Failure(f"workspace.create returned no id: {created}")
        self.sock.call("workspace.rename", {"workspace_id": workspace_id, "title": title})
        self.created.append(workspace_id)
        return workspace_id

    def source_and_mirror(self, label: str) -> Dict[str, str]:
        """A new source workspace and its auto-mirror: {source, mirror, window}."""
        source = self.create_workspace(label)
        mirror = wait_for(f"the auto-mirror of {label}", lambda: (self.mirrors_of(source) or [None])[0], self.timeout)
        return {"source": source, "mirror": up(mirror["workspace_id"]), "window": str(mirror.get("window_id") or "")}

    def make_busy(self, source: str) -> str:
        """Runs a Claude Code stand-in in the source's terminal; returns that terminal."""
        terminal = wait_for("the source's terminal", lambda: self.surfaces(source), self.timeout)[0]
        wait_for("the source's shell", lambda: self.read_text(source, terminal).strip(), self.timeout)
        marker = f"BUSY-{self.nonce}"
        command = ("python3 -c 'import subprocess,sys; "
                   f"sys.stdout.write(\"\\033[?1049h\\033[>1u\" + \"{marker[:4]}\" + \"{marker[4:]}\\n\"); sys.stdout.flush(); "
                   "subprocess.call([\"sleep\", \"900\"])'\n")
        self.sock.call("surface.send_text", {"workspace_id": source, "surface_id": terminal, "text": command})
        wait_for("the source to consider its terminal busy", lambda: self.needs_confirm(source, terminal), self.timeout)
        return terminal

    def user_close(self, workspace_ids: List[str], answer: str = "close") -> Dict[str, Any]:
        params: Dict[str, Any] = {"answer": answer}
        if len(workspace_ids) == 1:
            params["workspace_id"] = workspace_ids[0]
        else:
            params["workspace_ids"] = workspace_ids
        result = self.sock.call("supermux.devices.user_close", params) or {}
        self.facts.setdefault("user_closes", []).append({"ids": workspace_ids, "answer": answer, **result})
        return result

    @staticmethod
    def prompts(result: Dict[str, Any], kind: str) -> List[str]:
        return [str(p.get("title")) for p in result.get("prompts") or [] if p.get("kind") == kind]

    def stop_link(self) -> None:
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        self.link_stopped = True
        wait_for("the loopback link to drop", lambda: self.device().get("link_state") != "connected", self.timeout)

    def restore_link(self) -> None:
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        self.link_stopped = False
        self.wait_linked()

    def wait_linked(self) -> Dict[str, Any]:
        def ready() -> Optional[Dict[str, Any]]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        return wait_for("the loopback device to connect", ready, self.timeout)

    # -- shared checks --------------------------------------------------------

    def closed_here_problems(self, result: Dict[str, Any], mirrors: List[str]) -> List[str]:
        problems = []
        mirror_prompts = self.prompts(result, "mirror")
        if mirror_prompts:
            problems.append(f"the fork's own close prompt was asked: {mirror_prompts}")
        open_mirrors = [m for m in mirrors if self.is_open(m)]
        if open_mirrors:
            problems.append(f"the mirror(s) {open_mirrors} are still open here")
        return problems

    def closed_on_mac_problems(self, source: str, within: float) -> List[str]:
        """The source closes on the Mac, is not hidden, and no mirror of it comes back."""
        problems = []
        try:
            wait_for(f"{source} to close on its Mac", lambda: not self.is_open(source), within)
        except Failure as error:
            return [str(error)]
        back = holds(lambda: f"a mirror of {source} came back" if self.mirrors_of(source) else None, 3.0)
        if back:
            problems.append(back)
        if up(source) in self.hidden():
            problems.append(f"{source} was added to the Hide Here set")
        return problems

    # -- steps ----------------------------------------------------------------

    def step(self, name: str, action: Callable[[], Optional[Dict[str, Any]]]) -> bool:
        started = time.monotonic()
        record: Dict[str, Any] = {"name": name}
        try:
            record.update(action() or {})
            record["ok"] = True
        except Skipped as skipped:
            record["ok"] = True
            record["skipped"] = True
            record["reason"] = str(skipped)
        except Failure as error:
            record["ok"] = False
            record["error"] = str(error)
        record["seconds"] = round(time.monotonic() - started, 2)
        self.steps.append(record)
        status = "SKIP" if record.get("skipped") else ("PASS" if record["ok"] else "FAIL")
        print(f"{status} {name} ({record['seconds']}s)" + ("" if record["ok"] else ": " + record["error"]), file=sys.stderr)
        return record["ok"]

    def setup(self) -> Dict[str, Any]:
        state = self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True}) or {}
        device = self.wait_linked()
        self.machine = device["machine"]
        self.facts.update(machine=self.machine, device_name=device.get("name"))
        return {"machine": self.machine, "auto_mirror": state.get("auto_mirror")}

    def idle_mirror_close_closes_on_mac(self) -> Dict[str, Any]:
        pair = self.source_and_mirror("idle")
        result = self.user_close([pair["mirror"]])
        problems = self.closed_here_problems(result, [pair["mirror"]])
        upstream = self.prompts(result, "upstream")
        if upstream:
            problems.append(f"an idle mirror asked {upstream}; an idle local workspace closes without a prompt")
        if not problems:
            problems += self.closed_on_mac_problems(pair["source"], self.close_timeout)
        if problems:
            raise Failure("; ".join(problems))
        return {**pair, "prompts": result.get("prompts")}

    def busy_mirror_close_forces(self) -> Dict[str, Any]:
        pair = self.source_and_mirror("busy")
        terminal = self.make_busy(pair["source"])
        result = self.user_close([pair["mirror"]])
        problems = self.closed_here_problems(result, [pair["mirror"]])
        if not problems:
            problems += self.closed_on_mac_problems(pair["source"], self.close_timeout)
        if problems:
            raise Failure("; ".join(problems))
        return {**pair, "busy_terminal": terminal, "prompts": result.get("prompts")}

    def batch_close_mixed(self) -> Dict[str, Any]:
        first = self.source_and_mirror("batch-a")
        second = self.source_and_mirror("batch-b")
        local = self.create_workspace("batch-local", window_id=first["window"] or None)
        wait_for("the local workspace's terminal", lambda: self.surfaces(local), self.timeout)
        targets = [first["mirror"], second["mirror"], local]
        result = self.user_close(targets)
        problems = self.closed_here_problems(result, targets)
        upstream = self.prompts(result, "upstream")
        if len(upstream) > 1 or any(title != "Close workspaces?" for title in upstream):
            problems.append(f"expected at most upstream's one \"Close workspaces?\", got {upstream}")
        if not problems:
            for source in (first["source"], second["source"]):
                problems += self.closed_on_mac_problems(source, self.close_timeout)
        if problems:
            raise Failure("; ".join(problems))
        return {"targets": targets, "sources": [first["source"], second["source"]], "prompts": result.get("prompts")}

    def pinned_mirror_uses_pinned_prompt(self) -> Dict[str, Any]:
        pair = self.source_and_mirror("pinned")
        self.sock.call("workspace.action", {"workspace_id": pair["source"], "action": "pin"})
        wait_for("the mirror to show the source's pin",
                 lambda: ((self.mirrors_of(pair["source"]) or [{}])[0].get("status") or {}).get("is_pinned") is True,
                 self.timeout)
        problems: List[str] = []
        cancelled = self.user_close([pair["mirror"]], answer="cancel")
        if [p.get("title") for p in cancelled.get("prompts") or []] != ["Close pinned workspace?"]:
            problems.append(f"Cancel: expected only \"Close pinned workspace?\", got {cancelled.get('prompts')}")
        if not self.is_open(pair["mirror"]) or not self.is_open(pair["source"]):
            problems.append("Cancel in the pinned prompt closed the mirror or its source")
        closed = self.user_close([pair["mirror"]])
        if [p.get("title") for p in closed.get("prompts") or []] != ["Close pinned workspace?"]:
            problems.append(f"Close: expected only \"Close pinned workspace?\", got {closed.get('prompts')}")
        problems += self.closed_here_problems(closed, [pair["mirror"]])
        if not problems:
            problems += self.closed_on_mac_problems(pair["source"], self.close_timeout)
        if problems:
            raise Failure("; ".join(problems))
        return {**pair, "cancel_prompts": cancelled.get("prompts"), "close_prompts": closed.get("prompts")}

    def offline_mirror_close_lands_on_reconnect(self) -> Dict[str, Any]:
        pair = self.source_and_mirror("offline")
        problems: List[str] = []
        self.stop_link()
        try:
            result = self.user_close([pair["mirror"]])
            if result.get("prompts"):
                problems.append(f"an offline mirror close asked {result.get('prompts')}")
            problems += self.closed_here_problems(result, [pair["mirror"]])
            if problems:
                raise Failure("; ".join(problems))
            if not self.is_open(pair["source"]):
                problems.append("the source closed while its Mac was offline")
            if up(pair["source"]) not in self.pending():
                problems.append(f"the close is not pending for the reconnect: {self.hidden_state()}")
            back = holds(lambda: "the mirror came back while offline" if self.mirrors_of(pair["source"]) else None, 3.0)
            if back:
                problems.append(back)
        finally:
            self.restore_link()
        try:
            wait_for("the source to close on its Mac after the reconnect", lambda: not self.is_open(pair["source"]), 10.0)
        except Failure as error:
            problems.append(str(error))
        back = holds(lambda: "the mirror came back after the reconnect" if self.mirrors_of(pair["source"]) else None, 5.0)
        if back:
            problems.append(back)
        if up(pair["source"]) in self.hidden():
            problems.append("the offline close was added to the Hide Here set")
        try:
            wait_for("the pending close to be forgotten", lambda: up(pair["source"]) not in self.pending(), self.timeout)
        except Failure as error:
            problems.append(str(error))
        if problems:
            raise Failure("; ".join(problems))
        return pair

    def phone_wire_contract(self) -> Dict[str, Any]:
        """Guard: the host contract the phone's close (now with force) relies on."""
        source = self.create_workspace("wire")
        terminal = self.make_busy(source)
        request = {"machine": self.machine, "method": "workspace.close", "timeout_seconds": 30}
        without = self.error_code("supermux.devices.request", {**request, "params": {"workspace_id": source}})
        problems: List[str] = []
        if without != "confirmation_required":
            problems.append(f"workspace.close without force answered {without}, expected confirmation_required")
        if not self.is_open(source):
            raise Failure("; ".join(problems + ["the busy workspace closed without force"]))
        forced = self.error_code("supermux.devices.request", {**request, "params": {"workspace_id": source, "force": True}})
        if forced != "ok":
            problems.append(f"workspace.close with force answered {forced}")
        try:
            wait_for("the busy workspace to close with force", lambda: not self.is_open(source), self.close_timeout)
        except Failure as error:
            problems.append(str(error))
        if problems:
            raise Failure("; ".join(problems))
        return {"source": source, "busy_terminal": terminal, "without_force": without, "with_force": forced}

    def offline_close_survives_relaunch(self) -> Dict[str, Any]:
        if not self.args.app_path:
            raise Skipped("pass --app-path to quit and relaunch")
        pair = self.source_and_mirror("relaunch")
        self.stop_link()
        try:
            result = self.user_close([pair["mirror"]])
            problems = self.closed_here_problems(result, [pair["mirror"]])
            if result.get("prompts"):
                problems.append(f"an offline mirror close asked {result.get('prompts')}")
            if up(pair["source"]) not in self.pending():
                problems.append(f"the close is not pending: {self.hidden_state()}")
            if problems:
                raise Failure("; ".join(problems))
        except Failure:
            self.restore_link()
            raise
        self.relaunch()
        self.link_stopped = False
        self.wait_linked()
        problems = []
        try:
            wait_for("the source to close on its Mac after the relaunch", lambda: not self.is_open(pair["source"]),
                     self.timeout)
        except Failure as error:
            problems.append(str(error))
        back = holds(lambda: "the mirror came back after the relaunch" if self.mirrors_of(pair["source"]) else None, 5.0)
        if back:
            problems.append(back)
        if up(pair["source"]) in self.pending():
            problems.append("the pending close was never forgotten")
        if problems:
            raise Failure("; ".join(problems))
        return pair

    def relaunch(self) -> None:
        app = self.args.app_path
        bundle_id = plistlib.loads((Path(app) / "Contents" / "Info.plist").read_bytes())["CFBundleIdentifier"]
        self.sock.close()
        subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to quit'], check=False, capture_output=True)

        def quit_done() -> bool:
            result = subprocess.run(["osascript", "-e", f'application id "{bundle_id}" is running'],
                                    check=False, capture_output=True, text=True)
            return result.stdout.strip() != "true"

        wait_for("the app to quit", quit_done, 60, interval_s=0.5)
        env_args = ["--env", "SUPERMUX_DEBUG_LOOPBACK_DEVICE=1"]
        if self.args.projects_file:
            env_args += ["--env", f"SUPERMUX_PROJECTS_FILE={self.args.projects_file}"]
        subprocess.run(["open", "-g", *env_args, app], check=True)

        def socket_alive() -> bool:
            probe = Socket(self.sock.path, timeout_s=3)
            try:
                probe.connect()
                probe.call("supermux.devices.list", {})
                return True
            except (OSError, Failure):
                return False
            finally:
                probe.close()

        wait_for("the relaunched app's socket", socket_alive, 60, interval_s=0.5)
        self.sock.connect()

    # -- run ------------------------------------------------------------------

    def cleanup(self) -> None:
        try:
            if self.link_stopped and self.machine:
                self.restore_link()
        except Failure as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))
        if self.args.keep:
            return
        # Sources first, so their mirrors close by themselves instead of being hidden.
        for workspace_id in self.created:
            try:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except Failure as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))
        for workspace_id in self.created:
            try:
                wait_for("the mirrors to close with their sources", lambda w=workspace_id: not self.mirrors_of(w), 10.0)
            except Failure:
                for mirror in self.mirrors_of(workspace_id):
                    self.sock.call("workspace.close", {"workspace_id": mirror["workspace_id"], "force": True})
                    self.sock.call("supermux.devices.unhide", {"machine": self.machine, "remote_workspace_id": workspace_id})

    def run(self) -> bool:
        ok = self.step("setup", self.setup)
        if ok:
            for name, check in [
                ("idle_mirror_close_closes_on_mac", self.idle_mirror_close_closes_on_mac),
                ("busy_mirror_close_forces", self.busy_mirror_close_forces),
                ("batch_close_mixed", self.batch_close_mixed),
                ("pinned_mirror_uses_pinned_prompt", self.pinned_mirror_uses_pinned_prompt),
                ("offline_mirror_close_lands_on_reconnect", self.offline_mirror_close_lands_on_reconnect),
                ("phone_wire_contract", self.phone_wire_contract),
                ("offline_close_survives_relaunch", self.offline_close_survives_relaunch),
            ]:
                ok = self.step(name, check) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait before a setup check gives up")
    parser.add_argument("--close-timeout", type=float, default=10.0, help="max seconds for a close to reach the owning Mac")
    parser.add_argument("--app-path", help="the tagged .app to quit and relaunch for the relaunch check")
    parser.add_argument("--projects-file", help="SUPERMUX_PROJECTS_FILE to relaunch with")
    parser.add_argument("--keep", action="store_true", help="leave the test workspaces open")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = MirrorWorkspaceCloseE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-mirror-workspace-close-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_mirror_workspace_close_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
