#!/usr/bin/env python3
"""End-to-end test of Supermux auto-mirror, mirror close semantics and mirror
status parity, against one tagged DEBUG build running the loopback device.

The loopback device ("Loopback Mac") talks in-process to this same app's mobile
host, so every local (source) workspace is also a remote workspace of that
device, and auto-mirror opens one local mirror workspace per source. Checks:

  a. every_source_has_one_mirror   each non-mirror workspace with a terminal gets exactly one mirror
  b. new_workspace_gets_mirror     a newly created workspace gets a mirror automatically
  b2. mirrors_keep_remote_order    mirrors opened together keep the remote order relative to each other
  c. closing_source_closes_mirror  closing a source closes its mirror (remote workspace gone)
  d. hide_and_unhide               "Hide Here" (socket close_mirror hide) is never reopened;
                                   a programmatic workspace.close of a mirror hides too;
                                   supermux.devices.unhide brings the mirror back
  e. close_on_mac                  "Close on <Mac>" (socket close_mirror close_on_mac) closes the
                                   source and the mirror, and nothing reopens
  f. agent_activity                set_agent_lifecycle on the source -> mirror activity working /
                                   needsInput / ready; the duplicated agent pill is not mirrored
  g. status_progress_log_branch    set_status / set_progress / log (and git branch) on the source
                                   show on the mirror, and clearing them clears the mirror
  g2. color_description_pin        the source's custom color, description and pin follow onto the mirror
  i. layout_with_browser           a source holding a browser panel still syncs its terminals' layout
  h. restart_dedupe                (with --app-path) quit + relaunch: still exactly one mirror per
                                   source, no duplicates, no orphaned bindings

Writes a JSON report (default tests/supermux/artifacts/loopback_auto_mirror_e2e-<tag>.json) and
exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_auto_mirror_e2e.py \
      [--app-path "<App path printed by reload.sh>" --projects-file /tmp/<tag>/projects.json] \
      [--git-repo /tmp/<tag>/repo] [--timeout 45] [--report PATH]
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


class Socket:
    """Newline-delimited client for the cmux control socket (v2 JSON and v1 text)."""

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
        request_id = self._next_id
        self._next_id += 1
        self._send(json.dumps({"id": request_id, "method": method, "params": params or {}}))
        response = json.loads(self._read_line(timeout_s or self.timeout_s))
        if response.get("id") != request_id:
            raise Failure(f"{method}: mismatched response id")
        if response.get("ok") is True:
            return response.get("result")
        error = response.get("error") or {}
        raise Failure(f"{method}: {error.get('code', 'error')}: {error.get('message', 'unknown error')}")

    def v1(self, line: str) -> str:
        self._send(line)
        reply = self._read_line(self.timeout_s).strip()
        if reply.startswith("ERROR"):
            raise Failure(f"v1 `{line.split(' ')[0]}`: {reply}")
        return reply

    def _send(self, line: str) -> None:
        assert self._sock is not None, "not connected"
        self._sock.sendall((line + "\n").encode("utf-8"))

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


def hold(description: str, probe: Callable[[], Any], seconds: float, interval_s: float = 0.5) -> None:
    """Asserts `probe` stays truthy for `seconds` (negative checks)."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not probe():
            raise Failure(f"{description} stopped holding")
        time.sleep(interval_s)


