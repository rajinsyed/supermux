#!/usr/bin/env python3
"""End-to-end test: a terminal fills the Mac you look at it from, and the size mode is one
sticky choice for every terminal on this Mac, never for another Mac's.

Before: every terminal started as "Fit everyone" (smallest), held only in memory on the
Mac that runs it, so a phone or a small pane on the other Mac shrank a terminal viewed
full screen; and a mode chosen in the size panel changed one terminal only, until the
next relaunch. Now the default is "Priority" with this Mac first: the Mac pane for a
local terminal, this Mac's mirror for another Mac's terminal. A mirror claims its
terminal when it is shown (or first attaches while shown, or reconnects), pushing once
per connection and never in answer to the other Mac's size events; the claim only moves
this Mac first in a Priority order and never changes another Mac's mode, fixed size or
the rest of its order. A mode, fixed size or priority order chosen in the size panel or
the tab menu applies to every terminal on this Mac, now and later, and survives a
relaunch; of another Mac's terminals it changes only the one it was chosen on.

This suite runs against one tagged DEBUG build with the loopback device ("Loopback Mac"
= this app's own mobile host): a source workspace is the "other Mac" and its auto mirror
is the viewer. The loopback's mirrors get a distinct sizing device id (DEBUG only), so
the two "Macs" have distinct priority keys as two real Macs do. A fake phone and a fake
second Mac report viewports (`mobile.terminal.viewport`) on their own connection, this
control socket, as a real phone or Mac does on its own link: sent over the device link they
would share the mirror's connection, and the host names one client of a connection as its
`self_participant_id`, so the mirror could take the phone for itself. Panel actions are
driven by `supermux.devices.terminal_sizing.*` (DEBUG), which run the panel's own code path.

  1. setup                               auto-mirror on, the loopback linked, the preference reset
  2. source_and_mirror                   a background source workspace and its mirror, shown;
                                         the mirror's priority key differs from the source pane's
  3. default_policy_is_this_mac_first    the source terminal is Priority with the mirror first and
                                         takes the mirror's grid (decided AND real PTY grid)
  4. counting_source_pane_does_not_shrink
                                         the other Mac's own small pane counting does not shrink it
  5. local_terminal_mac_first_over_phone a local terminal keeps its Mac pane's grid while a phone
                                         (40x12) views it
  6. mode_choice_applies_to_every_terminal
                                         Follow Latest chosen on one mirror reaches its terminal and
                                         every terminal of this Mac (both sources and the local one,
                                         all this Mac's own in the loopback)
  7. new_terminals_follow_choice         a new local terminal and a new terminal opened over the
                                         device link start in Follow Latest
  8. second_mac_no_ping_pong             another Mac sets Priority with itself first: the shown
                                         mirror does not push back (3 s hold)
  9. viewing_mac_viewport_up_to_500x200
                                         a viewing Mac's full-screen pane (400x150) is taken as is,
                                         not clamped to a phone's 300x120
 10. reselecting_mode_keeps_claims       picking the mode this Mac already has (Priority, as the
                                         tab menu does to open the panel) on the local terminal
                                         changes no other terminal: the second Mac keeps the
                                         terminal it claimed (3 s hold)
 10b. stored_choice_applies_to_its_terminal
                                         the panel's choice reaches the terminal it was made on
                                         whenever that terminal differs, even when it equals this
                                         Mac's stored preference: the second Mac set Fit everyone,
                                         then Priority (already stored) picked on the mirror takes
                                         it back; the second Mac claimed it, then the stored order
                                         dragged on the mirror takes it back
 10c. showing_keeps_other_macs_mode     the second Mac chose Fit everyone: hiding then showing the
                                         mirror, and a link drop, leave it Fit everyone (3 s holds;
                                         red before: the shown mirror pushed this Mac's Priority)
 11. showing_again_reclaims              hiding then showing the mirror claims the terminal again,
                                         then stays put (3 s hold)
 12. reconnect_reclaims                  after the link drops and the other Mac starts over with its
                                         own default (Priority, its pane first), the reconnected
                                         mirror claims it again
 12b. sticky_choice_stays_on_this_mac    Largest chosen on a local terminal reaches the source as
                                         this Mac's own terminal (its pane's key) and no mirror pushes
                                         it (3 s hold; red before: the shown mirror pushed it, under
                                         its own key, to the terminal it shows)
 13. priority_order_applies_everywhere   a priority order dragged on one mirror ([phone, this Mac])
                                         is stored as [phone, self] and reaches the local terminal as
                                         [phone, its own view on this Mac]: its Mac pane (a hidden
                                         mirror pushes nothing; before the fix, in the loopback, its
                                         own auto-mirror's push landed after the local apply)
 14. choice_survives_relaunch            (--app-path) Largest Window, then quit and relaunch: new
                                         and restored terminals start in Largest Window

Writes a JSON report (default tests/supermux/artifacts/loopback_terminal_sizing_policy_e2e-<tag>.json)
with the policy, keys, owners, grid and live grid per step, and exits non-zero on any failure.
Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_terminal_sizing_policy_e2e.py [--app-path APP] [--timeout 30] [--report PATH]
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
SIZING = "supermux.devices.terminal_sizing."
# The device link's own client id is "mac-<uuid>"; the fake viewers below use "e2e-…".
MIRROR_PREFIX = "mobile:mac-"


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
        self._buffer = b""
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
            except (BrokenPipeError, ConnectionResetError):
                # The app drops a connection that sat idle; dial again once.
                self.close()
                self.connect()
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


def grid_of(value: Any) -> Optional[tuple]:
    if not isinstance(value, dict) or value.get("cols") is None or value.get("rows") is None:
        return None
    return (int(value["cols"]), int(value["rows"]))


class SizingPolicyE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.created: List[str] = []
        self.machine = ""
        # The first source (the "other Mac's" workspace), its mirror, and their terminals.
        self.source_id = ""
        self.mirror_id = ""
        self.source_surface = ""
        self.mirror_surface = ""
        self.mirror_key = ""
        # A local workspace on this Mac and its terminal.
        self.local_id = ""
        self.local_surface = ""
        self.local_key = ""
        self.source2_surface = ""
        self.phone_client = f"e2e-phone-{self.nonce}"
        self.mac_b_client = f"e2e-mac-b-{self.nonce}"
        # Latest viewport generation per fake viewer report: (workspace, surface, client) -> generation.
        self.reports: Dict[tuple, int] = {}

    # -- reads ----------------------------------------------------------------

    def device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device in supermux.devices.list (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def mirrors_of(self, source_id: str) -> List[Dict[str, Any]]:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        return [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(source_id)]

    def surfaces(self, workspace_id: str) -> List[str]:
        panes = (self.sock.call("pane.list", {"workspace_id": workspace_id}) or {}).get("panes") or []
        return [up(surface) for pane in panes for surface in pane.get("surface_ids") or []]

    def mirror_panel_for(self, mirror_id: str, source_surface: str) -> Optional[str]:
        for projection in (self.sock.call("surface.catalog", {}) or {}).get("projections") or []:
            resource = str(projection.get("resource", ""))
            if up(projection.get("workspace_id")) == up(mirror_id) and up(resource.rsplit("/", 1)[-1]) == up(source_surface):
                return up(projection.get("panel_id"))
        return None

    def state(self, surface_id: str) -> Dict[str, Any]:
        payload = self.sock.call("terminal.size_state", {"surface_id": surface_id}) or {}
        state = payload.get("size_state")
        if not isinstance(state, dict):
            raise Failure(f"{surface_id} has no size state: {payload}")
        return state

    @staticmethod
    def rows(state: Dict[str, Any]) -> List[Dict[str, Any]]:
        rows = []
        for row in state.get("participants") or []:
            participant = row.get("participant") if isinstance(row.get("participant"), dict) else row
            rows.append({
                "id": str(participant.get("id")),
                "device_kind": participant.get("device_kind"),
                "priority_key": row.get("priority_key") or participant.get("priority_key"),
                "viewport": participant.get("viewport"),
                "counts_override": participant.get("counts_override"),
                "counts": row.get("counts"),
            })
        return rows

    def row(self, state: Dict[str, Any], prefix: str) -> Optional[Dict[str, Any]]:
        return next((r for r in self.rows(state) if r["id"].startswith(prefix)), None)

    @staticmethod
    def policy(state: Dict[str, Any]) -> Dict[str, Any]:
        policy = state.get("policy") or {}
        return {"mode": policy.get("mode"), "priority": list(policy.get("priority") or []), "fixed": policy.get("fixed")}

    @staticmethod
    def grid(state: Dict[str, Any]) -> Optional[tuple]:
        return grid_of(state)

    def summary(self, state: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "policy": self.policy(state),
            "reason": state.get("reason"),
            "owners": state.get("owners"),
            "grid": list(self.grid(state) or ()),
            "generation": state.get("generation"),
            "participants": self.rows(state),
        }

    def request(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        reply = self.sock.call("supermux.devices.request", {
            "machine": self.machine, "method": method, "params": params, "timeout_seconds": 20,
        }, timeout_s=30) or {}
        return reply.get("result") or {}

    def live_grid(self, workspace_id: str, surface_id: str) -> Optional[tuple]:
        """The PTY grid the terminal really has (a capture over the device, not the decided size)."""
        result = self.request("mobile.terminal.replay", {"workspace_id": workspace_id, "surface_id": surface_id})
        frame = result.get("render_grid") if isinstance(result.get("render_grid"), dict) else result
        if frame.get("columns") is None or frame.get("rows") is None:
            return None
        return (int(frame["columns"]), int(frame["rows"]))

    def report_viewport(self, workspace_id: str, surface_id: str, client_id: str, kind: str,
                        cols: int, rows: int) -> None:
        """A fake viewer (phone or second Mac) reports its viewport on its own connection."""
        key = (workspace_id, surface_id, client_id)
        generation = self.reports.get(key, 0) + 1
        self.sock.call("mobile.terminal.viewport", {
            "workspace_id": workspace_id, "surface_id": surface_id, "client_id": client_id,
            "viewport_columns": cols, "viewport_rows": rows, "viewport_generation": generation,
            "device_kind": kind, "device_id": client_id, "device_name": f"E2E {kind}",
        })
        self.reports[key] = generation

    def clear_reports(self) -> None:
        for (workspace_id, surface_id, client_id), generation in self.reports.items():
            try:
                self.sock.call("mobile.terminal.viewport", {
                    "workspace_id": workspace_id, "surface_id": surface_id, "client_id": client_id,
                    "clear": True, "viewport_generation": generation + 1,
                })
            except Failure as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))
        self.reports.clear()

    # -- panel drivers ----------------------------------------------------------

    def select_mode(self, surface_id: str, mode: str) -> Dict[str, Any]:
        return self.sock.call(SIZING + "select_mode", {"surface_id": surface_id, "mode": mode}) or {}

    def set_priority(self, surface_id: str, keys: List[str]) -> Dict[str, Any]:
        return self.sock.call(SIZING + "set_priority", {"surface_id": surface_id, "keys": keys}) or {}

    def preference(self) -> Any:
        return (self.sock.call(SIZING + "state", {}) or {}).get("preference")

    # -- workspaces -------------------------------------------------------------

    def create_workspace(self, label: str) -> str:
        result = self.sock.call("workspace.create", {"title": f"sizing-{label}-{self.nonce}", "focus": False}) or {}
        workspace_id = up(result.get("workspace_id") or result.get("created_workspace_id"))
        if not workspace_id:
            raise Failure(f"workspace.create returned no id: {result}")
        self.created.append(workspace_id)
        return workspace_id

    def source_with_mirror(self, label: str) -> tuple:
        """A background source workspace, its auto mirror, and both terminals."""
        source = self.create_workspace(label)
        mirror = up(wait_for(f"the auto-mirror of {label}", lambda: (self.mirrors_of(source) or [None])[0],
                             self.timeout)["workspace_id"])
        self.created.insert(0, mirror)
        terminal = wait_for(f"the {label} terminal", lambda: self.surfaces(source), self.timeout)[0]
        panel = wait_for(f"the mirror to project the {label} terminal",
                         lambda: self.mirror_panel_for(mirror, terminal), self.timeout)
        return source, mirror, terminal, panel

    def select(self, workspace_id: str) -> None:
        self.sock.call("workspace.select", {"workspace_id": workspace_id})

    # -- checks -----------------------------------------------------------------

    def wait_state(self, description: str, surface_id: str,
                   check: Callable[[Dict[str, Any]], None]) -> Dict[str, Any]:
        def probe() -> Dict[str, Any]:
            state = self.state(surface_id)
            check(state)
            return self.summary(state)
        return wait_for(description, probe, self.timeout)

    def hold(self, surface_id: str, check: Callable[[Dict[str, Any]], None], seconds: float = 3.0,
             steady: bool = True) -> Dict[str, Any]:
        """The check keeps passing for `seconds`, and (`steady`) the state barely moves (no push-back loop)."""
        generations: List[int] = []
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            state = self.state(surface_id)
            check(state)
            generations.append(int(state.get("generation") or 0))
            time.sleep(0.25)
        delta = (generations[-1] - generations[0]) if generations else 0
        if steady and delta > 2:
            raise Failure(f"the size state kept changing while it should have held: generations {generations}")
        return {"held_seconds": seconds, "generation_delta": delta}

    def has_row(self, prefix: str, what: str) -> Callable[[Dict[str, Any]], None]:
        def check(state: Dict[str, Any]) -> None:
            if not self.row(state, prefix):
                raise Failure(f"{what} is not a participant yet: {self.rows(state)}")
        return check

    def key_of(self, surface_id: str, prefix: str) -> str:
        row = self.row(self.state(surface_id), prefix)
        if not row or not row.get("priority_key"):
            raise Failure(f"no priority key for {prefix}* on {surface_id}")
        return str(row["priority_key"])

    def mirror_counts(self, counts: bool) -> Callable[[Dict[str, Any]], None]:
        def check(state: Dict[str, Any]) -> None:
            mirror = self.row(state, MIRROR_PREFIX)
            if not mirror or bool(mirror.get("counts")) != counts:
                raise Failure(f"the mirror should{'' if counts else ' not'} count: {self.rows(state)}")
        return check

    def other_mac_sets(self, policy: Dict[str, Any]) -> None:
        """The second Mac's explicit choice on the source terminal (its size panel, over its link)."""
        self.request("mobile.terminal.size_policy.set", {
            "workspace_id": self.source_id, "surface_id": self.source_surface, "policy": policy,
        })

    def expect_mode(self, mode: str) -> Callable[[Dict[str, Any]], None]:
        def check(state: Dict[str, Any]) -> None:
            if self.policy(state)["mode"] != mode:
                raise Failure(f"policy is {self.policy(state)}, not {mode}")
        return check

    def expect_first(self, key: str) -> Callable[[Dict[str, Any]], None]:
        def check(state: Dict[str, Any]) -> None:
            policy = self.policy(state)
            if policy["mode"] != "priority" or policy["priority"][:1] != [key]:
                raise Failure(f"policy is {policy}, expected priority with {key} first")
        return check

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

        def ready() -> Optional[Dict[str, Any]]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        self.machine = wait_for("the loopback device to connect", ready, self.timeout)["machine"]
        reset = self.sock.call(SIZING + "reset", {}) or {}
        self.facts.update(machine=self.machine, preference_reset=reset.get("reset"), preference=self.preference())
        return {"machine": self.machine, "auto_mirror": state.get("auto_mirror"), "reset": reset}

    def source_and_mirror(self) -> Dict[str, Any]:
        self.source_id, self.mirror_id, self.source_surface, self.mirror_surface = self.source_with_mirror("source")
        self.select(self.mirror_id)

        def keys(state: Dict[str, Any]) -> None:
            mirror, mac = self.row(state, MIRROR_PREFIX), self.row(state, "mac:")
            if not mirror or not mirror.get("viewport") or not mac:
                raise Failure(f"the mirror and the source pane are not both participants yet: {self.rows(state)}")

        found = self.wait_state("the shown mirror to join the source terminal", self.source_surface, keys)
        self.mirror_key = self.key_of(self.source_surface, MIRROR_PREFIX)
        source_key = self.key_of(self.source_surface, "mac:")
        self.facts.update(source_workspace_id=self.source_id, mirror_workspace_id=self.mirror_id,
                          source_surface=self.source_surface, mirror_surface=self.mirror_surface,
                          mirror_key=self.mirror_key, source_pane_key=source_key)
        if self.mirror_key == source_key:
            raise Failure(f"the loopback mirror and the source pane share the priority key {source_key}")
        return {"mirror_key": self.mirror_key, "source_pane_key": source_key, **found}

    def default_policy_is_this_mac_first(self) -> Dict[str, Any]:
        def check(state: Dict[str, Any]) -> None:
            self.expect_first(self.mirror_key)(state)
            mirror = self.row(state, MIRROR_PREFIX)
            want = grid_of(mirror and mirror.get("viewport"))
            if state.get("reason") != "priority" or state.get("owners") != [mirror and mirror["id"]]:
                raise Failure(f"reason {state.get('reason')} owners {state.get('owners')}, expected the mirror by priority")
            if self.grid(state) != want:
                raise Failure(f"grid {self.grid(state)} != the mirror's {want}")
            live = self.live_grid(self.source_id, self.source_surface)
            if live != want:
                raise Failure(f"the terminal's real grid is {live}, not the mirror's {want}")

        result = self.wait_state("the source terminal to be Priority with this viewer first", self.source_surface, check)
        result["live_grid"] = list(self.live_grid(self.source_id, self.source_surface) or ())
        return result

    def counting_source_pane_does_not_shrink(self) -> Dict[str, Any]:
        state = self.state(self.source_surface)
        mac = self.row(state, "mac:")
        mirror = self.row(state, MIRROR_PREFIX)
        want = grid_of(mirror and mirror.get("viewport"))
        pane = grid_of(mac and mac.get("viewport"))
        self.facts["source_pane_viewport_differs"] = pane != want
        self.sock.call("terminal.size_counts.set", {"surface_id": self.source_surface, "participant_id": mac["id"], "counts": True})
        try:
            def check(state: Dict[str, Any]) -> None:
                if not (self.row(state, "mac:") or {}).get("counts"):
                    raise Failure(f"the source pane does not count yet: {self.rows(state)}")
                if self.grid(state) != want:
                    raise Failure(f"grid {self.grid(state)} != the mirror's {want} (source pane {pane})")

            result = self.wait_state("the source pane to count without shrinking the grid", self.source_surface, check)
            result.update(self.hold(self.source_surface, check, 1.5))
            return {"source_pane_viewport": list(pane or ()), "mirror_viewport": list(want or ()), **result}
        finally:
            # Back to what the visibility rule set for a pane nobody here looks at.
            self.sock.call("terminal.size_counts.set", {"surface_id": self.source_surface, "participant_id": mac["id"], "counts": False})

    def local_terminal_mac_first_over_phone(self) -> Dict[str, Any]:
        self.local_id = self.create_workspace("local")
        self.select(self.local_id)
        self.local_surface = wait_for("the local terminal", lambda: self.surfaces(self.local_id), self.timeout)[0]
        self.wait_state("the local terminal's size state", self.local_surface, self.has_row("mac:", "the Mac pane"))
        self.local_key = self.key_of(self.local_surface, "mac:")
        self.facts["local_pane_key"] = self.local_key
        self.report_viewport(self.local_id, self.local_surface, self.phone_client, "iphone", 40, 12)

        def check(state: Dict[str, Any]) -> None:
            self.expect_first(self.local_key)(state)
            mac = self.row(state, "mac:")
            if not self.row(state, "mobile:" + self.phone_client):
                raise Failure(f"the phone is not a participant yet: {self.rows(state)}")
            want = grid_of(mac and mac.get("viewport"))
            if self.grid(state) != want or self.grid(state) == (40, 12):
                raise Failure(f"grid {self.grid(state)}, expected the Mac pane's {want}, not the phone's 40x12")

        return self.wait_state("the local terminal to keep its Mac pane's grid", self.local_surface, check)

    def mode_choice_applies_to_every_terminal(self) -> Dict[str, Any]:
        _, _, self.source2_surface, _ = self.source_with_mirror("source2")
        self.wait_state("the second mirror to join its terminal", self.source2_surface,
                        self.has_row(MIRROR_PREFIX, "the second mirror"))
        chosen = self.select_mode(self.mirror_surface, "latest")
        results = {"accepted": chosen.get("accepted")}
        for label, surface in (("source", self.source_surface), ("source2", self.source2_surface),
                               ("local", self.local_surface)):
            results[label] = self.wait_state(f"the {label} terminal to follow Follow Latest", surface,
                                             self.expect_mode("latest"))
        results["preference"] = self.preference()
        return results

    def new_terminals_follow_choice(self) -> Dict[str, Any]:
        local2 = self.create_workspace("local2")
        local2_surface = wait_for("the new local terminal", lambda: self.surfaces(local2), self.timeout)[0]
        local = self.wait_state("a new local terminal to start in Follow Latest", local2_surface, self.expect_mode("latest"))
        created = self.request("mobile.terminal.create", {"workspace_id": self.source_id})
        terminal = up(created.get("created_terminal_id"))
        if not terminal:
            raise Failure(f"mobile.terminal.create returned no created_terminal_id: {created}")
        remote = self.wait_state("a terminal opened over the device link to start in Follow Latest", terminal,
                                 self.expect_mode("latest"))
        return {"local": local, "device_link": {"terminal": terminal, **remote}}

    def second_mac_no_ping_pong(self) -> Dict[str, Any]:
        self.select_mode(self.mirror_surface, "priority")
        self.select(self.mirror_id)
        before = self.wait_state("the source terminal to be Priority with this viewer first",
                                 self.source_surface, self.expect_first(self.mirror_key))
        self.report_viewport(self.source_id, self.source_surface, self.mac_b_client, "mac", 100, 30)
        self.wait_state("the second Mac to join", self.source_surface,
                        self.has_row("mobile:" + self.mac_b_client, "the second Mac"))
        b_key = self.key_of(self.source_surface, "mobile:" + self.mac_b_client)
        self.facts["mac_b_key"] = b_key
        self.request("mobile.terminal.size_policy.set", {
            "workspace_id": self.source_id, "surface_id": self.source_surface,
            "policy": {"mode": "priority", "priority": [b_key], "fixed": None},
        })
        after = self.wait_state("the second Mac's choice to land", self.source_surface, self.expect_first(b_key))
        held = self.hold(self.source_surface, self.expect_first(b_key))
        return {"before": before, "after": after, **held}

    def viewing_mac_viewport_up_to_500x200(self) -> Dict[str, Any]:
        """A big display's full-screen pane reaches the other Mac whole (a phone's stays 300x120)."""
        self.report_viewport(self.source_id, self.source_surface, self.mac_b_client, "mac", 400, 150)

        def check(state: Dict[str, Any]) -> None:
            mac_b = self.row(state, "mobile:" + self.mac_b_client)
            if not mac_b:
                raise Failure(f"the second Mac is not a participant yet: {self.rows(state)}")
            if grid_of(mac_b.get("viewport")) != (400, 150):
                raise Failure(f"the second Mac's 400x150 pane was taken as {grid_of(mac_b.get('viewport'))}")

        return self.wait_state("the second Mac's 400x150 viewport", self.source_surface, check)

    def reselecting_mode_keeps_claims(self) -> Dict[str, Any]:
        """Re-picking the stored mode on one terminal is not a sweep: it does not re-apply this
        Mac's preference over another terminal another Mac claimed."""
        b_key = self.facts.get("mac_b_key")
        if not b_key:
            raise Failure("the second Mac never claimed the source terminal (second_mac_no_ping_pong failed)")
        sizing = self.sock.call(SIZING + "state", {}) or {}
        if not sizing.get("stored") or (sizing.get("preference") or {}).get("mode") != "priority":
            raise Failure(f"expected a stored Priority preference before re-picking it: {sizing}")
        before = self.wait_state("the second Mac to hold the source terminal", self.source_surface,
                                 self.expect_first(b_key))
        chosen = self.select_mode(self.local_surface, "priority")
        held = self.hold(self.source_surface, self.expect_first(b_key))
        return {"accepted": chosen.get("accepted"), "before": before, **held}

    def stored_choice_applies_to_its_terminal(self) -> Dict[str, Any]:
        """Re-choosing the stored preference skips only the sweep over every terminal: the
        terminal the user acted on still takes it when its own policy differs (another Mac, a
        phone or `terminal.size_policy.set` changed it), as upstream's setMode compares against
        the terminal's own policy."""
        b_key = self.facts.get("mac_b_key")
        if not b_key:
            raise Failure("the second Mac never joined the source terminal (second_mac_no_ping_pong failed)")
        self.select(self.mirror_id)
        stored = self.preference() or {}
        if stored.get("mode") != "priority" or stored.get("priority") != ["self"]:
            raise Failure(f"expected the stored preference Priority [self]: {stored}")

        def other_mac_sets(policy: Dict[str, Any]) -> None:
            self.request("mobile.terminal.size_policy.set", {
                "workspace_id": self.source_id, "surface_id": self.source_surface, "policy": policy,
            })

        other_mac_sets({"mode": "smallest", "priority": [b_key], "fixed": None})
        fit = self.wait_state("the second Mac's Fit everyone", self.source_surface, self.expect_mode("smallest"))
        chosen = self.select_mode(self.mirror_surface, "priority")
        by_mode = self.wait_state("Priority picked on the mirror to reach its terminal", self.source_surface,
                                  self.expect_first(self.mirror_key))
        other_mac_sets({"mode": "priority", "priority": [b_key], "fixed": None})
        claimed = self.wait_state("the second Mac to claim the terminal again", self.source_surface,
                                  self.expect_first(b_key))
        dragged = self.set_priority(self.mirror_surface, [self.mirror_key])
        by_drag = self.wait_state("the stored order dragged on the mirror to reach its terminal", self.source_surface,
                                  self.expect_first(self.mirror_key))
        after = self.preference()
        if after != stored:
            raise Failure(f"re-choosing the stored preference changed it: {stored} -> {after}")
        # Leave the terminal as the earlier steps did (the second Mac holds it), so the
        # next step's claim is a change it can wait for.
        other_mac_sets({"mode": "priority", "priority": [b_key], "fixed": None})
        self.wait_state("the second Mac to hold the terminal again", self.source_surface, self.expect_first(b_key))
        return {"fit": fit, "mode_accepted": chosen.get("accepted"), "by_mode": by_mode, "claimed": claimed,
                "drag_accepted": dragged.get("accepted"), "by_drag": by_drag}

    def showing_keeps_other_macs_mode(self) -> Dict[str, Any]:
        """Another Mac's explicit Fit everyone stays when this Mac shows its mirror again or its
        link reconnects: a claim only moves this Mac first in a Priority order, it never changes
        the mode another Mac chose (red before: the shown mirror pushed this Mac's Priority)."""
        b_key = self.facts.get("mac_b_key")
        if not b_key:
            raise Failure("the second Mac never joined the source terminal (second_mac_no_ping_pong failed)")
        self.other_mac_sets({"mode": "smallest", "priority": [b_key], "fixed": None})
        fit = self.wait_state("the second Mac's Fit everyone", self.source_surface, self.expect_mode("smallest"))
        self.select(self.local_id)
        self.wait_state("the mirror to stop counting while hidden", self.source_surface, self.mirror_counts(False))
        self.select(self.mirror_id)
        self.wait_state("the shown mirror to count again", self.source_surface, self.mirror_counts(True))
        try:
            shown = self.hold(self.source_surface, self.expect_mode("smallest"), steady=False)
            self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
            time.sleep(1.0)
            self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
            wait_for("the loopback link to reconnect", lambda: self.device().get("link_state") == "connected",
                     self.timeout)
            self.wait_state("the reconnected mirror to count again", self.source_surface, self.mirror_counts(True))
            reconnected = self.hold(self.source_surface, self.expect_mode("smallest"), steady=False)
        finally:
            # Leave the terminal as the next step expects: the second Mac holds it in Priority.
            self.other_mac_sets({"mode": "priority", "priority": [b_key], "fixed": None})
            self.wait_state("the second Mac to hold the terminal again", self.source_surface, self.expect_first(b_key))
        return {"fit": fit, "after_show": shown, "after_reconnect": reconnected}

    def showing_again_reclaims(self) -> Dict[str, Any]:
        self.select(self.local_id)
        self.wait_state("the mirror to stop counting while hidden", self.source_surface, self.mirror_counts(False))
        self.select(self.mirror_id)
        claimed = self.wait_state("the shown mirror to claim the terminal", self.source_surface,
                                  self.expect_first(self.mirror_key))
        return {**claimed, **self.hold(self.source_surface, self.expect_first(self.mirror_key))}

    def reconnect_reclaims(self) -> Dict[str, Any]:
        self.select(self.mirror_id)
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        time.sleep(1.0)
        # What a restarted Mac does: its terminal starts over with its own default, Priority
        # with its own pane first.
        pane_key = self.facts["source_pane_key"]
        self.sock.call("terminal.size_policy.set", {"surface_id": self.source_surface, "mode": "priority",
                                                     "priority": [pane_key]})
        reset = self.wait_state("the other Mac's reset", self.source_surface, self.expect_first(pane_key))
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        wait_for("the loopback link to reconnect", lambda: self.device().get("link_state") == "connected", self.timeout)
        claimed = self.wait_state("the reconnected mirror to claim the terminal again", self.source_surface,
                                  self.expect_first(self.mirror_key))
        return {"reset": reset, "claimed": claimed}

    def sticky_choice_stays_on_this_mac(self) -> Dict[str, Any]:
        """A mode chosen on one of this Mac's terminals changes this Mac's terminals, not the
        terminals this Mac's mirrors show. In the loopback the source terminal is also this Mac's
        own, so it takes the choice as a local terminal, resolved to its own pane's key; a push
        through the shown mirror would name the mirror's key and land last (red before: every
        mirror pushed the new preference to the terminal it shows)."""
        pane_key = self.facts["source_pane_key"]
        self.select(self.mirror_id)
        before = self.wait_state("the shown mirror to hold the source terminal", self.source_surface,
                                 self.expect_first(self.mirror_key))

        def own_pane(state: Dict[str, Any]) -> None:
            self.expect_mode("largest")(state)
            priority = self.policy(state)["priority"]
            if priority[:1] == [self.mirror_key]:
                raise Failure(f"the mirror pushed this Mac's choice to the terminal it shows: {self.policy(state)}")
            if priority[:1] != [pane_key]:
                raise Failure(f"policy is {self.policy(state)}, expected this Mac's choice for its own pane {pane_key}")

        chosen = self.select_mode(self.local_surface, "largest")
        try:
            local = self.wait_state("Largest Window on the local terminal it was chosen on", self.local_surface,
                                    self.expect_mode("largest"))
            source = self.wait_state("the source terminal to take it as this Mac's own terminal",
                                     self.source_surface, own_pane)
            held = self.hold(self.source_surface, own_pane, steady=False)
        finally:
            # Back to Priority, chosen on the mirror (a choice on that very terminal), for the next steps.
            self.select_mode(self.mirror_surface, "priority")
            restored = self.wait_state("Priority chosen on the mirror to reach its terminal", self.source_surface,
                                       self.expect_first(self.mirror_key))
        return {"accepted": chosen.get("accepted"), "before": before, "local": local, "source": source,
                **held, "restored": restored}

    def priority_order_applies_everywhere(self) -> Dict[str, Any]:
        self.report_viewport(self.source_id, self.source_surface, self.phone_client, "iphone", 40, 12)
        self.wait_state("the phone to join the source terminal", self.source_surface,
                        self.has_row("mobile:" + self.phone_client, "the phone"))
        phone_key = self.key_of(self.source_surface, "mobile:" + self.phone_client)
        self.facts["phone_key"] = phone_key
        chosen = self.set_priority(self.mirror_surface, [phone_key, self.mirror_key])

        def order(keys: List[str]) -> Callable[[Dict[str, Any]], None]:
            def check(state: Dict[str, Any]) -> None:
                policy = self.policy(state)
                if policy["mode"] != "priority" or policy["priority"] != keys:
                    raise Failure(f"policy is {policy}, expected priority {keys}")
            return check

        preference = self.preference() or {}
        if preference.get("mode") != "priority" or preference.get("priority") != [phone_key, "self"]:
            raise Failure(f"the drag was stored as {preference}, expected priority [{phone_key}, self]")
        source = self.wait_state("the dragged order on the source terminal", self.source_surface,
                                 order([phone_key, self.mirror_key]))
        # In the loopback the local terminal is also "the other Mac's terminal" for its own
        # (hidden) auto-mirror. Builds before sticky_choice_stays_on_this_mac pushed the choice
        # through every mirror after the local apply, so that mirror's push of the same order,
        # relative to itself, landed last; now no mirror pushes it and the Mac pane's view stays.
        own_view = self.local_key
        for mirror in (self.sock.call(SIZING + "state", {}) or {}).get("mirrors") or []:
            if up(mirror.get("remote_surface_id")) == up(self.local_surface) and mirror.get("pushed"):
                own_view = str(mirror.get("self_key") or "")
        local = self.wait_state("the same order, relative to its own view on this Mac, on the local terminal",
                                self.local_surface, order([phone_key, own_view]))
        return {"accepted": chosen.get("accepted"), "source": source, "local": local,
                "local_own_view": "auto-mirror" if own_view != self.local_key else "mac pane",
                "preference": preference}

    def choice_survives_relaunch(self) -> Dict[str, Any]:
        self.select_mode(self.mirror_surface, "largest")
        self.wait_state("Largest Window on the source terminal", self.source_surface, self.expect_mode("largest"))
        self.relaunch()
        self.setup_after_relaunch()
        fresh = self.create_workspace("relaunched")
        fresh_surface = wait_for("the new local terminal", lambda: self.surfaces(fresh), self.timeout)[0]
        result = {"new_local": self.wait_state("a new terminal after the relaunch to start in Largest Window",
                                               fresh_surface, self.expect_mode("largest"))}
        restored = self.surfaces(self.source_id)
        if restored:
            result["restored_source"] = self.wait_state("the restored source terminal to start in Largest Window",
                                                        restored[0], self.expect_mode("largest"))
        else:
            result["restored_source"] = None
        result["preference"] = self.preference()
        return result

    def relaunch(self) -> None:
        app = self.args.app_path
        bundle_id = plistlib.loads((Path(app) / "Contents" / "Info.plist").read_bytes())["CFBundleIdentifier"]
        self.sock.close()
        subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to quit'], check=False, capture_output=True)
        wait_for("the app to quit", lambda: not self.app_running(bundle_id), 60, interval_s=0.5)
        env_args = ["--env", "SUPERMUX_DEBUG_LOOPBACK_DEVICE=1"]
        if self.args.projects_file:
            env_args += ["--env", f"SUPERMUX_PROJECTS_FILE={self.args.projects_file}"]
        subprocess.run(["open", "-g", *env_args, app], check=True)
        wait_for("the relaunched app's socket", self.socket_alive, 60)
        self.sock.connect()
        # The relaunch dropped every fake viewer report.
        self.reports.clear()

    def setup_after_relaunch(self) -> None:
        def ready() -> bool:
            device = self.device()
            return device.get("link_state") == "connected" and bool(device.get("has_fetched_records"))
        wait_for("the loopback device to reconnect after the relaunch", ready, self.timeout)

    @staticmethod
    def app_running(bundle_id: str) -> bool:
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
        try:
            self.facts["preference_reset_at_end"] = (self.sock.call(SIZING + "reset", {}) or {}).get("reset")
        except (Failure, OSError) as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))
        try:
            self.clear_reports()
        except OSError as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))
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
              and self.step("source_and_mirror", self.source_and_mirror))
        if ok:
            ok = self.step("default_policy_is_this_mac_first", self.default_policy_is_this_mac_first) and ok
            ok = self.step("counting_source_pane_does_not_shrink", self.counting_source_pane_does_not_shrink) and ok
            ok = self.step("local_terminal_mac_first_over_phone", self.local_terminal_mac_first_over_phone) and ok
            ok = self.step("mode_choice_applies_to_every_terminal", self.mode_choice_applies_to_every_terminal) and ok
            ok = self.step("new_terminals_follow_choice", self.new_terminals_follow_choice) and ok
            ok = self.step("second_mac_no_ping_pong", self.second_mac_no_ping_pong) and ok
            ok = self.step("viewing_mac_viewport_up_to_500x200", self.viewing_mac_viewport_up_to_500x200) and ok
            if self.local_surface:
                ok = self.step("reselecting_mode_keeps_claims", self.reselecting_mode_keeps_claims) and ok
            ok = self.step("stored_choice_applies_to_its_terminal", self.stored_choice_applies_to_its_terminal) and ok
            if self.local_id:
                ok = self.step("showing_keeps_other_macs_mode", self.showing_keeps_other_macs_mode) and ok
                ok = self.step("showing_again_reclaims", self.showing_again_reclaims) and ok
            ok = self.step("reconnect_reclaims", self.reconnect_reclaims) and ok
            if self.local_surface:
                ok = self.step("sticky_choice_stays_on_this_mac", self.sticky_choice_stays_on_this_mac) and ok
            if self.local_key:
                ok = self.step("priority_order_applies_everywhere", self.priority_order_applies_everywhere) and ok
            if self.args.app_path:
                ok = self.step("choice_survives_relaunch", self.choice_survives_relaunch) and ok
            else:
                self.steps.append({"name": "choice_survives_relaunch", "ok": None, "skipped": "pass --app-path to run"})
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait before a check gives up")
    parser.add_argument("--app-path", help="the tagged .app to quit and relaunch for the persistence check")
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
        test = SizingPolicyE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-terminal-sizing-policy-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = (Path(args.report) if args.report
                   else ARTIFACTS_DIR / f"loopback_terminal_sizing_policy_e2e-{args.tag or 'socket'}.json")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
