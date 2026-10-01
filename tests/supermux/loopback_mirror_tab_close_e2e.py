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
`supermux.devices.terminal_close.answer`, so no modal shows except in step 6,
which shows the real prompt and lets it answer Cancel by itself:

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
  6. shown_prompt_keeps_app_responsive  the real prompt for busy T2 (Cancel pressed after
                                        a few seconds) -> the app answers other requests at
                                        once while it is up, then T2 is projected again
  7. reopened_pane_attaches             T0 projected into another workspace, closed and
                                        projected again (same link) -> the new pane attaches
  8. first_pane_replays_beside_another  T0 in a second, split pane (same link), then the
                                        mirror's T0 pane replays -> it attaches again and
                                        does not take the size back; the second pane
                                        closes, the mirror's pane replays -> attaches again
  8b. pane_opened_off_screen_keeps_counting
                                        the mirror's T0 pane on screen, T0 projected into a
                                        background workspace X (B1, off screen) -> this Mac
                                        still counts for T0 (the hidden pane never makes the
                                        other Mac drop it)
  8c. speaker_hidden_beside_shown_pane  in X, B2 (a tab beside X's own terminal) speaks and
                                        B1 is on screen; B2's tab is switched away -> this
                                        Mac still counts (B1 speaks now)
  8d. shown_pane_lifts_counts_another_pane_left
                                        nothing of T0 on screen -> this Mac stops counting;
                                        the mirror's pane comes back on screen -> it counts
                                        again, although another pane set the "not counting"
  8e. speaker_closes_beside_another     B1 speaks and closes while the mirror's pane and B2
                                        stay -> this Mac never leaves T0's participants
  9. kill_terminal_forces               vm.terminal_close on busy T3 (Kill Terminal…) ->
                                        closed there, no prompt
 10. idle_tab_close_control             close idle T0's mirror tab -> closed there, no prompt
 11. offline_close                      link down, close idle T4's mirror tab -> gone at
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
        self.home_id = ""
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

    def replay_pane(self, workspace_id: str, panel: str) -> None:
        self.sock.call("supermux.devices.terminal_close.replay", {"workspace_id": workspace_id, "panel_id": panel})

    def mac_viewport(self, terminal: str) -> Any:
        """The viewport the owning Mac holds for this Mac's link on `terminal`, or None."""
        state = (self.sock.call("terminal.size_state", {"surface_id": terminal}) or {}).get("size_state") or {}
        for row in state.get("participants") or []:
            participant = row.get("participant") if isinstance(row.get("participant"), dict) else row
            if str(participant.get("id", "")).startswith("mobile:mac-"):
                return participant.get("viewport")
        return None

    def link_row(self, terminal: str) -> Optional[Dict[str, Any]]:
        """This Mac's participant row (its link's client) on `terminal`, as the owning Mac holds it."""
        state = (self.sock.call("terminal.size_state", {"surface_id": terminal}) or {}).get("size_state") or {}
        for row in state.get("participants") or []:
            participant = row.get("participant") if isinstance(row.get("participant"), dict) else row
            if str(participant.get("id", "")).startswith("mobile:mac-"):
                return {"viewport": participant.get("viewport"), "counts_override": participant.get("counts_override"),
                        "counts": row.get("counts")}
        return None

    def not_counting(self, terminal: str) -> Optional[str]:
        """Why this Mac does not count toward `terminal`'s grid, or None when it does."""
        row = self.link_row(terminal)
        if row is None:
            return "this Mac is not a participant of T0"
        if row.get("counts_override") is False or not row.get("counts"):
            return f"this Mac does not count for T0: {row}"
        return None

    def panes_of(self, terminal: str) -> Dict[str, Any]:
        """Every pane of `terminal` here, by workspace (diagnostics)."""
        found = {}
        for workspace_id in (self.mirror_id, self.extra_id):
            if workspace_id:
                found[workspace_id] = [p for p in self.inspect(workspace_id).get("panes") or []
                                       if up(p.get("remote_surface_id")) == up(terminal)]
        return found

    def select(self, workspace_id: str) -> None:
        self.sock.call("workspace.select", {"workspace_id": workspace_id})

    def pane_id_of(self, workspace_id: str, surface: str) -> str:
        for pane in (self.sock.call("pane.list", {"workspace_id": workspace_id}) or {}).get("panes") or []:
            if up(surface) in [up(s) for s in pane.get("surface_ids") or []]:
                return str(pane.get("pane_id") or pane.get("id") or "")
        raise Failure(f"no pane holds {surface} in {workspace_id}")

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

    def shown_prompt_keeps_app_responsive(self) -> Dict[str, Any]:
        """The real prompt is up: other requests (main-actor work) are still answered at once.

        A prompt run as a nested modal session from the close's main-actor task
        stalls the main queue until it is answered, so every request waits.
        """
        self.require_busy("T2")
        self.answer("show")
        old_panel = self.close_mirror_tab("T2")
        slowest = 0.0

        def timed(call: Callable[[], Any]) -> Any:
            nonlocal slowest
            started = time.monotonic()
            value = call()
            slowest = max(slowest, time.monotonic() - started)
            return value

        problems: List[str] = []
        shown = wait_for("the close prompt to show", lambda: timed(self.asked), self.timeout)
        if not all(prompt.get("shown") is True for prompt in shown):
            problems.append(f"the prompt was answered without showing: {shown}")
        deadline = time.monotonic() + 2.5
        while time.monotonic() < deadline:
            timed(lambda: self.surfaces(self.mirror_id))
            timed(self.asked)
            time.sleep(0.1)
        if slowest > 1.0:
            problems.append(f"a request waited {slowest:.1f}s while the prompt was up (expected under 1s)")

        def new_panel() -> Optional[str]:
            panel = self.mirror_panel(self.terms["T2"])
            return panel if panel and panel != old_panel else None

        panel = wait_for("T2 to be projected again after the prompt's Cancel", new_panel, self.timeout)
        if not self.source_has("T2"):
            problems.append("the source lost T2 although the prompt was cancelled")
        problems += self.asked_problems(1)
        if problems:
            raise Failure("; ".join(problems))
        return {"slowest_request_seconds": round(slowest, 2), "new_panel": panel}

    def reopened_pane_attaches(self) -> Dict[str, Any]:
        resource = (self.projections(self.mirror_id).get(up(self.terms["T0"])) or {}).get("resource")
        if not resource:
            raise Failure("precondition: the mirror does not show T0")
        created = self.sock.call("workspace.create", {"title": f"tab-close-extra-{self.nonce}", "focus": False}) or {}
        self.extra_id = up(created.get("workspace_id") or created.get("created_workspace_id"))

        def project() -> str:
            return self.project_into_extra(resource)

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

    def project_into_extra(self, resource: str) -> str:
        opened = self.sock.call("surface.project", {"resource": resource, "workspace_id": self.extra_id,
                                                    "reuse": False, "focus": False}, timeout_s=60) or {}
        return up(opened.get("panel_id") or opened.get("surface_id"))

    def first_pane_replays_beside_another(self) -> Dict[str, Any]:
        """The mirror's T0 pane replays again after another pane of T0 on the same link reported.

        Every pane of one link shares its client id, and the owning Mac fences
        that client's viewport generations. A pane whose replay carried a
        generation below a later pane's report or clear was refused with
        `viewport_transition` until it showed "Mac disconnected". A pane that
        only re-syncs must also not take the size back from the pane that
        reported last, or two panes of different sizes resize the terminal in turn.
        """
        terminal = self.terms["T0"]
        mirror_pane = self.mirror_panel(terminal)
        resource = (self.projections(self.mirror_id).get(up(terminal)) or {}).get("resource")
        if not mirror_pane or not resource:
            raise Failure("precondition: the mirror does not show T0")

        def mirror_attached() -> Any:
            return (self.pane(self.mirror_id, mirror_pane) or {}).get("attached")

        def replays_and_stays_attached(when: str) -> Optional[str]:
            self.replay_pane(self.mirror_id, mirror_pane)
            # A refused replay retries three times (50/100/200 ms) and then detaches.
            time.sleep(1.5)
            if not mirror_attached():
                return f"the mirror's T0 pane did not attach again {when}: {self.pane(self.mirror_id, mirror_pane)}"
            return holds(lambda: None if mirror_attached()
                         else f"the mirror's T0 pane detached {when}: {self.pane(self.mirror_id, mirror_pane)}", 1.5)

        wait_for("the mirror's T0 pane to attach", mirror_attached, self.timeout)
        created = self.sock.call("workspace.create", {"title": f"tab-close-second-{self.nonce}", "focus": False}) or {}
        self.extra_id = up(created.get("workspace_id") or created.get("created_workspace_id"))
        second = self.project_into_extra(resource)
        wait_for("T0's second pane to attach", lambda: (self.pane(self.extra_id, second) or {}).get("attached"),
                 self.timeout)
        size_before_split = self.mac_viewport(terminal)
        try:
            self.sock.call("surface.split_off", {"workspace_id": self.extra_id, "surface_id": second,
                                                 "direction": "right", "focus": False})
        except Failure as error:
            self.facts["second_pane_split_error"] = str(error)
        # The second pane measures its narrower grid and reports it.
        time.sleep(1.0)
        reported = self.mac_viewport(terminal)
        sizes_differ = reported is not None and reported != size_before_split
        self.facts.update(second_pane_viewport=reported, viewport_before_split=size_before_split,
                          second_pane_size_differs=sizes_differ)
        problems: List[str] = []
        problem = replays_and_stays_attached("beside the second pane")
        if problem:
            problems.append(problem)
        if sizes_differ:
            taken = holds(lambda: None if self.mac_viewport(terminal) == reported
                          else f"the mirror's replay took the size back: {self.mac_viewport(terminal)} "
                               f"instead of the second pane's {reported}", 1.0)
            if taken:
                problems.append(taken)
        self.close_extra()
        problem = replays_and_stays_attached("after the second pane closed")
        if problem:
            problems.append(problem)
        if problems:
            raise Failure("; ".join(problems))
        return {"mirror_pane": mirror_pane, "second_pane": second, "second_pane_size_differs": sizes_differ}

    def keeps_counting(self, terminal: str, when: str, seconds: float = 2.0) -> None:
        problem = holds(lambda: self.not_counting(terminal), seconds)
        if problem:
            raise Failure(f"{when}: {problem}; panes {self.panes_of(terminal)}")

    def pane_opened_off_screen_keeps_counting(self) -> Dict[str, Any]:
        """Every pane of one terminal on a link shares its client id, and the owning Mac keeps one
        counts override per client id. A new pane of T0 off screen must not hand the other Mac this
        Mac's automatic `counts_override: false` while another pane of T0 is on screen here."""
        terminal = self.terms["T0"]
        mirror_pane = self.mirror_panel(terminal)
        resource = (self.projections(self.mirror_id).get(up(terminal)) or {}).get("resource")
        if not mirror_pane or not resource:
            raise Failure("precondition: the mirror does not show T0")
        created = self.sock.call("workspace.create", {"title": f"tab-close-home-{self.nonce}", "focus": False}) or {}
        self.home_id = up(created.get("workspace_id") or created.get("created_workspace_id"))
        self.select(self.mirror_id)
        wait_for("the mirror's T0 pane on screen, attached, and this Mac counting for T0",
                 lambda: (self.pane(self.mirror_id, mirror_pane) or {}).get("hidden") is False
                 and (self.pane(self.mirror_id, mirror_pane) or {}).get("attached")
                 and self.not_counting(terminal) is None, self.timeout)
        created = self.sock.call("workspace.create", {"title": f"tab-close-panes-{self.nonce}", "focus": False}) or {}
        self.extra_id = up(created.get("workspace_id") or created.get("created_workspace_id"))
        self.facts["panes_workspace_terminal"] = wait_for("the panes workspace's own terminal",
                                                          lambda: self.surfaces(self.extra_id), self.timeout)[0]
        b1 = self.project_into_extra(resource)
        self.facts["b1"] = b1
        wait_for("B1 to attach", lambda: (self.pane(self.extra_id, b1) or {}).get("attached"), self.timeout)
        self.keeps_counting(terminal, "with B1 opened off screen beside the mirror's pane on screen")
        return {"b1": b1, "panes": self.panes_of(terminal)}

    def speaker_hidden_beside_shown_pane(self) -> Dict[str, Any]:
        """The pane that speaks for this Mac goes off screen while another pane of the same
        terminal stays on screen: that pane speaks now, and this Mac keeps counting."""
        terminal, b1 = self.terms["T0"], self.facts.get("b1")
        own = self.facts.get("panes_workspace_terminal")
        resource = (self.projections(self.mirror_id).get(up(terminal)) or {}).get("resource")
        if not b1 or not own or not resource:
            raise Failure("precondition: B1 and the panes workspace (pane_opened_off_screen_keeps_counting failed)")
        opened = self.sock.call("surface.project", {
            "resource": resource, "workspace_id": self.extra_id, "pane_id": self.pane_id_of(self.extra_id, own),
            "placement": "tab", "reuse": False, "focus": False,
        }, timeout_s=60) or {}
        b2 = up(opened.get("panel_id") or opened.get("surface_id"))
        self.facts["b2"] = b2
        wait_for("B2 to attach", lambda: (self.pane(self.extra_id, b2) or {}).get("attached"), self.timeout)
        self.select(self.extra_id)
        self.sock.call("surface.focus", {"workspace_id": self.extra_id, "surface_id": b2})

        def both_shown_b2_speaks() -> bool:
            one, two = self.pane(self.extra_id, b1) or {}, self.pane(self.extra_id, b2) or {}
            if one.get("hidden") is not False or two.get("hidden") is not False or not two.get("speaks"):
                raise Failure(f"B1 {one}, B2 {two}")
            problem = self.not_counting(terminal)
            if problem:
                raise Failure(problem)
            return True

        wait_for("B1 and B2 on screen, B2 speaking, this Mac counting", both_shown_b2_speaks, self.timeout)
        # Let every pane's view of the size state catch up with the counting it shows.
        time.sleep(0.5)
        self.sock.call("surface.focus", {"workspace_id": self.extra_id, "surface_id": own})
        wait_for("B2 off screen", lambda: (self.pane(self.extra_id, b2) or {}).get("hidden") is True, self.timeout)
        self.keeps_counting(terminal, "with B2 (the speaker) off screen and B1 on screen")
        return {"b2": b2, "panes": self.panes_of(terminal)}

    def shown_pane_lifts_counts_another_pane_left(self) -> Dict[str, Any]:
        """The automatic "not counting" one pane set is this Mac's, not that pane's: a pane of the
        same terminal that comes on screen later lifts it."""
        terminal = self.terms["T0"]
        mirror_pane = self.mirror_panel(terminal)
        if not self.home_id or not self.extra_id or not mirror_pane:
            raise Failure("precondition: the panes workspace (pane_opened_off_screen_keeps_counting failed)")
        self.select(self.home_id)
        stopped = wait_for("this Mac to stop counting for T0 with none of its panes on screen",
                           lambda: (self.link_row(terminal) or {}).get("counts_override") is False, self.timeout)
        self.select(self.mirror_id)
        wait_for("the mirror's T0 pane on screen", lambda: (self.pane(self.mirror_id, mirror_pane) or {}).get("hidden") is False,
                 self.timeout)
        try:
            wait_for("this Mac to count for T0 again", lambda: self.not_counting(terminal) is None, 5.0)
        except Failure as error:
            raise Failure(f"{error}: {self.link_row(terminal)}; panes {self.panes_of(terminal)}")
        self.keeps_counting(terminal, "with the mirror's pane back on screen", 1.5)
        return {"stopped": stopped, "panes": self.panes_of(terminal)}

    def speaker_closes_beside_another(self) -> Dict[str, Any]:
        """The pane that speaks for this Mac closes while other panes of the terminal stay open:
        one of them speaks now. Its clear would drop this Mac from the terminal until some later
        grid change made the others replay (two resizes of the program in between)."""
        terminal, b1 = self.terms["T0"], self.facts.get("b1")
        own = self.facts.get("panes_workspace_terminal")
        if not b1 or not own:
            raise Failure("precondition: B1 (pane_opened_off_screen_keeps_counting failed)")
        self.select(self.extra_id)
        self.sock.call("surface.focus", {"workspace_id": self.extra_id, "surface_id": own})
        wait_for("B1 on screen and speaking, this Mac counting",
                 lambda: (self.pane(self.extra_id, b1) or {}).get("speaks")
                 and (self.pane(self.extra_id, b1) or {}).get("hidden") is False
                 and self.not_counting(terminal) is None, self.timeout)
        self.sock.call("surface.close", {"workspace_id": self.extra_id, "surface_id": b1, "force": True})
        missing: List[float] = []
        started = time.monotonic()
        while time.monotonic() - started < 3.0:
            if self.link_row(terminal) is None:
                missing.append(round(time.monotonic() - started, 2))
            time.sleep(0.05)
        if b1 in self.surfaces(self.extra_id):
            raise Failure("B1 did not close")
        if missing:
            raise Failure(f"this Mac left T0's participants after the speaking pane closed (at {missing[:5]} s); "
                          f"panes {self.panes_of(terminal)}")
        return {"panes": self.panes_of(terminal), "row": self.link_row(terminal)}

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

    def close_panes_workspace(self) -> Dict[str, Any]:
        """The panes workspace closes (its last pane of T0 with it); the mirror's pane stays attached."""
        self.close_extra()
        mirror_pane = self.mirror_panel(self.terms["T0"]) or ""
        wait_for("the mirror's T0 pane to stay attached", lambda: (self.pane(self.mirror_id, mirror_pane) or {}).get("attached"),
                 self.timeout)
        return {}

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
        if self.home_id:
            try:
                self.sock.call("workspace.close", {"workspace_id": self.home_id, "force": True})
            except Failure as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))
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
                ("shown_prompt_keeps_app_responsive", self.shown_prompt_keeps_app_responsive),
                ("reopened_pane_attaches", self.reopened_pane_attaches),
                ("first_pane_replays_beside_another", self.first_pane_replays_beside_another),
                ("pane_opened_off_screen_keeps_counting", self.pane_opened_off_screen_keeps_counting),
                ("speaker_hidden_beside_shown_pane", self.speaker_hidden_beside_shown_pane),
                ("shown_pane_lifts_counts_another_pane_left", self.shown_pane_lifts_counts_another_pane_left),
                ("speaker_closes_beside_another", self.speaker_closes_beside_another),
                ("close_panes_workspace", self.close_panes_workspace),
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
