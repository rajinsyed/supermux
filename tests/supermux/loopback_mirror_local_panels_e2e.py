#!/usr/bin/env python3
"""End-to-end test: a browser tab in a device mirror keeps the mirror following its Mac.

A mirror's own browser (any non-terminal tab opened in it) used to stop the
mirror's layout sync in both directions: upstream's layout coordinator required
every pane of a synchronized workspace to project a terminal of the owning Mac,
so one local browser froze the mirror until it closed, and closing a mirrored
terminal tab beside it never closed that terminal on the owning Mac. This suite
drives one tagged DEBUG build running the loopback device ("Loopback Mac" = this
same app's own mobile host) and compares both pane trees after every change,
read through the DEBUG `supermux.devices.mirror.layout` driver. Terminals are
named by their source id (T1...), the mirror's browsers B and B2:

  A setup                                      auto-mirror on; source S and its mirror M: ["T1"] / ["T1"]
  B browser_tab_joins_mirror                   browser.tab.new in M after T1: ["T1"] / ["T1","B"], steady
  C mirror_with_browser_follows_source_split   T1 split right on S: M follows with B kept beside T1
  D mirror_with_browser_pushes_its_arrangement M on screen; T2 moved after B in M: S follows without B
  E source_split_beside_browser_split          browser split B2 in M, then T2 split down on S
  F moved_browser_keeps_its_place              B2 moved after T3 in M, then a new tab T4 in T3's pane on S
  G mirror_tab_close_beside_browsers_closes_its_terminal
                                               T1 closed in M: T1 closes on S too (the close path's guard)
  H closing_browsers_leaves_source_alone       B and B2 closed in M; then T2 split right on S
  I last_terminal_beside_browser_closes_source a second source S2 with ONE terminal, its mirror M2 and a
                                               browser B3 in M2; T1 closed in M2 -> S2 closes on its Mac
                                               (it cannot keep a workspace without a surface), no
                                               failure card, M2 stays open holding only B3 as a
                                               local workspace (no longer a mirror, nothing hidden),
                                               and for a few seconds nothing projects a terminal
                                               into it, closes it or mirrors S2 again
  J last_two_terminals_beside_browser_close_source
                                               a third source S3 with TWO terminals in one pane, its
                                               mirror M3 and a browser B4 in that pane; Close Other
                                               Tabs on B4 (`tab.action close_others`) closes both
                                               terminal tabs in one go -> as in I: S3 closes on its
                                               Mac, no failure card, M3 stays open holding only B4

Every expected pair must hold, then stay so for --settle seconds (nothing pushed
back, nothing moved); each step records both labelled trees and the latency.
Before the fix C fails deterministically: the mirror never projects T2 (its
layout target is nil while B exists), so D-H fail too (G even with only the
first fix: T1 stays on the source). Before I's fix the mirror sends
`mobile.terminal.close`, the owning Mac refuses its last surface, M2 shows
"Couldn't update the machine workspace", S2 keeps running and auto-mirror
closes M2 (browser included) as an orphan. Before J's fix the first close
lands, the second (decided on the layout from before either close, which
still held two terminals) is refused as S3's last surface, with the same
card and orphan close. Writes a JSON report (default
tests/supermux/artifacts/loopback_mirror_local_panels_e2e-<tag>.json) and exits
non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_local_panels_e2e.py [--timeout 20] [--settle 1.5] [--report PATH]
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


class MirrorPair:
    """One background source workspace and its auto-mirror on the loopback device."""

    def __init__(self, sock: Socket, timeout: float, title: str) -> None:
        self.sock = sock
        self.timeout = timeout
        self.title = title
        self.machine = ""
        self.device_name = ""
        self.source_id = ""
        self.mirror_id = ""

    def device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device in supermux.devices.list (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def wait_connected(self) -> Dict[str, Any]:
        def ready() -> Optional[Dict[str, Any]]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        device = wait_for("the loopback device to connect", ready, self.timeout)
        self.machine = device["machine"]
        self.device_name = str(device.get("name") or "")
        return device

    def create(self) -> Dict[str, Any]:
        self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True})
        self.wait_connected()
        created = self.sock.call("workspace.create", {"title": self.title, "focus": False}) or {}
        self.source_id = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not self.source_id:
            raise Failure(f"workspace.create returned no id: {created}")
        self.sock.call("workspace.rename", {"workspace_id": self.source_id, "title": self.title})

        def one_mirror() -> Optional[Dict[str, Any]]:
            rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
            mirrors = [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == self.source_id]
            if len(mirrors) > 1:
                raise Failure(f"{len(mirrors)} mirrors of the source")
            return mirrors[0] if mirrors else None

        self.mirror_id = up(wait_for("the auto-mirror of the source", one_mirror, self.timeout)["workspace_id"])
        first = wait_for("the source's first terminal", lambda: self.surfaces(self.source_id), self.timeout)[0]
        wait_for("the mirror to project the source's terminal", lambda: self.mirror_panel(first), self.timeout)
        return {"source": self.source_id, "mirror": self.mirror_id, "first_terminal": first}

    def panes(self, workspace_id: str) -> List[Dict[str, Any]]:
        return (self.sock.call("pane.list", {"workspace_id": workspace_id}) or {}).get("panes") or []

    def surfaces(self, workspace_id: str) -> List[str]:
        return [up(s) for pane in self.panes(workspace_id) for s in pane.get("surface_ids") or []]

    def pane_of(self, workspace_id: str, surface_id: str) -> str:
        for pane in self.panes(workspace_id):
            if up(surface_id) in [up(s) for s in pane.get("surface_ids") or []]:
                return up(pane.get("id") or pane.get("pane_id"))
        raise Failure(f"no pane of {workspace_id} holds {surface_id}")

    def mirror_projections(self) -> Dict[str, str]:
        """Mirror panel id -> the source terminal id it projects."""
        return {
            up(p.get("panel_id")): up(str(p.get("resource", "")).rsplit("/", 1)[-1])
            for p in (self.sock.call("surface.catalog", {}) or {}).get("projections") or []
            if up(p.get("workspace_id")) == self.mirror_id and str(p.get("resource", "")).startswith(self.machine)
        }

    def mirror_panel(self, source_terminal: str) -> Optional[str]:
        """The mirror panel projecting `source_terminal`, if any."""
        for panel, terminal in self.mirror_projections().items():
            if terminal == up(source_terminal):
                return panel
        return None

    def require_mirror_panel(self, source_terminal: str, name: str) -> str:
        panel = self.mirror_panel(source_terminal)
        if not panel:
            raise Failure(f"precondition: the mirror never projected {name} ({source_terminal})")
        return panel

    def close(self) -> List[str]:
        errors = []
        for workspace_id in (self.mirror_id, self.source_id):
            if not workspace_id:
                continue
            try:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except Failure as error:
                if "not_found" not in str(error):
                    errors.append(str(error))
        return errors


class LocalPanelsE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.timeout = args.timeout
        self.settle = args.settle
        self.keep = args.keep
        self.nonce = uuid.uuid4().hex[:6]
        self.pair = MirrorPair(sock, args.timeout, f"local-panels-{self.nonce}")
        self.extra_pairs: List[MirrorPair] = []
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "settle_seconds": self.settle}
        self.names: Dict[str, str] = {}      # source terminal id -> T1, T2, ...
        self.browsers: Dict[str, str] = {}   # mirror browser panel id -> B, B2
        self.ids: Dict[str, str] = {}        # name -> id (source terminal or mirror browser)

    # -- trees -----------------------------------------------------------------

    def name_terminal(self, terminal_id: str, name: str) -> str:
        self.names[up(terminal_id)] = name
        self.ids[name] = up(terminal_id)
        return up(terminal_id)

    def name_browser(self, panel_id: str, name: str) -> str:
        self.browsers[up(panel_id)] = name
        self.ids[name] = up(panel_id)
        return up(panel_id)

    def tree(self, workspace_id: str) -> Any:
        """The workspace's pane tree, every surface labelled by its name."""
        reply = self.sock.call("supermux.devices.mirror.layout", {"workspace_id": workspace_id}) or {}
        layout = reply.get("layout")
        if not layout:
            return None
        projected = self.pair.mirror_projections() if workspace_id == self.pair.mirror_id else {}

        def label(surface: Any) -> str:
            panel = up(surface)
            if panel in self.browsers:
                return self.browsers[panel]
            terminal = projected.get(panel, panel)
            return self.names.get(terminal, f"local:{panel[:8]}")

        def walk(node: Dict[str, Any]) -> Any:
            if node.get("type") == "pane":
                return [label(s) for s in node.get("surface_ids") or []]
            return {node.get("direction"): [walk(node["first"]), walk(node["second"])]}

        return walk(layout)

    def expect(self, what: str, source: Any, mirror: Any) -> Dict[str, Any]:
        """Both trees match within --timeout, then stay so for --settle seconds."""
        want = {"source": source, "mirror": mirror}

        def matches() -> Dict[str, Any]:
            got = {"source": self.tree(self.pair.source_id), "mirror": self.tree(self.pair.mirror_id)}
            if got != want:
                raise Failure(f"got {json.dumps(got)}, want {json.dumps(want)}")
            return got

        started = time.monotonic()
        got = wait_for(what, matches, self.timeout, interval_s=0.2)
        latency = round(time.monotonic() - started, 2)
        end = time.monotonic() + self.settle
        while time.monotonic() < end:
            matches()
            time.sleep(0.25)
        return {**got, "latency_seconds": latency}

    # -- actions ---------------------------------------------------------------

    def split_source(self, name: str, direction: str, new_name: str) -> str:
        created = self.sock.call("surface.split", {
            "workspace_id": self.pair.source_id, "surface_id": self.ids[name], "direction": direction,
        }) or {}
        terminal = up(created.get("surface_id"))
        if not terminal:
            raise Failure(f"surface.split returned no surface_id: {created}")
        return self.name_terminal(terminal, new_name)

    def close_in_mirror(self, panel_id: str) -> None:
        self.sock.call("surface.close", {"workspace_id": self.pair.mirror_id, "surface_id": panel_id, "force": True})

    # -- workspace state -------------------------------------------------------

    def bindings(self) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.bindings", {}) or {}

    def is_open(self, workspace_id: str) -> bool:
        return any(up(w.get("workspace_id")) == up(workspace_id) for w in self.bindings().get("local_workspaces") or [])

    def panel_kinds(self, workspace_id: str) -> Dict[str, str]:
        """Panel id -> kind (`terminal`, `browser`, ...) of an open workspace."""
        reply = self.sock.call("supermux.devices.mirror.layout", {"workspace_id": workspace_id}) or {}
        return {up(panel): str(kind) for panel, kind in (reply.get("panel_kinds") or {}).items()}

    def failure_card(self, workspace_id: str) -> Optional[Dict[str, Any]]:
        """The workspace's "Couldn't update the machine workspace" card, or None."""
        reply = self.sock.call("supermux.devices.terminal_close.inspect", {"workspace_id": workspace_id}) or {}
        return reply.get("failure_card") or None

    def remote_close_refs(self, key: str) -> List[str]:
        """Remote workspace ids in the Hide Here set (`hidden`) or waiting for their Mac (`pending_remote_closes`)."""
        state = self.sock.call("supermux.devices.hidden", {}) or {}
        return [up(ref.get("remote_workspace_id")) for ref in state.get(key) or []]

    # -- steps -----------------------------------------------------------------

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
        created = self.pair.create()
        self.name_terminal(created["first_terminal"], "T1")
        self.facts.update(machine=self.pair.machine, source_workspace_id=self.pair.source_id,
                          mirror_workspace_id=self.pair.mirror_id)
        return {**created, **self.expect("the mirror to show T1", ["T1"], ["T1"])}

    def browser_tab_joins_mirror(self) -> Dict[str, Any]:
        mirror_t1 = self.pair.require_mirror_panel(self.ids["T1"], "T1")
        created = self.sock.call("browser.tab.new", {"workspace_id": self.pair.mirror_id, "surface_id": mirror_t1}) or {}
        if not created.get("surface_id"):
            raise Failure(f"browser.tab.new returned no surface_id: {created}")
        self.name_browser(created["surface_id"], "B")
        return self.expect("B beside T1 in the mirror only", ["T1"], ["T1", "B"])

    def mirror_follows_source_split(self) -> Dict[str, Any]:
        self.split_source("T1", "right", "T2")
        return self.expect("the mirror to follow T1's split with B kept",
                           {"horizontal": [["T1"], ["T2"]]}, {"horizontal": [["T1", "B"], ["T2"]]})

    def mirror_pushes_its_arrangement(self) -> Dict[str, Any]:
        # Mirror -> owner pushes fire from the mirror's geometry changes, which
        # need it on screen.
        self.sock.call("workspace.select", {"workspace_id": self.pair.mirror_id})
        mirror_t2 = self.pair.require_mirror_panel(self.ids["T2"], "T2")
        self.sock.call("surface.move", {"surface_id": mirror_t2, "after_surface_id": self.ids["B"]})
        return self.expect("the source to follow the mirror's arrangement without B",
                           ["T1", "T2"], ["T1", "B", "T2"])

    def source_split_beside_browser_split(self) -> Dict[str, Any]:
        mirror_t1 = self.pair.require_mirror_panel(self.ids["T1"], "T1")
        created = self.sock.call("browser.open_split", {"workspace_id": self.pair.mirror_id, "surface_id": mirror_t1}) or {}
        if not created.get("surface_id"):
            raise Failure(f"browser.open_split returned no surface_id: {created}")
        self.name_browser(created["surface_id"], "B2")
        before = self.expect("B2 in its own split of the mirror only",
                             ["T1", "T2"], {"horizontal": [["T1", "B", "T2"], ["B2"]]})
        self.split_source("T2", "down", "T3")
        after = self.expect("the mirror to follow T2's split around B2's split",
                            {"vertical": [["T1", "T2"], ["T3"]]},
                            {"vertical": [{"horizontal": [["T1", "B", "T2"], ["B2"]]}, ["T3"]]})
        return {"before": before, "after": after}

    def moved_browser_keeps_its_place(self) -> Dict[str, Any]:
        mirror_t3 = self.pair.require_mirror_panel(self.ids["T3"], "T3")
        self.sock.call("surface.move", {"surface_id": self.ids["B2"], "after_surface_id": mirror_t3})
        before = self.expect("B2 after T3 in the mirror only",
                             {"vertical": [["T1", "T2"], ["T3"]]},
                             {"vertical": [["T1", "B", "T2"], ["T3", "B2"]]})
        created = self.sock.call("surface.create", {
            "workspace_id": self.pair.source_id, "pane_id": self.pair.pane_of(self.pair.source_id, self.ids["T3"]),
            "type": "terminal",
        }) or {}
        if not created.get("surface_id"):
            raise Failure(f"surface.create returned no surface_id: {created}")
        self.name_terminal(created["surface_id"], "T4")
        after = self.expect("T4 after B2 in the mirror",
                            {"vertical": [["T1", "T2"], ["T3", "T4"]]},
                            {"vertical": [["T1", "B", "T2"], ["T3", "B2", "T4"]]})
        return {"before": before, "after": after}

    def mirror_tab_close_closes_its_terminal(self) -> Dict[str, Any]:
        self.close_in_mirror(self.pair.require_mirror_panel(self.ids["T1"], "T1"))
        return self.expect("T1 to close on the source too",
                           {"vertical": [["T2"], ["T3", "T4"]]},
                           {"vertical": [["B", "T2"], ["T3", "B2", "T4"]]})

    def closing_browsers_leaves_source_alone(self) -> Dict[str, Any]:
        self.close_in_mirror(self.ids["B"])
        self.close_in_mirror(self.ids["B2"])
        tree = {"vertical": [["T2"], ["T3", "T4"]]}
        before = self.expect("the browsers to close in the mirror only", tree, tree)
        self.split_source("T2", "right", "T5")
        tree = {"vertical": [{"horizontal": [["T2"], ["T5"]]}, ["T3", "T4"]]}
        after = self.expect("the pure mirror to follow T2's split", tree, tree)
        return {"before": before, "after": after}

    def kept_browser_problem(self, pair: MirrorPair, browser: str) -> Optional[str]:
        """Why the closed source's former mirror is not a plain local workspace holding only `browser`."""
        if not self.is_open(pair.mirror_id):
            return "the mirror workspace closed, its browser with it"
        card = self.failure_card(pair.mirror_id)
        if card:
            return f"the mirror shows the failure card {card.get('title')!r}: {card.get('message')!r}"
        kinds = self.panel_kinds(pair.mirror_id)
        if kinds != {browser: "browser"}:
            return f"the mirror workspace holds {kinds}, want only its browser {browser}"
        mirrors = [m for m in self.bindings().get("mirrors") or []
                   if up(m.get("workspace_id")) == pair.mirror_id or up(m.get("remote_workspace_id")) == pair.source_id]
        if mirrors:
            return f"the source is still (or again) mirrored: {json.dumps(mirrors)}"
        return None

    def last_terminal_beside_browser_closes_source(self) -> Dict[str, Any]:
        pair = MirrorPair(self.sock, self.timeout, f"local-panels-last-{self.nonce}")
        self.extra_pairs.append(pair)
        created = pair.create()
        terminal = up(created["first_terminal"])
        mirror_t1 = pair.require_mirror_panel(terminal, "the second source's only terminal")
        opened = self.sock.call("browser.tab.new", {"workspace_id": pair.mirror_id, "surface_id": mirror_t1}) or {}
        browser = up(opened.get("surface_id"))
        if not browser:
            raise Failure(f"browser.tab.new returned no surface_id: {opened}")

        def browser_stays_local() -> Optional[str]:
            kinds, source = self.panel_kinds(pair.mirror_id), pair.surfaces(pair.source_id)
            if kinds != {mirror_t1: "terminal", browser: "browser"} or source != [terminal]:
                return f"mirror {kinds}, source {source}"
            return None

        wait_for("B3 beside the only terminal in the mirror only", lambda: browser_stays_local() is None, self.timeout)
        unsettled = holds(browser_stays_local, self.settle)
        if unsettled:
            raise Failure(f"precondition: the mirror and source did not settle: {unsettled}")

        self.sock.call("surface.close", {"workspace_id": pair.mirror_id, "surface_id": mirror_t1, "force": True})
        problems = self.source_closed_keeping_browser_problems(pair, browser)
        if problems:
            raise Failure("; ".join(problems))
        return {"source": pair.source_id, "mirror": pair.mirror_id, "terminal": terminal, "browser": browser,
                "kept_panels": self.panel_kinds(pair.mirror_id)}

    def source_closed_keeping_browser_problems(self, pair: MirrorPair, browser: str) -> List[str]:
        """What is wrong once the mirror's last terminals closed beside `browser`: the source
        must close on its Mac, and the mirror stay open holding only `browser` as a plain
        local workspace (no card, not mirrored, nothing hidden, no close left pending)."""
        problems: List[str] = []
        try:
            wait_for("the source to close on its Mac", lambda: not self.is_open(pair.source_id), self.timeout)
        except Failure as error:
            problems.append(str(error))
        kept = self.kept_browser_problem(pair, browser) \
            or holds(lambda: self.kept_browser_problem(pair, browser), max(self.settle, 3.0), interval_s=0.5)
        if kept:
            problems.append(kept)
        if not problems:
            if pair.source_id in self.remote_close_refs("hidden"):
                problems.append("the source was added to the Hide Here set")
            try:
                wait_for("the source's pending close to be forgotten",
                         lambda: pair.source_id not in self.remote_close_refs("pending_remote_closes"), self.timeout)
            except Failure as error:
                problems.append(str(error))
        return problems

    def last_two_terminals_beside_browser_close_source(self) -> Dict[str, Any]:
        """Close Other Tabs on the mirror's browser closes its last TWO terminals in one
        go. The first close lands on the owning Mac; the second then names that
        workspace's last surface, which the owner refuses, so the source must close
        there instead (decided on the layout that close fetched, not on the one from
        before either close), exactly as for one terminal."""
        pair = MirrorPair(self.sock, self.timeout, f"local-panels-two-{self.nonce}")
        self.extra_pairs.append(pair)
        created = pair.create()
        first = up(created["first_terminal"])
        made = self.sock.call("surface.create", {
            "workspace_id": pair.source_id, "pane_id": pair.pane_of(pair.source_id, first), "type": "terminal",
        }) or {}
        second = up(made.get("surface_id"))
        if not second:
            raise Failure(f"surface.create returned no surface_id: {made}")
        mirror_first = pair.require_mirror_panel(first, "the third source's first terminal")
        mirror_second = wait_for("the mirror to project the second terminal", lambda: pair.mirror_panel(second), self.timeout)
        opened = self.sock.call("browser.tab.new", {"workspace_id": pair.mirror_id, "surface_id": mirror_first}) or {}
        browser = up(opened.get("surface_id"))
        if not browser:
            raise Failure(f"browser.tab.new returned no surface_id: {opened}")

        def settled() -> Optional[str]:
            kinds, source = self.panel_kinds(pair.mirror_id), sorted(pair.surfaces(pair.source_id))
            want = {mirror_first: "terminal", mirror_second: "terminal", browser: "browser"}
            if kinds != want or source != sorted([first, second]):
                return f"mirror {kinds}, source {source}"
            panes = {pair.pane_of(pair.mirror_id, panel) for panel in want}
            if len(panes) != 1:
                return f"the mirror's two terminals and its browser are in {len(panes)} panes"
            return None

        wait_for("both terminals and the browser in one pane of the mirror", lambda: settled() is None, self.timeout)
        unsettled = holds(settled, self.settle)
        if unsettled:
            raise Failure(f"precondition: the mirror and source did not settle: {unsettled}")

        # One main-actor turn closes both terminal tabs, as the tab menu's Close Other Tabs does.
        closed = self.sock.call("tab.action", {
            "workspace_id": pair.mirror_id, "surface_id": browser, "action": "close_others", "force": True,
        }) or {}
        problems = self.source_closed_keeping_browser_problems(pair, browser)
        if problems:
            raise Failure("; ".join(problems))
        return {"source": pair.source_id, "mirror": pair.mirror_id, "terminals": [first, second], "browser": browser,
                "close_others": closed, "kept_panels": self.panel_kinds(pair.mirror_id)}

    def run(self) -> bool:
        ok = self.step("setup", self.setup)
        if ok:
            for name, check in [
                ("browser_tab_joins_mirror", self.browser_tab_joins_mirror),
                ("mirror_with_browser_follows_source_split", self.mirror_follows_source_split),
                ("mirror_with_browser_pushes_its_arrangement", self.mirror_pushes_its_arrangement),
                ("source_split_beside_browser_split", self.source_split_beside_browser_split),
                ("moved_browser_keeps_its_place", self.moved_browser_keeps_its_place),
                ("mirror_tab_close_beside_browsers_closes_its_terminal", self.mirror_tab_close_closes_its_terminal),
                ("closing_browsers_leaves_source_alone", self.closing_browsers_leaves_source_alone),
                ("last_terminal_beside_browser_closes_source", self.last_terminal_beside_browser_closes_source),
                ("last_two_terminals_beside_browser_close_source", self.last_two_terminals_beside_browser_close_source),
            ]:
                ok = self.step(name, check) and ok
        self.facts["names"] = {name: identifier for name, identifier in self.ids.items()}
        if not self.keep:
            errors = [error for pair in [self.pair, *self.extra_pairs] for error in pair.close()]
            if errors:
                self.facts["cleanup_errors"] = errors
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    parser.add_argument("--timeout", type=float, default=20.0, help="seconds to wait before a check gives up")
    parser.add_argument("--settle", type=float, default=1.5, help="seconds both trees must stay as expected")
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
        test = LocalPanelsE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-mirror-local-panels-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_mirror_local_panels_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
