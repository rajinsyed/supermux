#!/usr/bin/env python3
"""End-to-end test: background tab changes on the owning Mac reach its mirror.

The owning Mac used to announce `device.workspace.layout.changed` only when a
workspace's pane GEOMETRY changed, which needs the workspace on screen. A tab
added, closed or reordered in a workspace nobody is looking at there (an agent
spawning a terminal, the phone creating one, a preset launch, a CLI
new-surface) therefore never reached a viewer's mirror until some unrelated
geometry change. This suite drives exactly those background edits against one
tagged DEBUG build running the loopback device ("Loopback Mac" = this same
app's own mobile host), never selecting the source workspace:

  1. setup                          auto-mirror on, the loopback linked and fetched
  2. source_gets_mirror             a background source workspace gets one mirror
  3. socket_new_tab_reaches_mirror  surface.create in the source -> the mirror projects it
  4. phone_new_tab_reaches_mirror   mobile.terminal.create over the device link (the
                                    phone's path) -> the mirror projects it
  5. closed_tab_leaves_mirror       surface.close in the source -> the mirror drops it
  6. reorder_follows                surface.reorder in the source -> the mirror's tab
                                    order matches the source's
  7. source_stayed_in_background    the source was never selected (no geometry path)

Every propagation is timed; a step fails if it takes longer than --latency
seconds (default 1.0). Writes a JSON report (default
tests/supermux/artifacts/loopback_tab_sync_e2e-<tag>.json) and exits non-zero
on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_tab_sync_e2e.py [--latency 1.0] [--timeout 30] [--report PATH]
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


class TabSyncE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.timeout = args.timeout
        self.latency_limit = args.latency
        self.keep = args.keep
        self.nonce = uuid.uuid4().hex[:6]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "latency_limit_seconds": self.latency_limit}
        self.machine = ""
        self.source_id = ""
        self.mirror_id = ""
        self.selection_samples: List[bool] = []

    # -- reads ----------------------------------------------------------------

    def device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device in supermux.devices.list (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def mirrors_of_source(self) -> List[Dict[str, Any]]:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        return [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(self.source_id)]

    def ordered_surfaces(self, workspace_id: str) -> List[str]:
        """Every surface in pane order, then tab order inside each pane."""
        panes = (self.sock.call("pane.list", {"workspace_id": workspace_id}) or {}).get("panes") or []
        return [up(surface) for pane in panes for surface in pane.get("surface_ids") or []]

    def mirror_projections(self) -> Dict[str, str]:
        """Mirror panel id -> the source terminal id it projects."""
        return {
            up(p.get("panel_id")): up(str(p.get("resource", "")).rsplit("/", 1)[-1])
            for p in (self.sock.call("surface.catalog", {}) or {}).get("projections") or []
            if up(p.get("workspace_id")) == up(self.mirror_id) and str(p.get("resource", "")).startswith(self.machine)
        }

    def mirror_order_as_source_ids(self) -> List[str]:
        projections = self.mirror_projections()
        return [projections.get(panel, f"local:{panel}") for panel in self.ordered_surfaces(self.mirror_id)]

    def source_is_selected(self) -> bool:
        windows = (self.sock.call("window.list", {}) or {}).get("windows") or []
        for window in windows:
            rows = (self.sock.call("workspace.list", {"window_id": window.get("id")}) or {}).get("workspaces") or []
            for row in rows:
                if up(row.get("id")) == up(self.source_id):
                    return bool(row.get("is_selected") or row.get("selected"))
        return False

    def sample_selection(self) -> None:
        self.selection_samples.append(self.source_is_selected())

    # -- timing ---------------------------------------------------------------

    def timed(self, description: str, probe: Callable[[], Any]) -> Dict[str, Any]:
        """Polls fast, returns the latency, and fails when it exceeds the limit."""
        started = time.monotonic()
        value = wait_for(description, probe, self.timeout, interval_s=0.1)
        latency = round(time.monotonic() - started, 3)
        self.sample_selection()
        if latency > self.latency_limit:
            raise Failure(f"{description} took {latency}s (limit {self.latency_limit}s)")
        return {"latency_seconds": latency, "value": value}

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
        self.facts["machine"] = self.machine
        return {"machine": self.machine, "auto_mirror": state.get("auto_mirror")}

    def source_gets_mirror(self) -> Dict[str, Any]:
        title = f"tab-sync-{self.nonce}"
        created = self.sock.call("workspace.create", {"title": title, "focus": False}) or {}
        self.source_id = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not self.source_id:
            raise Failure(f"workspace.create returned no id: {created}")
        self.sock.call("workspace.rename", {"workspace_id": self.source_id, "title": title})

        def one_mirror() -> Optional[Dict[str, Any]]:
            mirrors = self.mirrors_of_source()
            if len(mirrors) > 1:
                raise Failure(f"{len(mirrors)} mirrors of the source")
            return mirrors[0] if mirrors else None

        self.mirror_id = up(wait_for("the auto-mirror of the source", one_mirror, self.timeout)["workspace_id"])
        source_order = wait_for("the source's first terminal", lambda: self.ordered_surfaces(self.source_id), self.timeout)
        wait_for("the mirror to project the source's terminal",
                 lambda: self.mirror_order_as_source_ids() == source_order, self.timeout)
        self.sample_selection()
        self.facts.update(source_workspace_id=self.source_id, mirror_workspace_id=self.mirror_id)
        return {"source": self.source_id, "mirror": self.mirror_id, "source_tabs": source_order}

    def expect_mirror_has(self, terminal_id: str, description: str) -> Dict[str, Any]:
        def projected() -> bool:
            return up(terminal_id) in self.mirror_projections().values()

        return self.timed(description, projected)

    def socket_new_tab(self) -> Dict[str, Any]:
        created = self.sock.call("surface.create", {"workspace_id": self.source_id, "type": "terminal"}) or {}
        terminal = up(created.get("surface_id"))
        if not terminal:
            raise Failure(f"surface.create returned no surface_id: {created}")
        self.facts["socket_tab"] = terminal
        result = self.expect_mirror_has(terminal, "the mirror to project the socket-created tab")
        return {"terminal": terminal, "latency_seconds": result["latency_seconds"]}

    def phone_new_tab(self) -> Dict[str, Any]:
        reply = self.sock.call("supermux.devices.request", {
            "machine": self.machine, "method": "mobile.terminal.create",
            "params": {"workspace_id": self.source_id}, "timeout_seconds": 30,
        }, timeout_s=40) or {}
        terminal = up((reply.get("result") or {}).get("created_terminal_id"))
        if not terminal:
            raise Failure(f"mobile.terminal.create returned no created_terminal_id: {reply}")
        self.facts["phone_tab"] = terminal
        result = self.expect_mirror_has(terminal, "the mirror to project the phone-created tab")
        return {"terminal": terminal, "latency_seconds": result["latency_seconds"]}

    def closed_tab(self) -> Dict[str, Any]:
        terminal = self.facts.get("socket_tab")
        if not terminal or up(terminal) not in self.mirror_projections().values():
            raise Failure("precondition: the mirror never showed the socket-created tab, so a close proves nothing")
        self.sock.call("surface.close", {"workspace_id": self.source_id, "surface_id": terminal, "force": True})

        def dropped() -> bool:
            if up(terminal) in self.ordered_surfaces(self.source_id):
                raise Failure("the source still holds the closed tab")
            return up(terminal) not in self.mirror_projections().values()

        result = self.timed("the mirror to drop the closed tab", dropped)
        return {"terminal": terminal, "latency_seconds": result["latency_seconds"]}

    def reorder(self) -> Dict[str, Any]:
        before = self.ordered_surfaces(self.source_id)
        if len(before) < 2:
            raise Failure(f"need two source tabs to reorder, have {before}")
        if self.mirror_order_as_source_ids() != before:
            raise Failure(f"precondition: the mirror order {self.mirror_order_as_source_ids()} != source order {before}")
        moved = before[-1]
        self.sock.call("surface.reorder", {"workspace_id": self.source_id, "surface_id": moved, "index": 0})
        # The reorder lands on the source on the next main-actor turn.

        def reordered() -> Optional[List[str]]:
            after = self.ordered_surfaces(self.source_id)
            return after if after != before and after[0] == moved else None

        after = wait_for(f"the source to move {moved} first", reordered, 5.0, interval_s=0.1)

        def follows() -> bool:
            mirror = self.mirror_order_as_source_ids()
            if mirror != after:
                raise Failure(f"mirror order {mirror} != source order {after}")
            return True

        result = self.timed("the mirror's tab order to follow the source", follows)
        return {"before": before, "after": after, "latency_seconds": result["latency_seconds"]}

    def stayed_in_background(self) -> Dict[str, Any]:
        self.sample_selection()
        if any(self.selection_samples):
            raise Failure(f"the source workspace was selected during the run: {self.selection_samples}")
        return {"samples": len(self.selection_samples)}

    # -- run ------------------------------------------------------------------

    def cleanup(self) -> None:
        if self.keep:
            return
        for workspace_id in (self.mirror_id, self.source_id):
            if not workspace_id:
                continue
            try:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except Failure as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        ok = self.step("setup", self.setup) and self.step("source_gets_mirror", self.source_gets_mirror)
        if ok:
            for name, check in [
                ("socket_new_tab_reaches_mirror", self.socket_new_tab),
                ("phone_new_tab_reaches_mirror", self.phone_new_tab),
                ("closed_tab_leaves_mirror", self.closed_tab),
                ("reorder_follows", self.reorder),
                ("source_stayed_in_background", self.stayed_in_background),
            ]:
                ok = self.step(name, check) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait before a check gives up")
    parser.add_argument("--latency", type=float, default=1.0, help="max seconds for a tab change to reach the mirror")
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
        test = TabSyncE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-tab-sync-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_tab_sync_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
