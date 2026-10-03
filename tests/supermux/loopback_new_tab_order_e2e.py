#!/usr/bin/env python3
"""End-to-end test: a new terminal tab lands at the END of the tab strip, on both Macs.

Upstream inserted a new tab right after the pane's SELECTED tab. A remote
workspace's tabs are created on the Mac that owns it, unfocused, and that Mac's
selection never follows the viewer: on a headless Mac it stays on the first tab.
So every new tab opened from a mirror (Cmd+T, the tab bar's +, the phone, the
CLI) landed at index 1 on both Macs, and "New Terminal to the Right" in a mirror
ignored its tab. This suite drives each entry point against one tagged DEBUG
build running the loopback device ("Loopback Mac" = this same app's own mobile
host), so the source workspace is "the other Mac" and its auto mirror is the
viewer:

  1. setup                               auto-mirror on, the loopback linked and fetched
  2. source_and_mirror                   a background source workspace and its one mirror
  3. host_socket_new_tabs_append         surface.create twice in the source: [T0, T1, T2]
                                         (the source's pane stays on T0, the headless state)
  4. host_phone_new_tab_appends          mobile.terminal.create over the device link (the
                                         phone, the sidebar's New Terminal, presets)
  5. mirror_cmd_t_from_last_tab_appends  Cmd+T in the mirror's last tab
  6. mirror_cmd_t_from_first_tab_appends Cmd+T in the mirror's first tab
  7. mirror_plus_button_appends          the mirror's tab bar +
  8. mirror_socket_new_tab_appends       surface.create on the mirror (routed to the source)
  9. mirror_new_terminal_to_right        the tab menu's "New Terminal to the Right" on the
                                         mirror's 2nd tab: right of it, on both sides
 10. mirror_socket_new_terminal_right    tab.action new_terminal_right on the mirror's 3rd tab
 11. mirror_terminal_right_retry_after_lost_reply
                                         "New Terminal to the Right" whose reply is lost
                                         after the source placed the tab (DEBUG fault); the
                                         reserved pane's Retry, with this Mac's capability
                                         cache cold as after a reconnect, must resend the
                                         same params and get that terminal back (the source
                                         answers a changed retry "Request ID was reused")
 12. local_workspace                     a focused local workspace with three tabs, mirrored
 13. local_cmd_t_appends                 Cmd+T in the local workspace's first tab
 14. local_plus_button_appends           its tab bar + with the first tab focused
 15. local_new_terminal_to_right         "New Terminal to the Right" locally still lands
                                         right of its tab
 16. failed_mirror_tab_not_restored_locally
                                         (--app-path) the mirror's + while the link is down:
                                         the reserved pane fails with Mac wording (names the
                                         Mac, never "Cloud"); after a quit and relaunch the
                                         mirror holds only the owner's terminals, never that
                                         pane restored as a local shell

After every create the suite waits for exactly one new terminal on the owning
side, checks its order, waits for the mirror to show the same order (read as
source ids through surface.catalog), then re-checks both 1.5 s later so a late
layout re-apply is caught. Writes a JSON report (default
tests/supermux/artifacts/loopback_new_tab_order_e2e-<tag>.json) with every
before/after order, the owning pane's selected tab and the latency, and exits
non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_new_tab_order_e2e.py [--timeout 30] [--keep] [--report PATH]
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
SETTLE_SECONDS = 1.5


class Failure(Exception):
    """A check failed; the message says which and why."""


class Skipped(Exception):
    """A step that cannot run in this invocation (it says why)."""


class RateLimited(Exception):
    """The socket's polling limiter refused a read; retry after the hint."""

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


def wait_for(description: str, probe: Callable[[], Any], timeout_s: float, interval_s: float = 0.2) -> Any:
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


def appended(before: List[str], new: str) -> List[str]:
    """Where every plain new tab must go: the end."""
    return before + [new]


def right_of(index: int) -> Callable[[List[str], str], List[str]]:
    """Where "New Terminal to the Right" of the tab at `index` must go."""
    return lambda before, new: before[: index + 1] + [new] + before[index + 1:]


class Pair:
    """A workspace that owns its terminals and the mirror that shows them."""

    def __init__(self, label: str, owner: str, mirror: str) -> None:
        self.label = label
        self.owner = owner
        self.mirror = mirror


