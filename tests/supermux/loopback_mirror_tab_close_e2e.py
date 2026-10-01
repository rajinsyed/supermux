#!/usr/bin/env python3
"""End-to-end test: closing a device-mirror tab whose terminal is busy.

A mirror tab of a terminal that runs a program (Claude Code, `sleep`, anything)
could not be closed: the owning Mac refused `mobile.terminal.close` without
`force` and reported it as `internal_error`, the viewer showed "Couldn't update
the machine workspace / The Cloud operation failed" and projected the terminal
again, and the new pane then showed "Mac disconnected" because its viewport
generation restarted below the clear the old pane had sent (the host fences
lower generations from the same link until it reconnects). Closing with the link
down showed the same card, and the closed tab came back on reconnect.

This suite drives the real device path against ONE tagged DEBUG build running
the loopback device ("Loopback Mac" = this same app's own mobile host). The
close prompt ("Close “X” on <Mac>?") is pre-answered through
`supermux.devices.terminal_close.answer`, so no modal ever shows:

  1. setup                              auto-mirror on, the loopback linked and fetched
  2. source_with_terminals              a source workspace with T0 idle, T1-T3 busy, T4
                                        idle, every terminal projected in its mirror
  3. host_close_requires_confirmation   mobile.terminal.close on busy T1 without force
                                        -> confirmation_required, T1 still there
  4. busy_tab_close_confirmed           answer Close, close T1's mirror tab -> asked once
                                        naming the Mac, T1 closed there, not projected
                                        again, no failure card
  5. busy_tab_close_cancelled           answer Cancel, close T2's mirror tab -> asked
                                        once, T2 kept and projected again, the new pane
                                        attached and rendering, no overlay, no card
  6. reopened_pane_attaches             T0 projected into another workspace, closed and
                                        projected again (same link) -> the new pane attaches
  7. kill_terminal_forces               vm.terminal_close on busy T3 (Kill Terminal…) ->
                                        closed there, no prompt
  8. idle_tab_close_control             close idle T0's mirror tab -> closed there, no prompt
  9. offline_close                      link down, close idle T4's mirror tab -> gone at
                                        once, no card; on reconnect T4 is closed there and
                                        never projected again

The busy terminals run a stand-in for Claude Code (alternate screen, kitty
keyboard flags, a marker line, a sleeping child); `--claude` runs the real
`claude` CLI instead. Writes a JSON report (default
tests/supermux/artifacts/loopback_mirror_tab_close_e2e-<tag>.json) and exits
non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_tab_close_e2e.py [--claude] [--timeout 30] [--report PATH]
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


class Failure(Exception):
    """A check failed; the message says which and why."""


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


class MirrorTabCloseE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.timeout = args.timeout
        self.close_timeout = args.close_timeout
        self.use_claude = args.claude
        self.keep = args.keep
        self.nonce = uuid.uuid4().hex[:6]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "busy_program": "claude" if self.use_claude else "mimic"}
        self.machine = ""
        self.device_name = ""
        self.source_id = ""
        self.mirror_id = ""
        self.extra_id = ""
        self.link_stopped = False
        self.terms: Dict[str, str] = {}
        self.markers: Dict[str, str] = {}

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

    def projections(self, workspace_id: str) -> Dict[str, Dict[str, str]]:
        """Source terminal id -> {panel, resource} for the device projections in a local workspace."""
        found: Dict[str, Dict[str, str]] = {}
        for projection in (self.sock.call("surface.catalog", {}) or {}).get("projections") or []:
            resource = str(projection.get("resource", ""))
            if up(projection.get("workspace_id")) == up(workspace_id) and resource.startswith(self.machine):
                found[up(resource.rsplit("/", 1)[-1])] = {"panel": up(projection.get("panel_id")), "resource": resource}
        return found

    def mirror_panel(self, terminal: str) -> Optional[str]:
        return (self.projections(self.mirror_id).get(up(terminal)) or {}).get("panel")

    def inspect(self, workspace_id: str) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.terminal_close.inspect", {"workspace_id": workspace_id}) or {}

    def pane(self, workspace_id: str, panel: str) -> Optional[Dict[str, Any]]:
        for pane in self.inspect(workspace_id).get("panes") or []:
            if up(pane.get("panel_id")) == up(panel):
                return pane
        return None

    def failure_card(self) -> Optional[Dict[str, Any]]:
        return self.inspect(self.mirror_id).get("failure_card")

    def answer(self, value: Optional[str] = None) -> Dict[str, Any]:
        params = {"answer": value} if value else {}
        return self.sock.call("supermux.devices.terminal_close.answer", params) or {}

    def asked(self) -> List[Dict[str, Any]]:
        return self.answer().get("asked") or []

    def needs_confirm(self, terminal: str) -> bool:
        result = self.sock.call("supermux.devices.terminal_close.needs_confirm",
                                {"workspace_id": self.source_id, "surface_id": terminal}) or {}
        if not result.get("exists"):
            raise Failure(f"{terminal} is not a terminal of the source")
        return bool(result.get("needs_confirm"))

    def read_text(self, workspace_id: str, surface: str) -> str:
        result = self.sock.call("surface.read_text", {"workspace_id": workspace_id, "surface_id": surface}) or {}
        return str(result.get("text") or "")

    def error_code(self, method: str, params: Dict[str, Any], timeout_s: float = 40) -> str:
        """`ok`, or the error code the app answered with."""
        try:
            self.sock.call(method, params, timeout_s=timeout_s)
            return "ok"
        except SocketError as error:
            return error.code

    # -- terminals ------------------------------------------------------------

    def busy_command(self, name: str) -> str:
        """A Claude Code stand-in: alternate screen, kitty keyboard flags, a marker, a sleeping child.

        The marker is split in the command line, so the shell's echo of it never matches.
        """
        if self.use_claude:
            return "claude\n"
        marker = f"BUSY-{self.nonce}-{name}"
        self.markers[name] = marker
        head, tail = marker[:4], marker[4:]
        return ("python3 -c 'import subprocess,sys; "
                f"sys.stdout.write(\"\\033[?1049h\\033[>1u\" + \"{head}\" + \"{tail}\\n\"); sys.stdout.flush(); "
                "subprocess.call([\"sleep\", \"900\"])'\n")

    def shows_program(self, name: str, text: str) -> bool:
        marker = self.markers.get(name)
        return marker in text if marker else bool(text.strip())

    def require_busy(self, name: str) -> None:
        terminal = self.terms[name]
        if not self.needs_confirm(terminal):
            raise Failure(f"precondition: the source does not consider {name} busy, so a close would just succeed")

    def require_idle(self, name: str) -> None:
        terminal = self.terms[name]
        wait_for(f"{name} to be idle on the source (no close confirmation)", lambda: not self.needs_confirm(terminal), self.timeout)

    def close_mirror_tab(self, name: str) -> str:
        panel = self.mirror_panel(self.terms[name])
        if not panel:
            raise Failure(f"precondition: the mirror does not show {name}")
        self.sock.call("surface.close", {"workspace_id": self.mirror_id, "surface_id": panel, "force": True})
        return panel

    def source_has(self, name: str) -> bool:
        return up(self.terms[name]) in self.surfaces(self.source_id)

    def asked_problems(self, expected: int) -> List[str]:
        asked = self.asked()
        self.facts.setdefault("asked", []).append(asked)
        if len(asked) != expected:
            return [f"the close prompt was asked {len(asked)} times, expected {expected}: {asked}"]
        problems = []
        for prompt in asked:
            if prompt.get("device") != self.device_name or self.device_name not in str(prompt.get("title", "")):
                problems.append(f"the prompt does not name {self.device_name!r}: {prompt}")
        return problems

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
        state = self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True}) or {}
        self.answer("clear")

        def ready() -> Optional[Dict[str, Any]]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        device = wait_for("the loopback device to connect", ready, self.timeout)
        self.machine, self.device_name = device["machine"], device.get("name") or ""
        self.facts.update(machine=self.machine, device_name=self.device_name)
        return {"machine": self.machine, "device_name": self.device_name, "auto_mirror": state.get("auto_mirror")}

    def source_with_terminals(self) -> Dict[str, Any]:
        title = f"tab-close-{self.nonce}"
        created = self.sock.call("workspace.create", {"title": title, "focus": False}) or {}
        self.source_id = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not self.source_id:
            raise Failure(f"workspace.create returned no id: {created}")
        self.sock.call("workspace.rename", {"workspace_id": self.source_id, "title": title})
        self.mirror_id = up(wait_for("the auto-mirror of the source", lambda: (self.mirrors_of_source() or [None])[0],
                                     self.timeout)["workspace_id"])
        self.terms["T0"] = wait_for("the source's first terminal", lambda: self.surfaces(self.source_id), self.timeout)[0]
        for name in ("T1", "T2", "T3", "T4"):
            created = self.sock.call("surface.create", {"workspace_id": self.source_id, "type": "terminal"}) or {}
            self.terms[name] = up(created.get("surface_id"))
            if not self.terms[name]:
                raise Failure(f"surface.create returned no surface_id: {created}")
        for name in ("T1", "T2", "T3"):
            terminal = self.terms[name]
            wait_for(f"{name}'s shell", lambda t=terminal: self.read_text(self.source_id, t).strip(), self.timeout)
            self.sock.call("surface.send_text", {"workspace_id": self.source_id, "surface_id": terminal,
                                                 "text": self.busy_command(name)})
        for name in ("T1", "T2", "T3"):
            terminal = self.terms[name]
            wait_for(f"{name}'s program on the source",
                     lambda n=name, t=terminal: self.shows_program(n, self.read_text(self.source_id, t)), self.timeout)
            wait_for(f"the source to consider {name} busy", lambda t=terminal: self.needs_confirm(t), self.timeout)
        wait_for("the mirror to project every terminal",
                 lambda: set(self.terms.values()) <= set(self.projections(self.mirror_id)), self.timeout)
        self.facts.update(source_workspace_id=self.source_id, mirror_workspace_id=self.mirror_id, terminals=self.terms)
        return {"source": self.source_id, "mirror": self.mirror_id, "terminals": self.terms}

    def host_close_requires_confirmation(self) -> Dict[str, Any]:
        self.require_busy("T1")
        code = self.error_code("supermux.devices.request", {
            "machine": self.machine, "method": "mobile.terminal.close",
            "params": {"workspace_id": self.source_id, "surface_id": self.terms["T1"]}, "timeout_seconds": 30,
        })
        if not self.source_has("T1"):
            raise Failure(f"the host closed busy T1 without force (answer: {code})")
        if code != "confirmation_required":
            raise Failure(f"mobile.terminal.close on busy T1 without force answered {code}, expected confirmation_required")
        return {"code": code}

    def busy_tab_close_confirmed(self) -> Dict[str, Any]:
        self.require_busy("T1")
        self.answer("close")
        panel = self.close_mirror_tab("T1")
        problems: List[str] = []
        try:
            wait_for("T1 to close on the source", lambda: not self.source_has("T1"), self.close_timeout)
        except Failure as error:
            problems.append(str(error))
        reprojected = holds(lambda: "T1 was projected in the mirror again"
                            if up(self.terms["T1"]) in self.projections(self.mirror_id) else None, 3.0)
        if reprojected:
            problems.append(reprojected)
        problems += self.asked_problems(1)
        card = self.failure_card()
        if card:
            problems.append(f"a failure card is shown: {card}")
        if problems:
            raise Failure("; ".join(problems))
        return {"closed_panel": panel}

    def busy_tab_close_cancelled(self) -> Dict[str, Any]:
        self.require_busy("T2")
        self.answer("cancel")
        old_panel = self.close_mirror_tab("T2")
        problems: List[str] = []

        def new_panel() -> Optional[str]:
            panel = self.mirror_panel(self.terms["T2"])
            return panel if panel and panel != old_panel else None

        panel = wait_for("T2 to be projected in the mirror again", new_panel, self.timeout)
        if not self.source_has("T2"):
            problems.append("the source lost T2 although the prompt was cancelled")
        problems += self.asked_problems(1)
        try:
            wait_for("the new T2 pane to attach", lambda: (self.pane(self.mirror_id, panel) or {}).get("attached"), 5.0)
        except Failure as error:
            problems.append(f"{error}: {self.pane(self.mirror_id, panel)}")
        try:
            wait_for("the new T2 pane to show the program",
                     lambda: self.shows_program("T2", self.read_text(self.mirror_id, panel)), 5.0)
        except Failure as error:
            problems.append(str(error))
        pane = self.pane(self.mirror_id, panel) or {}
        if pane.get("overlay_title"):
            problems.append(f"the new T2 pane shows {pane.get('overlay_title')!r}")
        card = self.failure_card()
        if card:
            problems.append(f"a failure card is shown: {card}")
        if problems:
            raise Failure("; ".join(problems))
        return {"old_panel": old_panel, "new_panel": panel}

    def reopened_pane_attaches(self) -> Dict[str, Any]:
        resource = (self.projections(self.mirror_id).get(up(self.terms["T0"])) or {}).get("resource")
        if not resource:
            raise Failure("precondition: the mirror does not show T0")
        created = self.sock.call("workspace.create", {"title": f"tab-close-extra-{self.nonce}", "focus": False}) or {}
        self.extra_id = up(created.get("workspace_id") or created.get("created_workspace_id"))

        def project() -> str:
            opened = self.sock.call("surface.project", {"resource": resource, "workspace_id": self.extra_id,
                                                        "reuse": False, "focus": False}, timeout_s=60) or {}
            return up(opened.get("panel_id") or opened.get("surface_id"))

        def attached(panel: str) -> Callable[[], Any]:
            return lambda: (self.pane(self.extra_id, panel) or {}).get("attached")

        first = project()
        wait_for("T0's second pane to attach", attached(first), self.timeout)
        self.sock.call("surface.close", {"workspace_id": self.extra_id, "surface_id": first, "force": True})
        wait_for("T0's second pane to close", lambda: first not in self.surfaces(self.extra_id), self.timeout)
        second = project()
        try:
            wait_for("T0's reopened pane to attach", attached(second), 5.0)
        except Failure as error:
            raise Failure(f"{error}: {self.pane(self.extra_id, second)}")
        mirror_pane = self.pane(self.mirror_id, self.mirror_panel(self.terms["T0"]) or "") or {}
        if not mirror_pane.get("attached"):
            raise Failure(f"the mirror's T0 pane is no longer attached: {mirror_pane}")
        self.close_extra()
        return {"first_panel": first, "reopened_panel": second}

    def kill_terminal_forces(self) -> Dict[str, Any]:
        self.require_busy("T3")
        self.answer("cancel")
        code = self.error_code("vm.terminal_close", {"id": self.machine, "terminal_id": self.terms["T3"]}, timeout_s=130)
        problems: List[str] = []
        if code != "ok":
            problems.append(f"vm.terminal_close on busy T3 answered {code}")
        try:
            wait_for("T3 to close on the source", lambda: not self.source_has("T3"), self.close_timeout)
        except Failure as error:
            problems.append(str(error))
        problems += self.asked_problems(0)
        if problems:
            raise Failure("; ".join(problems))
        return {"code": code}

    def idle_tab_close_control(self) -> Dict[str, Any]:
        self.require_idle("T0")
        self.answer("cancel")
        self.close_mirror_tab("T0")
        problems: List[str] = []
        try:
            wait_for("T0 to close on the source", lambda: not self.source_has("T0"), self.close_timeout)
        except Failure as error:
            problems.append(str(error))
        problems += self.asked_problems(0)
        if problems:
            raise Failure("; ".join(problems))
        return {}

    def offline_close(self) -> Dict[str, Any]:
        self.require_idle("T4")
        self.answer("cancel")
        panel = self.mirror_panel(self.terms["T4"])
        if not panel:
            raise Failure("precondition: the mirror does not show T4")
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        self.link_stopped = True
        wait_for("the loopback link to drop", lambda: self.device().get("link_state") != "connected", self.timeout)
        self.sock.call("surface.close", {"workspace_id": self.mirror_id, "surface_id": panel, "force": True})
        problems: List[str] = []
        try:
            wait_for("T4's mirror tab to close", lambda: panel not in self.surfaces(self.mirror_id), 3.0)
        except Failure as error:
            problems.append(str(error))
        def no_card() -> Optional[str]:
            card = self.failure_card()
            return f"a failure card is shown while offline: {card}" if card else None

        shown = holds(no_card, 2.0)
        if shown:
            problems.append(shown)
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        self.link_stopped = False
        wait_for("the loopback link to reconnect", lambda: self.device().get("link_state") == "connected", self.timeout)
        try:
            wait_for("T4 to close on the source after the reconnect", lambda: not self.source_has("T4"), 10.0)
        except Failure as error:
            problems.append(str(error))
        back = holds(lambda: "T4 came back in the mirror after the reconnect"
                     if up(self.terms["T4"]) in self.projections(self.mirror_id) else None, 5.0)
        if back:
            problems.append(back)
        problems += self.asked_problems(0)
        if problems:
            raise Failure("; ".join(problems))
        return {"closed_panel": panel}

    # -- run ------------------------------------------------------------------

    def close_extra(self) -> None:
        if self.extra_id:
            try:
                self.sock.call("workspace.close", {"workspace_id": self.extra_id, "force": True})
            except Failure as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))
            self.extra_id = ""

    def cleanup(self) -> None:
        try:
            self.answer("clear")
            if self.link_stopped and self.machine:
                self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        except Failure as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))
        if self.keep:
            return
        self.close_extra()
        # The source first, so the mirror closes by itself instead of being hidden.
        for workspace_id in (self.source_id, self.mirror_id):
            if not workspace_id:
                continue
            if workspace_id == self.mirror_id:
                try:
                    wait_for("the mirror to close with its source", lambda: not self.mirrors_of_source(), 10.0)
                    continue
                except Failure:
                    pass
            try:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except Failure as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        ok = self.step("setup", self.setup) and self.step("source_with_terminals", self.source_with_terminals)
        if ok:
            for name, check in [
                ("host_close_requires_confirmation", self.host_close_requires_confirmation),
                ("busy_tab_close_confirmed", self.busy_tab_close_confirmed),
                ("busy_tab_close_cancelled", self.busy_tab_close_cancelled),
                ("reopened_pane_attaches", self.reopened_pane_attaches),
                ("kill_terminal_forces", self.kill_terminal_forces),
                ("idle_tab_close_control", self.idle_tab_close_control),
                ("offline_close", self.offline_close),
            ]:
                ok = self.step(name, check) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait before a setup check gives up")
    parser.add_argument("--close-timeout", type=float, default=5.0, help="max seconds for a close to reach the owning Mac")
    parser.add_argument("--claude", action="store_true", help="run the real `claude` CLI in the busy terminals")
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
        test = MirrorTabCloseE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-mirror-tab-close-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_mirror_tab_close_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
