#!/usr/bin/env python3
"""End-to-end test: in Auto a terminal always gets back to the size of the device that is
viewing it, whatever happened before. Regression suite for the "stuck at the phone's size
until restart" reports (and their reverse, the phone stuck at the desktop size).

Auto (`latest`): the device you are viewing a terminal from owns its grid. These steps
reproduce the paths that left a terminal at a departed or inactive viewer's grid, and the
guards that keep the fixes from breaking the rules around them. Each step builds its own
state: a fresh shown local terminal (a new workspace), fresh fake viewer client ids, and
for the mirror steps the loopback's source terminal and its auto mirror. The local steps
(R1-R10, R13b-R18) run with auto-mirror off, so their terminals have no loopback mirror as
a second remote participant: like the reported case, the phone is the only other viewer
(a hidden mirror would send Auto down its "phones stay attached" path, which tears the apply
governor down and so hides R1-R3's wedge). The mirror steps turn it back on. Every step runs
even when an earlier one failed; a step made of several checks runs all of them and
reports each (`checks` in the artifact).

"Live grid" is the terminal's real grid: Ghostty's own size, read by the DEBUG driver
`terminal_sizing.governor` (cheap, sampled every 100 ms), confirmed where it matters by a
capture over the device link as the policy suite does. "The Mac grid" is the Mac pane's
own viewport (its participant row), which is what the PTY must return to.

Steps (fix, what it proves; why it fails today):

  R1  governor_wedge                  (F1) the phone (40x12) owns; it reports 44x14 and leaves
                                      inside 400 ms (the Mac takes its grid within 1 s); it comes
                                      back at 40x12 (cold attach) and then reports 46x16: the live
                                      grid follows within 1.5 s. Today the immediate leave cancelled
                                      the flush timer without clearing `flush_scheduled`, so 46x16 is
                                      staged with no timer and the grid stays 40x12.
  R2  wedge_then_held                 (F1) wedged as R1; the Mac row stops counting (size_counts
                                      false), the phone views 40x12 and leaves (reason held); the Mac
                                      row counts again: live = the Mac grid within 3.5 s. Today the
                                      uncap is staged with no timer: 40x12 forever.
  R3  size_to_me_forces               (F2) Size to My Window gives the Mac pane its grid at once:
                                      held_and_wedged (R2 up to held) and held_clean (no wedge, held
                                      at a departed phone's 40x12): Mac owns and live = Mac grid within
                                      1.0 s; mac_owner_wedged (R2's end: the engine already names the
                                      Mac, the PTY is still 40x12): live = Mac grid within 1.0 s.
                                      Today it only notes activity (nothing when the Mac already owns)
                                      and goes through the governor's 3 s uncap window or the wedge.
  R4  departed_viewer_hidden_pane     (F3) the phone views a shown terminal; the portal hides the
                                      pane (3 s) until it stops counting; the phone leaves: before the
                                      reveal the reason is not held, the decided grid is the Mac row's
                                      viewport, the Mac row counts and live = Mac grid within 1 s.
                                      Today nobody counts, so the phone's 40x12 is held.
  R5  hidden_pane_viewer_returns      (F3 guard) while the pane is hidden the phone leaves and reports
                                      again: the phone owns and the Mac row does not count. Passes
                                      today.
  R6  fit_everyone_hidden_pane        (F3 guard) Fit everyone with another Mac viewing (200x60): while
                                      the pane is hidden the grid is 200x60 (a hidden pane does not
                                      size a terminal someone else views). Passes today.
  R7  mac_activity_kept               (F5) the phone owns; the Mac row counts false; a key press on
                                      the Mac pane; the phone repeats its 40x12; the Mac row counts
                                      again: the Mac owns. Today activity that changes no published
                                      state is thrown away, so the phone is still the newest.
  R8  mac_scroll_is_activity          (F7) the phone owns; this Mac's user scrolls over the pane
                                      (`local_scroll`, a posted wheel event, first shown to reach
                                      the terminal: its viewport scrolls into the scrollback): the
                                      Mac owns. Today scrolling never notes activity.
  R9  soft_leave                      (F8) transient_return: a clear with `transient: true`, then the
                                      phone returns with the same viewport 1 s later: no live grid
                                      sample (every 100 ms) leaves 40x12. Today the clear uncaps at once
                                      and the return caps again (two resizes). transient_no_return:
                                      live = Mac grid within 3.5 s (passes today); hard_leave: live =
                                      Mac grid within 1 s (passes today).
  R10 mac_selection_keeps_grid        (F9, Mac-only signal) mac_user_selection: this Mac's user
                                      selects a terminal (`local_select`) and a phone that attaches
                                      right after does not take it (2 s hold: the Mac owns, live = Mac
                                      grid); typing on the phone then takes it. Today attaching is
                                      activity, so the phone owns at once. socket_selection (guard): a
                                      socket selection is not the Mac's user, so a phone attaching
                                      after it owns the grid. Passes today.
  R13b activation_with_textbox        (F6) the phone owns; the user switches to the app with the
                                      terminal's TextBox focused (`activate textbox`): the Mac owns.
                                      Today the handler only knows a focused GhosttyNSView.
  R14 connection_scoped_clear         (F15) the phone's report is re-sent on its newer connection B;
                                      its older connection A closes: the phone still owns after 2 s.
                                      Today the close clears every report of its client id. Guards
                                      (pass today): B closing drops the phone; a control-socket
                                      (unstamped) report is still cleared by a closing connection of
                                      its client.
  R15 lane_input                      (G1) lane_activity: the Mac owns; the phone types over its IRX
                                      input lane (`lane_input`): the phone owns. Today lane input is
                                      nobody's activity. detached_lane_refused: a phone someone
                                      disconnected types over the lane: the frame is refused and the
                                      text never reaches the terminal. Today the lane skips the
                                      detach gate.
  R16 sticky_replay_claim             (G2a) the phone attaches only through `mobile.terminal.replay`
                                      with viewport fields and `viewport_generation` (its reconnect
                                      path): it still owns 8 s later (TTL 5 s). Today the replay's
                                      report is not sticky and expires.
  R17 fixed_seed                      (Fixed seed) the phone owns at 40x12; switching to Fixed without
                                      a size (socket `terminal.size_policy.set mode=fixed`, and the
                                      size panel's mode picker) fixes the Mac pane's own viewport.
                                      Today both seed from the shared grid: 40x12.
  R18 composite_return                the user's report end to end: the phone views T (owns); the Mac
                                      switches away (T hidden); the phone's keyboard goes down and it
                                      locks inside 400 ms; the Mac shows T again with no input: live =
                                      Mac grid within 1 s (may pass today: showing the pane applies at
                                      once); Size to My Window is then a successful no-op; the
                                      governor is not left wedged (today: `flush_scheduled` with
                                      nothing staged); the phone comes back and rotates (60x20): live
                                      follows within 1.5 s (today: stuck at 40x12, the wedge from the
                                      lock moment carried over).
  R12 mirror_size_to_me               (F13) the phone owns the source terminal; Size to My Window on
                                      this Mac's mirror of it, from Auto and from Fit everyone: the
                                      mirror (`mobile:mac-…`) owns within 2 s. Today the mirror sends
                                      nothing (Fit everyone only switches to Auto).
  R13 mirror_activation               (F14) the phone owns the source terminal; the user switches to
                                      the app with the mirror focused (`activate`): the mirror owns
                                      within 2 s. Today a mirror has no local host, so nothing happens.
  R11 mirror_generation_reset         (F12) runs last (it resets every host): the mirror is hidden;
                                      the link drops; this Mac's sizing hosts start over as a relaunch
                                      does (`reset_hosts`); the link comes back: the hidden mirror's
                                      row does not count and it does not own for 3 s. Today the mirror
                                      keeps the old host's higher generation, ignores the new states,
                                      and its replay omits `counts_override: false`.

The DEBUG drivers are `supermux.devices.terminal_sizing.*` (SupermuxTerminalSizingSocketCommands.swift,
SupermuxTerminalSizingRecoveryDrivers.swift). Fake phones report on this control socket as in the
policy suite; R14 and R15 use synthetic phone connections (`connection_request`, `lane_input`).

Writes a JSON report (default tests/supermux/artifacts/loopback_terminal_sizing_recovery_e2e-<tag>.json)
with, per step, its checks, decided states, governor snapshots and live grid samples, and exits
non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_terminal_sizing_recovery_e2e.py [--timeout 30] [--report PATH]
  CMUX_E2E_SUITES="loopback_terminal_sizing_recovery_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))

from loopback_terminal_sizing_policy_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    MIRROR_PREFIX,
    SIZING,
    Failure,
    SizingPolicyE2E,
    Socket,
    grid_of,
    socket_path_for_tag,
    wait_for,
)

Grid = Tuple[int, int]
PHONE = (40, 12)


class SizingRecoveryE2E(SizingPolicyE2E):
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        super().__init__(sock, args)
        # Per step: timestamped snapshots and samples, and the step's own checks.
        self.trace: List[Dict[str, Any]] = []
        self.checks: List[Dict[str, Any]] = []
        self.step_started = time.monotonic()
        # Synthetic phone connections opened through the drivers (closed at the end).
        self.connections: set = set()

    # -- reads ------------------------------------------------------------------------

    def client(self, label: str) -> str:
        return f"e2e-{label}-{self.nonce}"

    def governor(self, surface_id: str) -> Dict[str, Any]:
        return self.sock.call(SIZING + "governor", {"surface_id": surface_id}) or {}

    def surface_grid(self, surface_id: str) -> Optional[Grid]:
        return grid_of(self.governor(surface_id).get("surface_grid"))

    def mac_grid(self, surface_id: str) -> Grid:
        row = self.row(self.state(surface_id), "mac:")
        grid = grid_of(row and row.get("viewport"))
        if not grid:
            raise Failure(f"the Mac pane has no viewport: {self.rows(self.state(surface_id))}")
        return grid

    def mac_id(self, surface_id: str) -> str:
        row = self.row(self.state(surface_id), "mac:")
        if not row:
            raise Failure(f"no Mac pane row on {surface_id}")
        return row["id"]

    def note(self, label: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        """Records a driver's reply in the step's trace (kept when the step fails)."""
        self.trace.append({"t": self.elapsed(), "label": label, "reply": payload})
        return payload

    def elapsed(self) -> float:
        return round(time.monotonic() - self.step_started, 2)

    def snap(self, label: str, surface_id: str) -> Dict[str, Any]:
        """Records the decided state, the governor and the live grid now."""
        state = self.state(surface_id)
        governor = self.governor(surface_id)
        entry = {
            "t": self.elapsed(), "label": label, "surface_id": surface_id,
            "decided": self.summary(state), "governor": governor.get("governor"),
            "surface_grid": governor.get("surface_grid"),
        }
        self.trace.append(entry)
        return entry

    # -- fake viewers -----------------------------------------------------------------

    def viewport_params(self, workspace_id: str, surface_id: str, client_id: str, cols: int, rows: int,
                        kind: str = "iphone", **extra: Any) -> Dict[str, Any]:
        """A dedicated viewport report's params, with this viewer's next generation."""
        key = (workspace_id, surface_id, client_id)
        generation = self.reports.get(key, 0) + 1
        self.reports[key] = generation
        params = {
            "workspace_id": workspace_id, "surface_id": surface_id, "client_id": client_id,
            "viewport_columns": cols, "viewport_rows": rows, "viewport_generation": generation,
            "device_kind": kind, "device_id": client_id, "device_name": f"E2E {kind}",
        }
        params.update(extra)
        return params

    def report(self, workspace_id: str, surface_id: str, client_id: str, cols: int, rows: int,
               kind: str = "iphone", **extra: Any) -> None:
        self.sock.call("mobile.terminal.viewport",
                       self.viewport_params(workspace_id, surface_id, client_id, cols, rows, kind, **extra))

    def leave(self, workspace_id: str, surface_id: str, client_id: str, **extra: Any) -> None:
        """The viewer's clear (`transient: true` for a scene-phase leave)."""
        key = (workspace_id, surface_id, client_id)
        generation = self.reports.get(key, 0) + 1
        self.reports[key] = generation
        params = {"workspace_id": workspace_id, "surface_id": surface_id, "client_id": client_id,
                  "clear": True, "viewport_generation": generation}
        params.update(extra)
        self.sock.call("mobile.terminal.viewport", params)

    def connection_request(self, connection_id: str, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        self.connections.add(connection_id)
        result = self.sock.call(SIZING + "connection_request",
                                {"connection_id": connection_id, "method": method, "params": params}) or {}
        if not result.get("ok"):
            raise Failure(f"{method} on connection {connection_id[:8]} failed: {result.get('error')}")
        return result

    def connection_close(self, connection_id: str, client_id: Optional[str] = None) -> Dict[str, Any]:
        self.connections.discard(connection_id)
        params: Dict[str, Any] = {"connection_id": connection_id}
        if client_id:
            params["client_id"] = client_id
        return self.sock.call(SIZING + "connection_close", params) or {}

    def lane_input(self, surface_id: str, client_id: str, connection_id: str, text: str) -> Dict[str, Any]:
        self.connections.add(connection_id)
        return self.sock.call(SIZING + "lane_input", {
            "surface_id": surface_id, "client_id": client_id, "connection_id": connection_id, "text": text,
        }) or {}

    def set_auto_mirror(self, enabled: bool) -> None:
        self.sock.call("supermux.devices.set_auto_mirror", {"enabled": enabled})
        self.facts.setdefault("auto_mirror", []).append(enabled)

    def no_mirror_row(self, label: str, surface_id: str) -> None:
        """A local step's terminal has no loopback mirror (auto-mirror is off for these steps)."""
        mirror = self.row(self.state(surface_id), MIRROR_PREFIX)
        if mirror:
            raise Failure(f"harness: the {label} terminal has a loopback mirror participant ({mirror['id']}); "
                          "the local steps need auto-mirror off")

    def keeps(self, what: str, surface_id: str, check: Callable[[Dict[str, Any]], None],
              seconds: float) -> Dict[str, Any]:
        """`check` keeps passing for `seconds`; a failure says what was expected and when it broke."""
        started = time.monotonic()
        try:
            return self.hold(surface_id, check, seconds, steady=False)
        except Failure as error:
            self.snap(f"broke: {what}", surface_id)
            raise Failure(f"{what}: broke after {time.monotonic() - started:.1f}s of {seconds}s: {error}") from None

    def size_to_me(self, surface_id: str) -> Dict[str, Any]:
        return self.sock.call("terminal.size_to_me", {"surface_id": surface_id}) or {}

    def set_counts(self, surface_id: str, participant_id: str, counts: Optional[bool]) -> None:
        self.sock.call("terminal.size_counts.set",
                       {"surface_id": surface_id, "participant_id": participant_id, "counts": counts})

    def set_mode(self, surface_id: str, mode: str) -> Dict[str, Any]:
        """This one terminal's mode (the socket path: no stored preference)."""
        return self.sock.call("terminal.size_policy.set", {"surface_id": surface_id, "mode": mode}) or {}

    # -- checks -----------------------------------------------------------------------

    def within(self, what: str, surface_id: str, check: Callable[[Dict[str, Any]], None],
               seconds: float) -> Dict[str, Any]:
        """The decided state passes `check` within `seconds` (polled every 100 ms)."""
        started = time.monotonic()

        def probe() -> Dict[str, Any]:
            state = self.state(surface_id)
            check(state)
            return self.summary(state)

        try:
            result = wait_for(what, probe, seconds, interval_s=0.1)
        except Failure:
            self.snap(f"timed out: {what}", surface_id)
            raise
        return {"reached_in": round(time.monotonic() - started, 2), **result}

    def wait_grid(self, surface_id: str, want: Grid, seconds: float, what: str) -> Dict[str, Any]:
        """The live grid becomes `want` within `seconds` (sampled every 100 ms)."""
        started = time.monotonic()
        samples: List[Dict[str, Any]] = []
        while True:
            grid = self.surface_grid(surface_id)
            waited = round(time.monotonic() - started, 2)
            samples.append({"t": waited, "grid": list(grid or ())})
            if grid == want:
                self.trace.append({"t": self.elapsed(), "label": what, "reached_in": waited, "samples": samples[-30:]})
                return {"reached_in": waited}
            if waited >= seconds:
                governor = self.governor(surface_id).get("governor")
                self.trace.append({"t": self.elapsed(), "label": f"timed out: {what}", "samples": samples[-30:],
                                   "governor": governor})
                raise Failure(f"{what}: the live grid is {grid}, not {want}, after {seconds}s (governor {governor})")
            time.sleep(0.1)

    def sample_grids(self, surface_id: str, seconds: float, into: List[Dict[str, Any]], origin: float) -> None:
        """Samples the live grid every 100 ms for `seconds` into `into`."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            into.append({"t": round(time.monotonic() - origin, 2), "grid": list(self.surface_grid(surface_id) or ())})
            time.sleep(0.1)

    def confirm_live(self, workspace_id: str, surface_id: str, want: Grid) -> List[int]:
        """The device-link capture agrees (the policy suite's definition of the real grid)."""
        live: Optional[tuple] = None
        for _ in range(4):
            live = self.live_grid(workspace_id, surface_id)
            if live == want:
                break
            time.sleep(0.3)
        self.trace.append({"t": self.elapsed(), "label": "captured live grid", "live_grid": list(live or ()),
                           "want": list(want)})
        if live != want:
            raise Failure(f"the captured live grid is {live}, not {want}")
        return list(live)

    def owns(self, client_id: str, grid: Grid = PHONE) -> Callable[[Dict[str, Any]], None]:
        return self.owned_by("mobile:" + client_id, grid)

    def not_participant(self, client_id: str) -> Callable[[Dict[str, Any]], None]:
        def check(state: Dict[str, Any]) -> None:
            if self.row(state, "mobile:" + client_id):
                raise Failure(f"{client_id} is still a participant: {self.rows(state)}")
        return check

    def held_at(self, grid: Grid, departed: str) -> Callable[[Dict[str, Any]], None]:
        """Nobody counts: the departed viewer is gone and its grid is held."""
        def check(state: Dict[str, Any]) -> None:
            self.not_participant(departed)(state)
            if state.get("reason") != "held" or self.grid(state) != grid:
                raise Failure(f"reason {state.get('reason')} grid {self.grid(state)}, expected held at {grid}")
        return check

    def check(self, name: str, action: Callable[[], Optional[Dict[str, Any]]]) -> bool:
        """One check of a step: recorded, and the step goes on when it fails."""
        record: Dict[str, Any] = {"name": name}
        try:
            record.update(action() or {})
            record["ok"] = True
        except Failure as error:
            record["ok"] = False
            record["error"] = str(error)
        self.checks.append(record)
        print(f"  {'ok  ' if record['ok'] else 'FAIL'} {name}" + ("" if record["ok"] else ": " + record["error"]),
              file=sys.stderr)
        return record["ok"]

    def step(self, name: str, action: Callable[[], Optional[Dict[str, Any]]]) -> bool:
        self.trace, self.checks = [], []
        self.step_started = time.monotonic()

        def run() -> Optional[Dict[str, Any]]:
            result = action()
            failed = [c for c in self.checks if not c["ok"]]
            if failed:
                raise Failure("; ".join(f"{c['name']}: {c['error']}" for c in failed))
            return result

        ok = super().step(name, run)
        record = self.steps[-1]
        record["checks"] = self.checks
        record["trace"] = self.trace
        return ok

    # -- set-up -----------------------------------------------------------------------

    def fresh(self, label: str) -> Tuple[str, str]:
        """A new selected local workspace whose shown Mac pane counts (Auto)."""
        workspace = self.create_workspace(label)
        self.select(workspace)
        surface = wait_for(f"the {label} terminal", lambda: self.surfaces(workspace), self.timeout)[0]
        self.wait_state(f"the {label} Mac pane to count", surface,
                        lambda state: (self.expect_mode("latest")(state), self.mac_counts(True)(state)))
        self.no_mirror_row(label, surface)
        self.snap(f"{label}: fresh terminal", surface)
        return workspace, surface

    def phone_takes(self, workspace_id: str, surface_id: str, client_id: str, grid: Grid = PHONE,
                    **extra: Any) -> None:
        """The phone reports `grid` and owns it, decided and live."""
        self.report(workspace_id, surface_id, client_id, grid[0], grid[1], **extra)
        self.within(f"{client_id} to own {grid}", surface_id, self.owns(client_id, grid), 5)
        self.wait_grid(surface_id, grid, 3, f"the live grid to be the phone's {grid}")

    def phone_retakes(self, workspace_id: str, surface_id: str, client_id: str, grid: Grid = PHONE) -> None:
        """The phone's terminal view comes back on screen (`view_appeared`): it takes the grid again."""
        def again() -> bool:
            self.report(workspace_id, surface_id, client_id, grid[0], grid[1], view_appeared=True)
            time.sleep(0.3)
            self.owns(client_id, grid)(self.state(surface_id))
            return True

        wait_for(f"{client_id} to take the grid again", again, 10, interval_s=0.7)
        self.wait_grid(surface_id, grid, 3, f"the live grid to be the phone's {grid} again")

    def wedge(self, workspace_id: str, surface_id: str, client_id: str) -> Dict[str, Any]:
        """The phone owns 40x12, reports 44x14 (staged for 400 ms) and leaves at once."""
        self.phone_takes(workspace_id, surface_id, client_id)
        self.report(workspace_id, surface_id, client_id, 44, 14)
        self.leave(workspace_id, surface_id, client_id)
        snap = self.snap("44x14 then an immediate leave", surface_id)
        mac = self.mac_grid(surface_id)
        self.within("the Mac pane to own the grid after the leave", surface_id, self.mac_owns(), 2)
        reached = self.wait_grid(surface_id, mac, 1.0, "the live grid to be the Mac grid after the leave")
        self.snap("after the leave", surface_id)
        return {"after_leave": snap, "mac_grid": list(mac), "mac_restored": reached}

    def close_created(self) -> None:
        for workspace_id in self.created:
            try:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except Failure as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))
        # Their terminals are gone: nothing is left to clear for their fake viewers.
        closed = set(self.created)
        self.reports = {key: generation for key, generation in self.reports.items() if key[0] not in closed}
        self.created.clear()

    def ensure_mirror(self) -> None:
        """The loopback's source terminal and its auto mirror, the mirror shown and counting."""
        if not self.source_surface:
            # The local steps are done: close their workspaces so turning auto-mirror back on
            # does not open a mirror of each.
            self.close_created()
            self.set_auto_mirror(True)
            self.source_and_mirror()
        self.select(self.mirror_id)
        self.wait_state("the shown mirror to count", self.source_surface, self.mirror_counts(True))

    # -- R1-R3: nothing could recover a wrong size -------------------------------------

    def r1_governor_wedge(self) -> Dict[str, Any]:
        workspace, surface = self.fresh("r1")
        phone = self.client("r1")
        wedged = self.wedge(workspace, surface, phone)
        self.report(workspace, surface, phone, 40, 12)
        cold = self.wait_grid(surface, PHONE, 2.0, "the phone's 40x12 again (a cold attach)")
        self.report(workspace, surface, phone, 46, 16)
        self.snap("46x16 reported", surface)
        resized = self.wait_grid(surface, (46, 16), 1.5, "the phone's 46x16 (a keyboard or rotation change)")
        decided = self.within("the phone to own 46x16", surface, self.owns(phone, (46, 16)), 1)
        live = self.confirm_live(workspace, surface, (46, 16))
        return {**wedged, "cold_attach": cold, "resized": resized, "decided": decided, "live_grid": live}

    def held_after_wedge(self, label: str) -> Tuple[str, str, str, str, Grid]:
        """R2 up to "held": wedged, the Mac row not counting, the phone viewed and left."""
        workspace, surface = self.fresh(label)
        phone = self.client(label)
        self.wedge(workspace, surface, phone)
        mac_id = self.mac_id(surface)
        mac = self.mac_grid(surface)
        self.set_counts(surface, mac_id, False)
        self.within("the Mac row to stop counting", surface, self.mac_counts(False), 2)
        self.phone_takes(workspace, surface, phone)
        self.leave(workspace, surface, phone)
        self.within("the terminal to hold the departed phone's 40x12", surface, self.held_at(PHONE, phone), 2)
        self.snap("held", surface)
        return workspace, surface, phone, mac_id, mac

    def r2_wedge_then_held(self) -> Dict[str, Any]:
        workspace, surface, _, mac_id, mac = self.held_after_wedge("r2")
        self.set_counts(surface, mac_id, None)
        decided = self.within("the Mac pane to own the grid", surface, self.mac_owns(), 2)
        restored = self.wait_grid(surface, mac, 3.5, "the live grid to be the Mac grid once the Mac row counts")
        return {"decided": decided, "restored": restored, "live_grid": self.confirm_live(workspace, surface, mac)}

    def r3_size_to_me_forces(self) -> Dict[str, Any]:
        def forced(workspace: str, surface: str, mac: Grid) -> Dict[str, Any]:
            started = time.monotonic()
            self.size_to_me(surface)
            decided = self.within("Size to My Window to give the Mac pane the grid", surface, self.mac_owns(), 1.0)
            remaining = max(0.1, 1.0 - (time.monotonic() - started))
            restored = self.wait_grid(surface, mac, remaining, "the live grid to be the Mac grid after Size to My Window")
            return {"decided": decided, "restored": restored, "live_grid": self.confirm_live(workspace, surface, mac)}

        def held_and_wedged() -> Dict[str, Any]:
            workspace, surface, _, _, mac = self.held_after_wedge("r3a")
            return forced(workspace, surface, mac)

        def held_clean() -> Dict[str, Any]:
            workspace, surface = self.fresh("r3b")
            phone = self.client("r3b")
            self.phone_takes(workspace, surface, phone)
            mac = self.mac_grid(surface)
            self.set_counts(surface, self.mac_id(surface), False)
            self.within("the Mac row to stop counting", surface, self.mac_counts(False), 2)
            self.leave(workspace, surface, phone)
            self.within("the departed phone's 40x12 to be held", surface, self.held_at(PHONE, phone), 2)
            self.snap("held (no wedge)", surface)
            return forced(workspace, surface, mac)

        def mac_owner_wedged() -> Dict[str, Any]:
            workspace, surface, _, mac_id, mac = self.held_after_wedge("r3c")
            self.set_counts(surface, mac_id, None)
            self.within("the engine to name the Mac pane", surface, self.mac_owns(), 2)
            time.sleep(1.0)
            before = self.snap("the Mac owns: live grid before Size to My Window", surface)
            if grid_of(before.get("surface_grid")) == mac:
                # Nothing is wedged (F1 fixed): the precondition cannot be built any more.
                return {"precondition_unreachable": True, "live_grid": list(mac)}
            return forced(workspace, surface, mac)

        self.check("held_and_wedged", held_and_wedged)
        self.check("held_clean", held_clean)
        self.check("mac_owner_wedged", mac_owner_wedged)
        return {}

    # -- R4-R6: a departed viewer on a hidden Mac pane --------------------------------

    def hidden_with_phone(self, label: str, hidden_ms: int) -> Tuple[str, str, str, float]:
        """A fresh terminal the phone owns, its pane hidden by the portal until it stops counting."""
        workspace, surface = self.fresh(label)
        phone = self.client(label)
        self.phone_takes(workspace, surface, phone)
        self.portal_flicker(surface, hidden_ms)
        hidden_at = time.monotonic()
        self.within("the hidden Mac pane to stop counting", surface, self.mac_counts(False), 2)
        self.snap("pane hidden", surface)
        return workspace, surface, phone, hidden_at

    def before_reveal(self, hidden_at: float, hidden_ms: int) -> None:
        if time.monotonic() - hidden_at > hidden_ms / 1000.0 - 0.1:
            raise Failure("the check ran after the portal revealed the pane; it proves nothing")

    def r4_departed_viewer_hidden_pane(self) -> Dict[str, Any]:
        hidden_ms = 3000
        workspace, surface, phone, hidden_at = self.hidden_with_phone("r4", hidden_ms)
        mac = self.mac_grid(surface)
        self.leave(workspace, surface, phone)

        def own_grid(state: Dict[str, Any]) -> None:
            self.not_participant(phone)(state)
            if state.get("reason") == "held" or self.grid(state) != mac:
                raise Failure(f"grid {self.grid(state)} ({state.get('reason')}), expected the Mac row's {mac}")
            self.mac_counts(True)(state)

        try:
            decided = self.within("the Mac pane's own grid while hidden", surface, own_grid, 1.0)
            restored = self.wait_grid(surface, mac, 1.0, "the live grid to be the Mac grid while hidden")
            self.before_reveal(hidden_at, hidden_ms)
        finally:
            time.sleep(max(0.0, hidden_ms / 1000.0 - (time.monotonic() - hidden_at)) + 0.5)
        return {"decided": decided, "restored": restored}

    def r5_hidden_pane_viewer_returns(self) -> Dict[str, Any]:
        hidden_ms = 4000
        workspace, surface, phone, hidden_at = self.hidden_with_phone("r5", hidden_ms)
        self.leave(workspace, surface, phone)
        time.sleep(0.5)
        self.report(workspace, surface, phone, 40, 12)
        try:
            decided = self.within("the returning phone to own the grid, the hidden Mac row not counting", surface,
                                  lambda state: (self.owns(phone)(state), self.mac_counts(False)(state)), 1.5)
            self.before_reveal(hidden_at, hidden_ms)
        finally:
            time.sleep(max(0.0, hidden_ms / 1000.0 - (time.monotonic() - hidden_at)) + 0.5)
        return {"decided": decided}

    def r6_fit_everyone_hidden_pane(self) -> Dict[str, Any]:
        hidden_ms = 3000
        workspace, surface = self.fresh("r6")
        viewer = self.client("r6-mac")
        self.set_mode(surface, "smallest")
        try:
            self.within("Fit everyone", surface, self.expect_mode("smallest"), 3)
            self.report(workspace, surface, viewer, 200, 60, kind="mac")
            self.within("the other Mac to join", surface, self.has_row("mobile:" + viewer, "the other Mac"), 3)
            self.portal_flicker(surface, hidden_ms)
            hidden_at = time.monotonic()
            self.within("the hidden Mac pane to stop counting", surface, self.mac_counts(False), 2)

            def viewer_grid(state: Dict[str, Any]) -> None:
                if self.grid(state) != (200, 60):
                    raise Failure(f"grid {self.grid(state)}, expected the viewing Mac's 200x60 while the pane is hidden")

            decided = self.within("the viewing Mac's 200x60 while the pane is hidden", surface, viewer_grid, 1.0)
            self.before_reveal(hidden_at, hidden_ms)
            time.sleep(max(0.0, hidden_ms / 1000.0 - (time.monotonic() - hidden_at)) + 0.5)
            after = self.snap("after the reveal", surface)
        finally:
            self.leave(workspace, surface, viewer)
            self.set_mode(surface, "latest")
        return {"decided": decided, "after_reveal": after}

    # -- R7-R8: the Mac's activity ----------------------------------------------------

    def r7_mac_activity_kept(self) -> Dict[str, Any]:
        workspace, surface = self.fresh("r7")
        phone = self.client("r7")
        self.phone_takes(workspace, surface, phone)
        mac_id = self.mac_id(surface)
        self.set_counts(surface, mac_id, False)
        self.within("the phone to own with the Mac row not counting", surface,
                    lambda state: (self.owns(phone)(state), self.mac_counts(False)(state)), 2)
        pressed = self.mac_types(workspace, surface)
        time.sleep(0.7)
        self.snap("after the key press", surface)
        self.report(workspace, surface, phone, 40, 12)
        time.sleep(0.3)
        self.set_counts(surface, mac_id, None)
        decided = self.within("the Mac pane (newest by its key press) to own the grid", surface, self.mac_owns(), 3)
        return {"pressed": pressed, "decided": decided}

    def screen_text(self, workspace_id: str, surface_id: str) -> str:
        reply = self.sock.call("surface.read_text", {"workspace_id": workspace_id, "surface_id": surface_id}) or {}
        return str(reply.get("text") or "")

    def scroll_delivered(self, workspace_id: str, surface_id: str, before: str) -> bool:
        """The posted wheel event reached the terminal: its viewport moved into the scrollback."""
        try:
            wait_for("the scroll to move the terminal's viewport",
                     lambda: self.screen_text(workspace_id, surface_id) != before, 1.5, interval_s=0.1)
            return True
        except Failure:
            return False

    def r8_mac_scroll_is_activity(self) -> Dict[str, Any]:
        workspace, surface = self.fresh("r8")
        phone = self.client("r8")
        self.phone_takes(workspace, surface, phone)
        # Scrollback to scroll into (socket input: not the Mac's user, so the phone keeps the grid).
        self.sock.call("surface.send_text", {"workspace_id": workspace, "surface_id": surface,
                                             "text": "seq 1 200\n"})
        wait_for("the scrollback to fill", lambda: "200" in self.screen_text(workspace, surface), 5, interval_s=0.2)
        self.within("the phone to still own the grid after the socket input", surface, self.owns(phone), 2)
        for attempt in (1, 2):
            activations = self.mac_activations()
            before = self.screen_text(workspace, surface)
            scrolled = self.note("local_scroll", self.sock.call(
                SIZING + "local_scroll", {"surface_id": surface, "lines": 5}) or {})
            # Harness checks: the wheel event must really reach the terminal, or this step proves nothing.
            if not scrolled.get("hits_terminal"):
                raise Failure(f"harness: the scroll event's location is not over the terminal: {scrolled}")
            if not self.scroll_delivered(workspace, surface, before):
                raise Failure(f"harness: the posted scroll never reached the terminal (its viewport did not move): "
                              f"{scrolled}")
            decided = self.within("a scroll on the Mac pane (delivered: the viewport moved) to give it the grid",
                                  surface, self.mac_owns(), 3)
            if self.mac_activations() == activations:
                return {"scroll": scrolled, "decided": decided, "attempt": attempt}
            # The app became active meanwhile (the Mac's own activity): try again.
            self.phone_retakes(workspace, surface, phone)
        raise Failure("the app became active around both scrolls; the scroll itself was not shown")

    # -- R9: a scene-phase leave is soft ------------------------------------------------

    def r9_soft_leave(self) -> Dict[str, Any]:
        workspace, surface = self.fresh("r9")
        phone = self.client("r9")
        self.phone_takes(workspace, surface, phone)
        mac = self.mac_grid(surface)

        def ensure_phone() -> None:
            if self.row(self.state(surface), "mobile:" + phone) and self.surface_grid(surface) == PHONE:
                return
            self.phone_takes(workspace, surface, phone)

        def transient_return() -> Dict[str, Any]:
            ensure_phone()
            samples: List[Dict[str, Any]] = []
            origin = time.monotonic()
            self.leave(workspace, surface, phone, transient=True)
            self.sample_grids(surface, 1.0, samples, origin)
            self.report(workspace, surface, phone, 40, 12)
            self.sample_grids(surface, 2.5, samples, origin)
            self.trace.append({"t": self.elapsed(), "label": "soft leave and return", "samples": samples})
            moved = [s for s in samples if s["grid"] != list(PHONE)]
            if moved:
                raise Failure(f"the live grid left 40x12 during a soft leave and return: {moved[:5]}")
            decided = self.within("the returning phone to own the grid", surface, self.owns(phone), 1)
            return {"samples": len(samples), "decided": decided}

        def transient_no_return() -> Dict[str, Any]:
            ensure_phone()
            self.leave(workspace, surface, phone, transient=True)
            return {"restored": self.wait_grid(surface, mac, 3.5, "the Mac grid after a soft leave")}

        def hard_leave() -> Dict[str, Any]:
            ensure_phone()
            self.leave(workspace, surface, phone)
            return {"restored": self.wait_grid(surface, mac, 1.0, "the Mac grid after an explicit leave")}

        self.check("transient_return", transient_return)
        self.check("transient_no_return", transient_no_return)
        self.check("hard_leave", hard_leave)
        return {"mac_grid": list(mac)}

    # -- R10: this Mac's user's selection ---------------------------------------------

    def hidden_terminal(self, label: str) -> Tuple[str, str]:
        """A new workspace that is not selected, its terminal's host already made."""
        workspace = self.create_workspace(label)
        surface = wait_for(f"the {label} terminal", lambda: self.surfaces(workspace), self.timeout)[0]
        self.wait_state(f"the {label} terminal's size state", surface, self.has_row("mac:", "the Mac pane"))
        self.no_mirror_row(label, surface)
        return workspace, surface

    def r10_mac_selection_keeps_grid(self) -> Dict[str, Any]:
        def mac_user_selection() -> Dict[str, Any]:
            workspace, surface = self.hidden_terminal("r10")
            phone = self.client("r10")
            selected = self.note("local_select", self.sock.call(
                SIZING + "local_select", {"workspace_id": workspace, "surface_id": surface}) or {})
            chosen_at = time.monotonic()
            self.within("the selected pane to count", surface, self.mac_counts(True), 2)
            mac = self.mac_grid(surface)
            self.report(workspace, surface, phone, 40, 12)
            attached_after = round(time.monotonic() - chosen_at, 2)
            self.within("the phone to join", surface, self.has_row("mobile:" + phone, "the phone"), 2)
            self.snap("the phone attached after this Mac's user selected", surface)
            held = self.keeps("the Mac pane keeps the grid (this Mac's user selected it; the phone only attached)",
                              surface, self.mac_owns(), 2.0)
            live = self.wait_grid(surface, mac, 0.5, "the live grid to stay the Mac grid")
            self.viewer_types(workspace, surface, phone)
            typed = self.within("typing on the phone to give it the grid", surface, self.owns(phone), 5)
            return {"selected": selected, "attached_after_s": attached_after, **held, "live": live, "typed": typed}

        def socket_selection() -> Dict[str, Any]:
            workspace, surface = self.hidden_terminal("r10g")
            phone = self.client("r10g")
            self.select(workspace)
            self.within("the selected pane to count", surface, self.mac_counts(True), 3)
            self.report(workspace, surface, phone, 40, 12)
            return {"decided": self.within("the phone attaching after a socket selection to own the grid",
                                           surface, self.owns(phone), 2)}

        self.check("mac_user_selection", mac_user_selection)
        self.check("socket_selection", socket_selection)
        return {}

    # -- R13b: activation with the TextBox focused ------------------------------------

    def r13b_activation_with_textbox(self) -> Dict[str, Any]:
        workspace, surface = self.fresh("r13b")
        phone = self.client("r13b")
        self.phone_takes(workspace, surface, phone)
        activated = self.note("activate (textbox)", self.sock.call(
            SIZING + "activate", {"surface_id": surface, "textbox": True}) or {})
        if not activated.get("textbox_focused"):
            raise Failure(f"the TextBox did not take focus: {activated}")
        decided = self.within("switching to the app with the TextBox focused to give the Mac the grid", surface,
                              self.mac_owns(), 2)
        return {"activated": activated, "decided": decided}

    # -- R14: a connection close clears only its own reports --------------------------

    def r14_connection_scoped_clear(self) -> Dict[str, Any]:
        workspace, surface = self.fresh("r14")
        phone = self.client("r14")
        older, newer = str(uuid.uuid4()), str(uuid.uuid4())

        def stamped_reports() -> Dict[str, Any]:
            self.connection_request(older, "mobile.terminal.viewport",
                                    self.viewport_params(workspace, surface, phone, 40, 12))
            self.within("the phone (connection A) to own the grid", surface, self.owns(phone), 3)
            # The phone reconnected: its newer connection sends the report again.
            self.connection_request(newer, "mobile.terminal.viewport",
                                    self.viewport_params(workspace, surface, phone, 40, 12))
            time.sleep(0.3)
            closed = self.note("connection A closed", self.connection_close(older))
            self.snap("connection A closed", surface)
            held = self.keeps("the phone keeps the grid after its older connection A closed (B re-sent its report)",
                              surface, self.owns(phone), 2.0)
            return {"closed": closed, **held}

        def own_connection_close() -> Dict[str, Any]:
            if not self.row(self.state(surface), "mobile:" + phone):
                self.connection_request(newer, "mobile.terminal.viewport",
                                        self.viewport_params(workspace, surface, phone, 40, 12))
                self.within("the phone (connection B) to own the grid", surface, self.owns(phone), 3)
            self.connection_close(newer)
            return {"decided": self.within("the phone to leave with the connection that wrote its report",
                                           surface, self.not_participant(phone), 1.5)}

        def unstamped_report() -> Dict[str, Any]:
            phone2 = self.client("r14-socket")
            self.phone_takes(workspace, surface, phone2)
            self.connection_close(str(uuid.uuid4()), client_id=phone2)
            return {"decided": self.within("a closing connection of its client to clear a control-socket report",
                                           surface, self.not_participant(phone2), 1.5)}

        self.check("stamped_reports", stamped_reports)
        self.check("own_connection_close", own_connection_close)
        self.check("unstamped_report", unstamped_report)
        return {}

    # -- R15: typing over the IRX input lane --------------------------------------------

    def r15_lane_input(self) -> Dict[str, Any]:
        def lane_activity() -> Dict[str, Any]:
            workspace, surface = self.fresh("r15")
            phone, connection = self.client("r15"), str(uuid.uuid4())
            self.phone_takes(workspace, surface, phone)
            self.mac_types(workspace, surface)
            self.within("the Mac pane to take the grid back", surface, self.mac_owns(), 5)
            typed = self.note("lane_input", self.lane_input(surface, phone, connection, " "))
            if not typed.get("delivered"):
                raise Failure(f"the lane refused an attached phone's input: {typed}")
            decided = self.within("typing on the phone's input lane to give it the grid", surface, self.owns(phone), 2)
            return {"typed": typed, "decided": decided}

        def detached_lane_refused() -> Dict[str, Any]:
            workspace, surface = self.fresh("r15d")
            phone, connection = self.client("r15d"), str(uuid.uuid4())
            self.phone_takes(workspace, surface, phone)
            self.sock.call("terminal.participant.disconnect",
                           {"surface_id": surface, "participant_id": "mobile:" + phone})
            self.within("the disconnected phone to leave", surface, self.not_participant(phone), 2)
            marker = "zq" + self.nonce
            typed = self.note("lane_input (disconnected)", self.lane_input(surface, phone, connection, marker))
            time.sleep(1.0)
            screen = self.sock.call("surface.read_text", {"workspace_id": workspace, "surface_id": surface}) or {}
            reached = marker in str(screen.get("text") or "")
            if typed.get("delivered") or reached:
                raise Failure(f"a disconnected phone's lane input was delivered (delivered={typed.get('delivered')}, "
                              f"on screen={reached})")
            return {"typed": typed, "on_screen": reached}

        self.check("lane_activity", lane_activity)
        self.check("detached_lane_refused", detached_lane_refused)
        return {}

    # -- R16: the replay's claim is sticky ----------------------------------------------

    def r16_sticky_replay_claim(self) -> Dict[str, Any]:
        workspace, surface = self.fresh("r16")
        phone = self.client("r16")
        params = self.viewport_params(workspace, surface, phone, 40, 12)

        def replay() -> bool:
            self.sock.call("mobile.terminal.replay", params, timeout_s=30)
            return True

        wait_for("the phone's replay with its viewport", replay, 10, interval_s=0.5)
        attached = self.within("the phone attaching by its replay to own the grid", surface, self.owns(phone), 3)
        self.snap("attached by replay", surface)
        held = self.keeps("the phone attached by its replay keeps the grid (a sticky claim, TTL 5 s)",
                          surface, self.owns(phone), 8.0)
        return {"attached": attached, **held}

    # -- R17: Fixed seeds from the Mac pane ---------------------------------------------

    def r17_fixed_seed(self) -> Dict[str, Any]:
        def fixed_is(want: Grid) -> Callable[[Dict[str, Any]], None]:
            def check(state: Dict[str, Any]) -> None:
                policy = self.policy(state)
                if policy["mode"] != "fixed" or grid_of(policy["fixed"]) != want:
                    raise Failure(f"policy {policy}, expected Fixed at the Mac pane's {want} (not the phone's 40x12)")
            return check

        def socket_path() -> Dict[str, Any]:
            workspace, surface = self.fresh("r17")
            phone = self.client("r17")
            self.phone_takes(workspace, surface, phone)
            mac = self.mac_grid(surface)
            try:
                self.set_mode(surface, "fixed")
                return {"decided": self.within("Fixed seeded from the Mac pane", surface, fixed_is(mac), 2)}
            finally:
                self.set_mode(surface, "latest")

        def panel_path() -> Dict[str, Any]:
            workspace, surface = self.fresh("r17p")
            phone = self.client("r17p")
            self.phone_takes(workspace, surface, phone)
            mac = self.mac_grid(surface)
            try:
                chosen = self.select_mode(surface, "fixed")
                decided = self.within("Fixed (size panel) seeded from the Mac pane", surface, fixed_is(mac), 2)
                return {"accepted": chosen.get("accepted"), "decided": decided, "preference": self.preference()}
            finally:
                self.sock.call(SIZING + "reset", {})

        self.check("socket_path", socket_path)
        self.check("panel_path", panel_path)
        return {}

    # -- R18: the user's report, end to end ----------------------------------------------

    def r18_composite_return(self) -> Dict[str, Any]:
        workspace, surface = self.fresh("r18")
        away = self.create_workspace("r18-away")
        phone = self.client("r18")
        self.phone_takes(workspace, surface, phone)
        mac = self.mac_grid(surface)
        self.select(away)
        self.within("the hidden Mac pane to stop counting", surface, self.mac_counts(False), 3)
        # The phone's keyboard goes down and it locks, inside one 400 ms window.
        self.report(workspace, surface, phone, 40, 8)
        self.leave(workspace, surface, phone)
        self.within("the phone to leave", surface, self.not_participant(phone), 2)
        self.snap("the phone left while the pane was hidden", surface)

        def mac_grid_on_return() -> Dict[str, Any]:
            self.select(workspace)
            restored = self.wait_grid(surface, mac, 1.0, "the Mac grid once the Mac shows the terminal again")
            decided = self.within("the Mac pane to own the grid", surface, self.mac_owns(), 1)
            return {"restored": restored, "decided": decided, "live_grid": self.confirm_live(workspace, surface, mac)}

        def size_to_me_is_a_no_op() -> Dict[str, Any]:
            self.size_to_me(surface)
            time.sleep(0.5)
            decided = self.within("the Mac pane to still own the grid", surface, self.mac_owns(), 1)
            return {"decided": decided, "still": self.wait_grid(surface, mac, 0.2, "the live grid to stay the Mac grid")}

        def governor_settled() -> Dict[str, Any]:
            governor = self.governor(surface).get("governor")
            if governor and governor.get("flush_scheduled") and governor.get("staged") is None:
                raise Failure(f"the governor is wedged: a flush is marked scheduled with nothing staged ({governor})")
            return {"governor": governor}

        def phone_returns_and_rotates() -> Dict[str, Any]:
            self.report(workspace, surface, phone, 40, 12)
            back = self.wait_grid(surface, PHONE, 2.0, "the returning phone's 40x12")
            self.report(workspace, surface, phone, 60, 20)
            rotated = self.wait_grid(surface, (60, 20), 1.5, "the rotated phone's 60x20")
            return {"back": back, "rotated": rotated}

        self.check("mac_grid_on_return", mac_grid_on_return)
        self.check("size_to_me_is_a_no_op", size_to_me_is_a_no_op)
        self.check("governor_settled", governor_settled)
        self.check("phone_returns_and_rotates", phone_returns_and_rotates)
        return {"mac_grid": list(mac)}

    # -- R11-R13: Mac to Mac (the loopback's mirror) ------------------------------------

    def r12_mirror_size_to_me(self) -> Dict[str, Any]:
        self.ensure_mirror()
        phone = self.client("r12")

        def from_auto() -> Dict[str, Any]:
            self.phone_takes(self.source_id, self.source_surface, phone)
            self.size_to_me(self.mirror_surface)
            return {"decided": self.within("Size to My Window on the mirror to give it the grid",
                                           self.source_surface, self.owned_by(MIRROR_PREFIX), 2)}

        def from_fit_everyone() -> Dict[str, Any]:
            # The phone attaches again (the newest), then the terminal goes to Fit everyone.
            self.leave(self.source_id, self.source_surface, phone)
            self.within("the phone to leave", self.source_surface, self.not_participant(phone), 3)
            self.phone_takes(self.source_id, self.source_surface, phone)
            self.set_mode(self.source_surface, "smallest")
            self.within("Fit everyone", self.source_surface, self.expect_mode("smallest"), 3)
            self.size_to_me(self.mirror_surface)
            return {"decided": self.within("Size to My Window on the mirror (from Fit everyone) to give it the grid",
                                           self.source_surface, self.owned_by(MIRROR_PREFIX), 2)}

        try:
            self.check("from_auto", from_auto)
            self.check("from_fit_everyone", from_fit_everyone)
        finally:
            self.leave(self.source_id, self.source_surface, phone)
            self.set_mode(self.source_surface, "latest")
        return {}

    def r13_mirror_activation(self) -> Dict[str, Any]:
        self.ensure_mirror()
        phone = self.client("r13")
        try:
            self.phone_takes(self.source_id, self.source_surface, phone)
            activated = self.note("activate (mirror)", self.sock.call(
                SIZING + "activate", {"surface_id": self.mirror_surface}) or {})
            decided = self.within("switching to the app with the mirror focused to give the mirror the grid",
                                  self.source_surface, self.owned_by(MIRROR_PREFIX), 2)
        finally:
            self.leave(self.source_id, self.source_surface, phone)
        return {"activated": activated, "decided": decided}

    def r11_mirror_generation_reset(self) -> Dict[str, Any]:
        self.ensure_mirror()
        phone = self.client("r11")
        # Raise the source terminal's generation well above where a fresh host starts.
        for cols in range(40, 52):
            self.report(self.source_id, self.source_surface, phone, cols, 12)
        self.leave(self.source_id, self.source_surface, phone)
        self.within("the phone to leave", self.source_surface, self.not_participant(phone), 3)
        local = self.create_workspace("r11-local")
        self.select(local)
        self.within("the hidden mirror to stop counting", self.source_surface, self.mirror_counts(False), 5)
        before = self.snap("mirror hidden, before the relaunch", self.source_surface)
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        try:
            wait_for("the loopback link to drop", lambda: self.device().get("link_state") != "connected", self.timeout)
            reset = self.note("reset_hosts", self.sock.call(SIZING + "reset_hosts", {}) or {})
        finally:
            self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        wait_for("the loopback link to reconnect", lambda: self.device().get("link_state") == "connected", self.timeout)
        self.wait_state("the mirror to join the restarted host", self.source_surface,
                        self.has_row(MIRROR_PREFIX, "the mirror"))
        self.snap("the mirror re-joined", self.source_surface)

        def hidden_and_not_owner(state: Dict[str, Any]) -> None:
            self.mirror_counts(False)(state)
            mirror = self.row(state, MIRROR_PREFIX)
            if mirror and mirror["id"] in (state.get("owners") or []):
                raise Failure(f"the hidden mirror owns the grid: owners {state.get('owners')}")

        held = self.keeps("the hidden mirror stays non-counting and not the owner after the host restarted",
                          self.source_surface, hidden_and_not_owner, 3.0)
        return {"before": before, "reset": reset, **held}

    # -- run ------------------------------------------------------------------------------

    def plan(self) -> List[Tuple[str, Callable[[], Optional[Dict[str, Any]]]]]:
        return [
            ("R1_governor_wedge", self.r1_governor_wedge),
            ("R2_wedge_then_held", self.r2_wedge_then_held),
            ("R3_size_to_me_forces", self.r3_size_to_me_forces),
            ("R4_departed_viewer_hidden_pane", self.r4_departed_viewer_hidden_pane),
            ("R5_hidden_pane_viewer_returns", self.r5_hidden_pane_viewer_returns),
            ("R6_fit_everyone_hidden_pane", self.r6_fit_everyone_hidden_pane),
            ("R7_mac_activity_kept", self.r7_mac_activity_kept),
            ("R8_mac_scroll_is_activity", self.r8_mac_scroll_is_activity),
            ("R9_soft_leave", self.r9_soft_leave),
            ("R10_mac_selection_keeps_grid", self.r10_mac_selection_keeps_grid),
            ("R13b_activation_with_textbox", self.r13b_activation_with_textbox),
            ("R14_connection_scoped_clear", self.r14_connection_scoped_clear),
            ("R15_lane_input", self.r15_lane_input),
            ("R16_sticky_replay_claim", self.r16_sticky_replay_claim),
            ("R17_fixed_seed", self.r17_fixed_seed),
            ("R18_composite_return", self.r18_composite_return),
            ("R12_mirror_size_to_me", self.r12_mirror_size_to_me),
            ("R13_mirror_activation", self.r13_mirror_activation),
            # Last: it resets every sizing host of this app.
            ("R11_mirror_generation_reset", self.r11_mirror_generation_reset),
        ]

    def cleanup(self) -> None:
        for connection_id in list(self.connections):
            try:
                self.connection_close(connection_id)
            except (Failure, OSError) as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))
        try:
            self.set_auto_mirror(True)
        except (Failure, OSError) as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))
        super().cleanup()

    def run(self) -> bool:
        ok = self.step("setup", self.setup)
        if ok:
            self.set_auto_mirror(False)
            for name, action in self.plan():
                ok = self.step(name, action) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait before a set-up wait gives up")
    parser.add_argument("--app-path", help="unused (accepted for the runner's common arguments)")
    parser.add_argument("--projects-file", help="unused (accepted for the runner's common arguments)")
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
        test = SizingRecoveryE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-terminal-sizing-recovery-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = (Path(args.report) if args.report
                   else ARTIFACTS_DIR / f"loopback_terminal_sizing_recovery_e2e-{args.tag or 'socket'}.json")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": passed, "steps": [{"name": s.get("name"), "ok": s.get("ok"),
                                                   "error": s.get("error")} for s in steps]}, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