class NewTabOrderE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.keep = args.keep
        self.nonce = uuid.uuid4().hex[:6]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.machine = ""
        self.remote: Optional[Pair] = None
        self.local: Optional[Pair] = None

    # -- reads ----------------------------------------------------------------

    def device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device in supermux.devices.list (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def mirrors_of(self, owner_id: str) -> List[Dict[str, Any]]:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        return [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(owner_id)]

    def panes(self, workspace_id: str) -> List[Dict[str, Any]]:
        return (self.sock.call("pane.list", {"workspace_id": workspace_id}) or {}).get("panes") or []

    def order(self, workspace_id: str) -> List[str]:
        """Every surface in pane order, then tab order inside each pane."""
        return [up(surface) for pane in self.panes(workspace_id) for surface in pane.get("surface_ids") or []]

    def selected(self, workspace_id: str) -> List[str]:
        """Each pane's selected tab (the owning Mac's `.current` anchor)."""
        return [up(pane.get("selected_surface_id")) for pane in self.panes(workspace_id)]

    def projections(self, mirror_id: str) -> Dict[str, str]:
        """Mirror panel id -> the owner terminal id it projects."""
        return {
            up(p.get("panel_id")): up(str(p.get("resource", "")).rsplit("/", 1)[-1])
            for p in (self.sock.call("surface.catalog", {}) or {}).get("projections") or []
            if up(p.get("workspace_id")) == up(mirror_id) and str(p.get("resource", "")).startswith(self.machine)
        }

    def mirror_order(self, pair: Pair) -> List[str]:
        """The mirror's tab order, as the owner terminal ids its panels project."""
        projections = self.projections(pair.mirror)
        return [projections.get(panel, f"local:{panel}") for panel in self.order(pair.mirror)]

    def mirror_panel(self, pair: Pair, index: int) -> str:
        """The mirror panel at `index` of its tab strip."""
        panels = self.order(pair.mirror)
        if index >= len(panels):
            raise Failure(f"the mirror has no tab {index}: {panels}")
        return panels[index]

    # -- actions --------------------------------------------------------------

    def keyboard_focus(self, workspace_id: str, surface_id: str) -> None:
        """Makes `surface_id` the app's first responder, as a click would."""
        self.sock.call("workspace.select", {"workspace_id": workspace_id})
        self.sock.call("surface.focus", {"workspace_id": workspace_id, "surface_id": surface_id})
        self.sock.call("debug.app.activate", {})

        def focused() -> bool:
            result = self.sock.call("debug.terminal.is_focused", {"surface_id": surface_id}) or {}
            if not result.get("focused"):
                self.sock.call("surface.focus", {"workspace_id": workspace_id, "surface_id": surface_id})
            return bool(result.get("focused"))

        wait_for(f"{surface_id} to take keyboard focus", focused, self.timeout)
        time.sleep(0.5)

    def cmd_t(self) -> None:
        self.sock.call("debug.shortcut.simulate", {"combo": "cmd+t"})

    def plus_button(self, workspace_id: str) -> None:
        self.sock.call("supermux.devices.mirror.tab_bar_new_tab", {"workspace_id": workspace_id})

    def tab_menu_terminal_to_right(self, workspace_id: str, surface_id: str) -> None:
        self.sock.call("supermux.devices.mirror.tab_context_action", {
            "workspace_id": workspace_id, "surface_id": surface_id, "action": "newTerminalToRight",
        })

    def socket_new_tab(self, workspace_id: str) -> None:
        self.sock.call("surface.create", {"workspace_id": workspace_id, "type": "terminal"})

    def pending_creations(self, workspace_id: str) -> List[Dict[str, Any]]:
        """Reserved panes still waiting for their terminal (`failure` set once one failed)."""
        return (self.sock.call("supermux.devices.mirror.pending_creations",
                               {"workspace_id": workspace_id}) or {}).get("pending") or []

    # -- the order check ------------------------------------------------------

    def one_new_terminal(self, pair: Pair, before: List[str]) -> str:
        """Waits for exactly one terminal more than `before` in the owner."""
        def one_new() -> Optional[str]:
            now = self.order(pair.owner)
            fresh = [s for s in now if s not in before]
            if len(fresh) > 1:
                raise Failure(f"{len(fresh)} new terminals: {fresh}")
            return fresh[0] if fresh and len(now) == len(before) + 1 else None

        return wait_for(f"one new terminal in the {pair.label} owner", one_new, self.timeout)

    def new_tab(self, pair: Pair, trigger: Callable[[], None],
                expected: Callable[[List[str], str], List[str]] = appended) -> Dict[str, Any]:
        """Runs `trigger`, then checks where the one new terminal landed on both sides."""
        before = self.order(pair.owner)

        def mirror_matches_before() -> bool:
            mirror = self.mirror_order(pair)
            if mirror != before:
                raise Failure(f"mirror {mirror} != owner {before}")
            return True

        wait_for(f"the {pair.label} mirror to match its owner before the create", mirror_matches_before, self.timeout)
        record: Dict[str, Any] = {
            "owner_before": before,
            "mirror_before": self.mirror_order(pair),
            "owner_selected_before": self.selected(pair.owner),
        }
        started = time.monotonic()
        trigger()
        new = self.one_new_terminal(pair, before)
        want = expected(before, new)
        record.update(new_terminal=new, expected=want, new_index_expected=want.index(new))
        owner = self.order(pair.owner)
        record.update(owner_after=owner, new_index_owner=owner.index(new) if new in owner else None)

        def mirror_follows() -> bool:
            mirror = self.mirror_order(pair)
            if mirror != owner:
                raise Failure(f"mirror {mirror} != owner {owner}")
            return True

        mirror_error: Optional[str] = None
        try:
            wait_for(f"the {pair.label} mirror to show the owner's order", mirror_follows, self.timeout, interval_s=0.1)
        except Failure as error:
            mirror_error = str(error)
        record["latency_seconds"] = round(time.monotonic() - started, 3)
        mirror = self.mirror_order(pair)
        record.update(mirror_after=mirror, new_index_mirror=mirror.index(new) if new in mirror else None)
        if owner != want:
            raise Failure(f"owner order {owner} != expected {want} (new tab at {record['new_index_owner']}, "
                          f"expected {record['new_index_expected']}); record={json.dumps(record)}")
        if mirror_error:
            raise Failure(f"{mirror_error}; record={json.dumps(record)}")

        time.sleep(SETTLE_SECONDS)
        owner_late, mirror_late = self.order(pair.owner), self.mirror_order(pair)
        record.update(owner_settled=owner_late, mirror_settled=mirror_late, owner_selected_after=self.selected(pair.owner))
        if owner_late != want or mirror_late != want:
            raise Failure(f"{SETTLE_SECONDS}s later: owner {owner_late}, mirror {mirror_late}, expected {want}; "
                          f"record={json.dumps(record)}")
        return record

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
        except Failure as error:
            record["ok"] = False
            record["error"] = str(error)
        record["seconds"] = round(time.monotonic() - started, 2)
        self.steps.append(record)
        label = {True: "PASS", False: "FAIL", None: "SKIP"}[record["ok"]]
        detail = record.get("error") or record.get("skipped")
        print(f"{label} {name} ({record['seconds']}s){': ' + detail if detail else ''}", file=sys.stderr)
        return record["ok"] is not False

    def setup(self) -> Dict[str, Any]:
        state = self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True}) or {}

        def ready() -> Optional[Dict[str, Any]]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        self.machine = wait_for("the loopback device to connect", ready, self.timeout)["machine"]
        self.facts["machine"] = self.machine
        return {"machine": self.machine, "auto_mirror": state.get("auto_mirror")}

    def owner_with_mirror(self, label: str, focus: bool) -> Pair:
        title = f"new-tab-order-{label}-{self.nonce}"
        created = self.sock.call("workspace.create", {"title": title, "focus": focus}) or {}
        owner = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not owner:
            raise Failure(f"workspace.create returned no id: {created}")
        self.sock.call("workspace.rename", {"workspace_id": owner, "title": title})

        def one_mirror() -> Optional[Dict[str, Any]]:
            mirrors = self.mirrors_of(owner)
            if len(mirrors) > 1:
                raise Failure(f"{len(mirrors)} mirrors of {owner}")
            return mirrors[0] if mirrors else None

        mirror = up(wait_for(f"the auto-mirror of the {label} workspace", one_mirror, self.timeout)["workspace_id"])
        pair = Pair(label, owner, mirror)
        first = wait_for(f"the {label} workspace's first terminal", lambda: self.order(owner), self.timeout)
        wait_for(f"the {label} mirror to project its first terminal", lambda: self.mirror_order(pair) == first, self.timeout)
        self.facts[f"{label}_owner"] = owner
        self.facts[f"{label}_mirror"] = mirror
        return pair

    def source_and_mirror(self) -> Dict[str, Any]:
        self.remote = self.owner_with_mirror("remote", focus=False)
        return {"source": self.remote.owner, "mirror": self.remote.mirror, "tabs": self.order(self.remote.owner)}

    def host_socket_new_tabs_append(self) -> Dict[str, Any]:
        pair = self.need(self.remote)
        first = self.new_tab(pair, lambda: self.socket_new_tab(pair.owner))
        second = self.new_tab(pair, lambda: self.socket_new_tab(pair.owner))
        return {"first": first, "second": second}

    def host_phone_new_tab_appends(self) -> Dict[str, Any]:
        pair = self.need(self.remote)

        def phone() -> None:
            self.sock.call("supermux.devices.request", {
                "machine": self.machine, "method": "mobile.terminal.create",
                "params": {"workspace_id": pair.owner}, "timeout_seconds": 30,
            }, timeout_s=40)

        return self.new_tab(pair, phone)

    def mirror_cmd_t(self, index: Optional[int]) -> Callable[[], Dict[str, Any]]:
        def run() -> Dict[str, Any]:
            pair = self.need(self.remote)
            panels = self.order(pair.mirror)
            panel = panels[-1] if index is None else self.mirror_panel(pair, index)
            self.keyboard_focus(pair.mirror, panel)
            return {"focused_mirror_panel": panel, **self.new_tab(pair, self.cmd_t)}
        return run

    def mirror_plus_button_appends(self) -> Dict[str, Any]:
        pair = self.need(self.remote)
        self.sock.call("workspace.select", {"workspace_id": pair.mirror})
        return self.new_tab(pair, lambda: self.plus_button(pair.mirror))

    def mirror_socket_new_tab_appends(self) -> Dict[str, Any]:
        pair = self.need(self.remote)
        return self.new_tab(pair, lambda: self.socket_new_tab(pair.mirror))

    def mirror_new_terminal_to_right(self) -> Dict[str, Any]:
        pair = self.need(self.remote)
        self.sock.call("workspace.select", {"workspace_id": pair.mirror})
        anchor = self.mirror_panel(pair, 1)
        record = self.new_tab(pair, lambda: self.tab_menu_terminal_to_right(pair.mirror, anchor), right_of(1))
        return {"anchor_mirror_panel": anchor, **record}

    def mirror_socket_new_terminal_right(self) -> Dict[str, Any]:
        pair = self.need(self.remote)
        anchor = self.mirror_panel(pair, 2)

        def action() -> None:
            self.sock.call("tab.action", {
                "workspace_id": pair.mirror, "surface_id": anchor, "action": "new_terminal_right",
            })

        return {"anchor_mirror_panel": anchor, **self.new_tab(pair, action, right_of(2))}

    def mirror_terminal_right_retry_after_lost_reply(self) -> Dict[str, Any]:
        """A positioned create whose reply is lost; its Retry must get the same terminal back.

        The source stores a receipt per request id and answers a retry whose params
        differ with "Request ID was reused for another edit". The retry runs with this
        Mac's capability cache emptied, as right after a reconnect, so a retry that
        re-decides `after_surface_id` from that cache drops it and fails for good.
        """
        pair = self.need(self.remote)
        self.sock.call("workspace.select", {"workspace_id": pair.mirror})
        anchor = self.mirror_panel(pair, 1)
        before = self.order(pair.owner)
        wait_for(f"the {pair.label} mirror to match its owner before the create",
                 lambda: self.mirror_order(pair) == before, self.timeout)
        self.sock.call("supermux.devices.mirror.lose_next_create_reply", {})
        self.tab_menu_terminal_to_right(pair.mirror, anchor)
        new = self.one_new_terminal(pair, before)
        want = right_of(1)(before, new)
        record: Dict[str, Any] = {"anchor_mirror_panel": anchor, "owner_before": before,
                                  "new_terminal": new, "expected": want}
        owner = self.order(pair.owner)
        if owner != want:
            raise Failure(f"first attempt: owner order {owner} != expected {want}; record={json.dumps(record)}")

        def failed() -> List[Dict[str, Any]]:
            return [p for p in self.pending_creations(pair.mirror) if p.get("failure")]

        record["failed_panes"] = wait_for("the reserved pane to show the lost reply's failure", failed, self.timeout)
        retried = self.sock.call("supermux.devices.mirror.retry_pending", {
            "workspace_id": pair.mirror, "forget_host_capabilities": True,
        }) or {}
        record["retried"] = retried.get("retried")
        if len(retried.get("retried") or []) != 1:
            raise Failure(f"expected one failed reserved pane to retry: {retried}; record={json.dumps(record)}")

        def settled() -> bool:
            pending = self.pending_creations(pair.mirror)
            if pending:
                raise Failure(f"reserved pane still pending after Retry: {pending}")
            owner_now, mirror_now = self.order(pair.owner), self.mirror_order(pair)
            if owner_now != want or mirror_now != want:
                raise Failure(f"owner {owner_now}, mirror {mirror_now}, expected {want}")
            return True

        try:
            wait_for("the Retry to bring back the terminal the source already made", settled, self.timeout)
        except Failure as error:
            raise Failure(f"{error}; record={json.dumps(record)}")
        time.sleep(SETTLE_SECONDS)
        record.update(owner_settled=self.order(pair.owner), mirror_settled=self.mirror_order(pair),
                      pending_settled=self.pending_creations(pair.mirror))
        if record["owner_settled"] != want or record["mirror_settled"] != want or record["pending_settled"]:
            raise Failure(f"{SETTLE_SECONDS}s later the retry did not hold; record={json.dumps(record)}")
        return record

    def local_workspace(self) -> Dict[str, Any]:
        """A focused local workspace with three tabs (their order is not checked here)."""
        self.local = self.owner_with_mirror("local", focus=True)
        pair = self.local
        for count in (2, 3):
            self.socket_new_tab(pair.owner)
            wait_for(f"{count} local tabs", lambda: len(self.order(pair.owner)) == count, self.timeout)
        return {"local": pair.owner, "mirror": pair.mirror, "tabs": self.order(pair.owner)}

    def local_cmd_t_appends(self) -> Dict[str, Any]:
        pair = self.need(self.local)
        first = self.order(pair.owner)[0]
        self.keyboard_focus(pair.owner, first)
        return {"focused_local_tab": first, **self.new_tab(pair, self.cmd_t)}

    def local_plus_button_appends(self) -> Dict[str, Any]:
        pair = self.need(self.local)
        first = self.order(pair.owner)[0]
        self.keyboard_focus(pair.owner, first)
        return {"focused_local_tab": first, **self.new_tab(pair, lambda: self.plus_button(pair.owner))}

    def local_new_terminal_to_right(self) -> Dict[str, Any]:
        pair = self.need(self.local)
        anchor = self.order(pair.owner)[0]
        record = self.new_tab(pair, lambda: self.tab_menu_terminal_to_right(pair.owner, anchor), right_of(0))
        return {"anchor_local_tab": anchor, **record}

    def failed_mirror_tab_not_restored_locally(self) -> Dict[str, Any]:
        """A reserved mirror tab whose create failed must not come back as a local shell.

        The pane is a placeholder for a terminal the other Mac never made. The session saved
        it like any terminal pane, so a relaunch restored it as a LOCAL shell inside the
        mirror, placed first and looking like the other Mac's tabs. Its failure text also
        said "The Cloud operation failed" for a Mac.
        """
        if not self.args.app_path:
            raise Skipped("pass --app-path to quit and relaunch")
        pair = self.need(self.remote)
        device_name = str(self.device().get("name") or "")
        self.sock.call("workspace.select", {"workspace_id": pair.mirror})
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        problems: List[str] = []
        try:
            wait_for("the loopback link to drop", lambda: self.device().get("link_state") != "connected", self.timeout)
            self.plus_button(pair.mirror)

            def failed() -> List[Dict[str, Any]]:
                return [p for p in self.pending_creations(pair.mirror) if p.get("failure")]

            placeholder = wait_for("the mirror's new tab to fail with the link down", failed, self.timeout)[0]
            text = str(placeholder.get("failure") or "")
            if "Cloud" in text or (device_name and device_name not in text):
                problems.append(f"the failed tab's text is not about {device_name!r}: {text!r}")
        finally:
            self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        self.relaunch()
        wait_for("the loopback device to reconnect after the relaunch",
                 lambda: self.device().get("link_state") == "connected" and self.device().get("has_fetched_records"),
                 self.timeout)
        owner_terminals = wait_for("the owner's restored terminals", lambda: self.order(pair.owner), self.timeout)
        mirror = up(wait_for("the restored mirror", lambda: (self.mirrors_of(pair.owner) or [None])[0],
                             self.timeout)["workspace_id"])
        restored = Pair(pair.label, pair.owner, mirror)
        self.remote = restored

        def only_owner_terminals() -> List[str]:
            order = self.mirror_order(restored)
            if sorted(order) != sorted(self.order(pair.owner)):
                raise Failure(f"mirror {order} vs owner {self.order(pair.owner)}")
            return order

        try:
            settled = wait_for("the restored mirror to hold exactly the owner's terminals", only_owner_terminals, self.timeout)
            time.sleep(SETTLE_SECONDS)
            settled = only_owner_terminals()
        except Failure as error:
            problems.append(f"after the relaunch: {error}")
            settled = self.mirror_order(restored)
        if problems:
            raise Failure("; ".join(problems))
        return {"failure_text": text, "owner_terminals": owner_terminals, "mirror_after_relaunch": settled}

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

    @staticmethod
    def need(pair: Optional[Pair]) -> Pair:
        if pair is None:
            raise Failure("precondition: the workspace this step uses was never created")
        return pair

    # -- run ------------------------------------------------------------------

    def cleanup(self) -> None:
        if self.keep:
            return
        ids = [p.mirror for p in (self.remote, self.local) if p] + [p.owner for p in (self.remote, self.local) if p]
        for workspace_id in ids:
            try:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except Failure as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        ok = self.step("setup", self.setup) and self.step("source_and_mirror", self.source_and_mirror)
        if ok:
            for name, check in [
                ("host_socket_new_tabs_append", self.host_socket_new_tabs_append),
                ("host_phone_new_tab_appends", self.host_phone_new_tab_appends),
                ("mirror_cmd_t_from_last_tab_appends", self.mirror_cmd_t(None)),
                ("mirror_cmd_t_from_first_tab_appends", self.mirror_cmd_t(0)),
                ("mirror_plus_button_appends", self.mirror_plus_button_appends),
                ("mirror_socket_new_tab_appends", self.mirror_socket_new_tab_appends),
                ("mirror_new_terminal_to_right", self.mirror_new_terminal_to_right),
                ("mirror_socket_new_terminal_right", self.mirror_socket_new_terminal_right),
                ("mirror_terminal_right_retry_after_lost_reply", self.mirror_terminal_right_retry_after_lost_reply),
                ("local_workspace", self.local_workspace),
                ("local_cmd_t_appends", self.local_cmd_t_appends),
                ("local_plus_button_appends", self.local_plus_button_appends),
                ("local_new_terminal_to_right", self.local_new_terminal_to_right),
                ("failed_mirror_tab_not_restored_locally", self.failed_mirror_tab_not_restored_locally),
            ]:
                ok = self.step(name, check) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait before a check gives up")
    parser.add_argument("--keep", action="store_true", help="leave the test workspaces and mirrors open")
    parser.add_argument("--app-path", help="the tagged .app to quit and relaunch for the restore check")
    parser.add_argument("--projects-file", help="SUPERMUX_PROJECTS_FILE to relaunch with")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = NewTabOrderE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-new-tab-order-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_new_tab_order_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