class AutoMirrorE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.machine = ""
        self.created: List[str] = []

    # -- reads ----------------------------------------------------------------

    def device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device in supermux.devices.list (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def bindings(self) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.bindings", {}) or {}

    def mirrors_of(self, source_id: str, bindings: Optional[Dict[str, Any]] = None) -> List[Dict[str, Any]]:
        rows = (bindings or self.bindings()).get("mirrors") or []
        return [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(source_id)]

    def one_mirror(self, source_id: str) -> Dict[str, Any]:
        mirrors = self.mirrors_of(source_id)
        if len(mirrors) > 1:
            raise Failure(f"{len(mirrors)} mirrors of {source_id}")
        return mirrors[0] if mirrors else {}

    def local_ids(self) -> set:
        return {up(w.get("workspace_id")) for w in self.bindings().get("local_workspaces") or []}

    def hidden(self) -> set:
        return {up(h.get("remote_workspace_id")) for h in (self.sock.call("supermux.devices.hidden", {}) or {}).get("hidden") or []}

    def mirror_status(self, source_id: str) -> Dict[str, Any]:
        mirror = self.one_mirror(source_id)
        if not mirror:
            raise Failure(f"no mirror of {source_id}")
        return mirror.get("status") or {}

    def terminal_ids(self, workspace_id: str) -> List[str]:
        surfaces = (self.sock.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        return [s["id"] for s in surfaces if s.get("type") == "terminal"]

    # -- actions --------------------------------------------------------------

    def create_source(self, label: str, cwd: Optional[str] = None) -> str:
        params: Dict[str, Any] = {"title": f"auto-mirror-{label}-{self.nonce}", "focus": False}
        if cwd:
            params["cwd"] = cwd
        result = self.sock.call("workspace.create", params) or {}
        workspace_id = result.get("workspace_id") or result.get("created_workspace_id")
        if not workspace_id:
            raise Failure(f"workspace.create returned no id: {result}")
        self.sock.call("workspace.rename", {"workspace_id": workspace_id, "title": params["title"]})
        self.created.append(str(workspace_id))
        return str(workspace_id)

    def wait_one_mirror(self, source_id: str) -> Dict[str, Any]:
        return wait_for(f"exactly one mirror of {source_id}", lambda: self.one_mirror(source_id), self.timeout)

    def close_workspace(self, workspace_id: str) -> None:
        self.sock.call("workspace.close", {"workspace_id": workspace_id})

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
        print(f"{'PASS' if record['ok'] else 'FAIL'} {name} ({record['seconds']}s){'' if record['ok'] else ': ' + record['error']}", file=sys.stderr)
        return record["ok"]

    # -- setup ----------------------------------------------------------------

    def setup(self) -> Dict[str, Any]:
        state = self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True}) or {}

        def ready() -> Optional[Dict[str, Any]]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        device = wait_for("the loopback device to connect", ready, self.timeout)
        self.machine = device["machine"]
        self.facts["machine"] = self.machine
        return {"machine": self.machine, "auto_mirror": state.get("auto_mirror")}

    # -- checks ---------------------------------------------------------------

    def sources_with_terminals(self) -> Dict[str, str]:
        device = self.device()
        return {up(r["id"]): r.get("title") for r in device.get("records") or [] if (r.get("terminal_count") or 0) > 0}

    def check_every_source(self) -> Dict[str, Any]:
        def settled() -> Optional[Dict[str, Any]]:
            sources = self.sources_with_terminals()
            bindings = self.bindings()
            mirror_ids = {up(w.get("workspace_id")) for w in bindings.get("local_workspaces") or [] if w.get("is_device_mirror")}
            if mirror_ids & set(sources):
                raise Failure(f"a mirror is exported as a remote workspace: {sorted(mirror_ids & set(sources))}")
            counts = {source: len(self.mirrors_of(source, bindings)) for source in sources}
            wrong = {k: v for k, v in counts.items() if v != 1}
            if wrong:
                raise Failure(f"mirror counts != 1: {wrong}")
            return {"sources": len(sources), "mirrors": len(mirror_ids)}

        return wait_for("one mirror per source", settled, self.timeout * 2)

    def check_new_workspace(self) -> Dict[str, Any]:
        source = self.create_source("new")
        mirror = self.wait_one_mirror(source)
        if up(mirror.get("workspace_id")) == up(source):
            raise Failure("the mirror is the source itself")
        titles = wait_for(
            "the mirror to take the source title",
            lambda: (lambda m: m if m.get("title") == m.get("remote_title") else None)(self.one_mirror(source)),
            self.timeout,
        )
        self.facts["new_source"] = source
        return {"source": source, "mirror": mirror.get("workspace_id"), "title": titles.get("title")}

    def check_mirror_order(self) -> Dict[str, Any]:
        """Mirrors opened together keep the remote's order relative to each other."""
        sources = [self.create_source(f"order{i}") for i in range(3)]
        for source in sources:
            self.wait_one_mirror(source)
        remote_order = [up(r["id"]) for r in self.device().get("records") or [] if up(r["id"]) in {up(s) for s in sources}]
        bindings = self.bindings()
        mirror_to_source = {up(m["workspace_id"]): up(m["remote_workspace_id"]) for m in bindings.get("mirrors") or []}
        local_order = [
            mirror_to_source[up(w["workspace_id"])]
            for w in bindings.get("local_workspaces") or []
            if up(w["workspace_id"]) in mirror_to_source and mirror_to_source[up(w["workspace_id"])] in remote_order
        ]
        if local_order != remote_order:
            raise Failure(f"mirror order {local_order} != remote order {remote_order}")
        for source in sources:
            self.close_workspace(source)
        wait_for("the order mirrors to close", lambda: all(not self.mirrors_of(s) for s in sources), self.timeout)
        return {"order": remote_order}

    def check_close_source(self) -> Dict[str, Any]:
        source = self.facts["new_source"]
        mirror_id = up(self.one_mirror(source).get("workspace_id"))
        self.close_workspace(source)
        wait_for("the mirror to close after its source", lambda: not self.mirrors_of(source) and mirror_id not in self.local_ids(), self.timeout)
        hold("no mirror reappears", lambda: not self.mirrors_of(source), 3)
        if up(source) in self.hidden():
            raise Failure("a coordinator close hid the remote workspace")
        return {"source": source, "closed_mirror": mirror_id}

    def check_hide_unhide(self) -> Dict[str, Any]:
        source = self.create_source("hide")
        mirror = self.wait_one_mirror(source)
        result = self.sock.call("supermux.devices.close_mirror", {"workspace_id": mirror["workspace_id"], "action": "hide"}) or {}
        if not result.get("closed"):
            raise Failure(f"close_mirror hide did not close the mirror: {result}")
        if up(source) not in self.hidden():
            raise Failure("Hide Here did not add the ref to the hidden set")
        hold("the hidden workspace stays unmirrored", lambda: not self.mirrors_of(source), 4)
        if up(source) not in self.local_ids():
            raise Failure("Hide Here closed the source")
        unhidden = self.sock.call("supermux.devices.unhide", {"machine": self.machine, "remote_workspace_id": source}) or {}
        again = self.wait_one_mirror(source)
        # A plain programmatic close of a mirror is treated as Hide Here.
        self.close_workspace(again["workspace_id"])
        wait_for("the programmatic close to hide", lambda: up(source) in self.hidden() and not self.mirrors_of(source), self.timeout)
        hold("the programmatically closed mirror stays hidden", lambda: not self.mirrors_of(source), 3)
        self.sock.call("supermux.devices.unhide", {})
        third = self.wait_one_mirror(source)
        return {
            "source": source,
            "unhidden": unhidden.get("unhidden"),
            "reopened_mirror": again.get("workspace_id"),
            "reopened_after_programmatic_close": third.get("workspace_id"),
        }

    def check_close_on_mac(self) -> Dict[str, Any]:
        source = self.create_source("closeonmac")
        mirror = self.wait_one_mirror(source)
        result = self.sock.call(
            "supermux.devices.close_mirror",
            {"workspace_id": mirror["workspace_id"], "action": "close_on_mac"},
            timeout_s=60,
        ) or {}
        wait_for("the source to close on its Mac", lambda: up(source) not in self.local_ids(), self.timeout)
        wait_for("the mirror to be gone", lambda: not self.mirrors_of(source), self.timeout)
        hold("nothing reopens", lambda: not self.mirrors_of(source) and up(source) not in self.local_ids(), 3)
        if up(source) in self.hidden():
            raise Failure("close on Mac also hid the ref")
        return {"source": source, "mirror": mirror.get("workspace_id"), "result_closed": result.get("closed")}

    def status_source(self) -> str:
        if "status_source" not in self.facts:
            source = self.create_source("status", cwd=self.args.git_repo)
            self.wait_one_mirror(source)
            panel = wait_for("the source terminal", lambda: (self.terminal_ids(source) or [None])[0], self.timeout)
            self.facts["status_source"] = source
            self.facts["status_panel"] = panel
        return self.facts["status_source"]

    def mirror_field(self, source: str, field: str, predicate: Callable[[Any], bool], description: str) -> Any:
        def probe() -> Any:
            value = self.mirror_status(source).get(field)
            return {"value": value} if predicate(value) else None

        return wait_for(f"mirror {field} {description}", probe, self.timeout)["value"]

    def check_agent_activity(self) -> Dict[str, Any]:
        source = self.status_source()
        panel = self.facts["status_panel"]
        v1 = self.sock.v1
        seen = {}
        for lifecycle, expected in (("running", "working"), ("needsInput", "needsInput"), ("idle", "ready")):
            v1(f"set_agent_lifecycle claude_code {lifecycle} --tab={source} --panel={panel}")
            seen[lifecycle] = self.mirror_field(source, "activity", lambda v, e=expected: v == e, f"== {expected}")
        # The duplicated agent pill (bolt.fill while working) is not mirrored,
        # a user pill is.
        v1(f"set_agent_lifecycle claude_code running --tab={source} --panel={panel}")
        v1(f"set_status claude_code Running --icon=bolt.fill --tab={source} --panel={panel}")
        v1(f"set_status e2e_user_pill kept --icon=star.fill --tab={source}")
        entries = self.mirror_field(
            source, "status_entries",
            lambda v: any(e.get("key") == "e2e_user_pill" for e in v or []),
            "to include the user pill",
        )
        if any(e.get("key") == "claude_code" for e in entries):
            raise Failure(f"the duplicated agent pill reached the mirror: {entries}")
        v1(f"clear_status claude_code --tab={source}")
        v1(f"clear_status e2e_user_pill --tab={source}")
        v1(f"set_agent_lifecycle claude_code idle --tab={source} --panel={panel}")
        return {"activity": seen, "mirror_pills_while_working": entries}

    def check_status_progress_log(self) -> Dict[str, Any]:
        source = self.status_source()
        v1 = self.sock.v1
        v1(f"set_status e2e_status hello-{self.nonce} --icon=star.fill --color=#FF3B30 --tab={source}")
        v1(f"set_progress 0.5 --label=halfway --tab={source}")
        v1(f"log --level=warning --tab={source} -- e2e log {self.nonce}")
        pill = self.mirror_field(
            source, "status_entries",
            lambda v: any(e.get("key") == "e2e_status" and e.get("value") == f"hello-{self.nonce}" for e in v or []),
            "to show the pill",
        )
        progress = self.mirror_field(source, "progress", lambda v: bool(v) and abs(v.get("value", 0) - 0.5) < 1e-6 and v.get("label") == "halfway", "== 0.5 halfway")
        log = self.mirror_field(source, "log", lambda v: bool(v) and v.get("message") == f"e2e log {self.nonce}" and v.get("level") == "warning", "to show the log line")
        facts: Dict[str, Any] = {"pill": [e for e in pill if e.get("key") == "e2e_status"], "progress": progress, "log": log}
        if self.args.git_repo:
            facts["branch"] = self.mirror_field(source, "branch", lambda v: bool(v), "to show the source git branch")
        v1(f"clear_status e2e_status --tab={source}")
        v1(f"clear_progress --tab={source}")
        v1(f"clear_log --tab={source}")
        self.mirror_field(source, "status_entries", lambda v: not any(e.get("key") == "e2e_status" for e in v or []), "to drop the pill")
        self.mirror_field(source, "progress", lambda v: v is None, "to clear")
        self.mirror_field(source, "log", lambda v: v is None, "to clear")
        return facts

    def check_customization(self) -> Dict[str, Any]:
        source = self.status_source()

        def action(name: str, **extra: Any) -> None:
            self.sock.call("workspace.action", {"workspace_id": source, "action": name, **extra})

        action("set_color", color="#34C759")
        action("set_description", description=f"e2e description {self.nonce}")
        action("pin")
        color = self.mirror_field(source, "custom_color", lambda v: str(v or "").upper() == "#34C759", "== #34C759")
        description = self.mirror_field(source, "description", lambda v: v == f"e2e description {self.nonce}", "to follow")
        self.mirror_field(source, "is_pinned", lambda v: v is True, "== true")
        action("unpin")
        action("clear_description")
        action("clear_color")
        self.mirror_field(source, "is_pinned", lambda v: v is False, "== false")
        self.mirror_field(source, "description", lambda v: v is None, "to clear")
        self.mirror_field(source, "custom_color", lambda v: v is None, "to clear")
        return {"color": color, "description": description}

    def check_layout_with_browser(self) -> Dict[str, Any]:
        source = self.create_source("browser")
        self.wait_one_mirror(source)
        terminal = wait_for("the source terminal", lambda: (self.terminal_ids(source) or [None])[0], self.timeout)
        self.sock.call("browser.open_split", {"workspace_id": source, "surface_id": terminal, "url": "about:blank"})
        # The mirror keeps working with a browser in its remote workspace:
        # a new source split must still be projected into the mirror.
        time.sleep(1.5)
        split = self.sock.call("surface.split", {"workspace_id": source, "surface_id": terminal, "direction": "down"}) or {}
        new_terminal = split.get("surface_id")
        if not new_terminal:
            raise Failure(f"surface.split returned no surface: {split}")
        mirror_id = self.one_mirror(source)["workspace_id"]

        def projected() -> bool:
            catalog = self.sock.call("surface.catalog", {}) or {}
            suffix = "/terminal/" + str(new_terminal).lower()
            return any(
                up(p.get("workspace_id")) == up(mirror_id) and str(p.get("resource", "")).lower().endswith(suffix)
                for p in catalog.get("projections") or []
            )

        wait_for("the mirror to project the new terminal next to a remote browser", projected, self.timeout)
        return {"source": source, "mirror": mirror_id, "new_terminal": new_terminal}

    # -- restart --------------------------------------------------------------

    def check_restart(self) -> Dict[str, Any]:
        app = self.args.app_path
        bundle_id = plistlib.loads((Path(app) / "Contents" / "Info.plist").read_bytes())["CFBundleIdentifier"]
        before = self.snapshot_pairs()
        self.sock.close()
        subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to quit'], check=False, capture_output=True)
        wait_for("the app to quit", lambda: not os.path.exists(self.sock.path) or not self.socket_alive(), 30)
        time.sleep(1.0)
        env_args = ["--env", "SUPERMUX_DEBUG_LOOPBACK_DEVICE=1"]
        if self.args.projects_file:
            env_args += ["--env", f"SUPERMUX_PROJECTS_FILE={self.args.projects_file}"]
        subprocess.run(["open", "-g", *env_args, app], check=True)
        wait_for("the relaunched app's socket", self.socket_alive, 60)
        self.sock.connect()
        self.setup()
        self.check_every_source()
        # Give a late duplicate a chance to appear, then check again.
        time.sleep(4)
        after = self.check_every_source()
        bindings = self.bindings()
        stale = [s for s in bindings.get("stored") or [] if not s.get("is_live")]
        if stale:
            raise Failure(f"orphaned stored bindings after restore: {stale}")
        refs = [(m.get("machine"), up(m.get("remote_workspace_id"))) for m in bindings.get("mirrors") or []]
        dupes = {r for r in refs if refs.count(r) > 1}
        if dupes:
            raise Failure(f"duplicate mirrors after restore: {dupes}")
        after_pairs = self.snapshot_pairs()
        return {
            "bundle_id": bundle_id,
            "sources_before": len(before),
            "sources_after": len(after_pairs),
            "same_mirror_workspaces": sum(1 for k, v in before.items() if after_pairs.get(k) == v),
            "state": after,
        }

    def snapshot_pairs(self) -> Dict[str, str]:
        pairs = {}
        for mirror in self.bindings().get("mirrors") or []:
            if mirror.get("machine") == self.machine:
                pairs[up(mirror.get("remote_workspace_id"))] = up(mirror.get("workspace_id"))
        return pairs

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
        for workspace_id in self.created:
            try:
                if up(workspace_id) in self.local_ids():
                    self.close_workspace(workspace_id)
            except (Failure, OSError) as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        ok = self.step("setup", self.setup)
        if ok:
            checks = [
                ("a_every_source_has_one_mirror", self.check_every_source),
                ("b_new_workspace_gets_mirror", self.check_new_workspace),
                ("b2_mirrors_keep_remote_order", self.check_mirror_order),
                ("c_closing_source_closes_mirror", self.check_close_source),
                ("d_hide_and_unhide", self.check_hide_unhide),
                ("e_close_on_mac_closes_source", self.check_close_on_mac),
                ("f_agent_activity", self.check_agent_activity),
                ("g_status_progress_log_branch", self.check_status_progress_log),
                ("g2_color_description_pin", self.check_customization),
                ("i_layout_with_browser", self.check_layout_with_browser),
            ]
            for name, check in checks:
                ok = self.step(name, check) and ok
            if self.args.app_path:
                ok = self.step("h_restart_one_mirror_per_source", self.check_restart) and ok
            else:
                self.steps.append({"name": "h_restart_one_mirror_per_source", "ok": None, "skipped": "pass --app-path to run"})
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    parser.add_argument("--timeout", type=float, default=45.0, help="seconds per wait")
    parser.add_argument("--app-path", help="the tagged .app to quit and relaunch for the restart check")
    parser.add_argument("--projects-file", help="SUPERMUX_PROJECTS_FILE for the relaunch (a scratch projects file)")
    parser.add_argument("--git-repo", help="a scratch git repo for the branch check (e.g. /tmp/<tag>/repo)")
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
        test = AutoMirrorE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-auto-mirror-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_auto_mirror_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
