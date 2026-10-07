#!/usr/bin/env python3
"""End-to-end test of reordering a project's workspaces from the iPhone and from
the Mac, against one tagged DEBUG build running the loopback device.

The loopback device is this same app's own mobile host, so a request sent to it
(`supermux.devices.request`) reaches the exact handlers a phone's request does.
The phone lists workspaces from `mobile.workspace.list` (nesting a workspace
under the project its `supermux_project_id` names) and sends a nested row's
drag as upstream's `workspace.move` with a `before_workspace_id` worked out by
`SupermuxNestedReorderPolicy` (a drop between rows: the next row of the
project; a drop at the project's end: the next tab of that window outside the
project, or none). Checks:

  1. setup                      the loopback linked and fetched
  2. project_with_three_rows    a scratch project with three worktree workspaces
                                (alpha, beta, gamma) and a loose workspace
  3. phone_matches_mac          the phone's project order is the Mac sidebar's
  4. phone_drag_to_top          gamma dropped above alpha: the Mac sidebar and the
                                phone's list both read gamma, alpha, beta
  5. phone_drag_to_end          gamma dropped below beta (the project's end): both
                                read alpha, beta, gamma, and no tab outside the
                                project changed place
  6. phone_drag_between         alpha dropped between beta and gamma: both read
                                beta, alpha, gamma
  7. mac_drag_reaches_phone     the Mac sidebar's drag (a TabManager reorder, here
                                over the socket) puts gamma first, and the phone's
                                list follows
  8. sidebar_screenshot         the window, for the report

Writes a JSON report (default tests/supermux/artifacts/loopback_nested_reorder_e2e-<tag>.json)
plus the sidebar screenshot next to it, and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_nested_reorder_e2e.py [--scratch /tmp/<tag>/reorder] [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_auto_mirror_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    LOOPBACK_DEVICE_ID,
    Failure,
    Socket,
    socket_path_for_tag,
    up,
    wait_for,
)


def git(*args: str, cwd: Path) -> None:
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise Failure(f"git {' '.join(args)}: {result.stderr.strip()}")


def phone_anchor(order: List[str], moved: str, window: List[str]) -> Optional[str]:
    """`SupermuxNestedReorderPolicy.beforeWorkspaceID`: the next row of the
    project, or, dropped last, the next tab of the window after the row it now
    follows that is not in the project (None: the window's end)."""
    position = order.index(moved)
    if position + 1 < len(order):
        return order[position + 1]
    after = window.index(order[position - 1])
    return next((tab for tab in window[after + 1:] if tab not in order), None)


class NestedReorderE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.root = Path(args.scratch) / f"reorder-{self.nonce}"
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "scratch": str(self.root), "moves": []}
        self.machine = ""
        self.project_id = ""
        self.names: Dict[str, str] = {}
        self.created: List[str] = []

    # -- reads and actions ----------------------------------------------------

    def request(self, method: str, params: Dict[str, Any], timeout_s: float = 120) -> Dict[str, Any]:
        """A request the way the phone sends it: to this Mac's mobile host."""
        result = self.sock.call(
            "supermux.devices.request",
            {"machine": self.machine, "method": method, "params": params, "timeout_seconds": timeout_s},
            timeout_s=timeout_s + 5,
        ) or {}
        if result.get("error"):
            raise Failure(f"{method}: {result.get('error')}")
        return result.get("result") or {}

    def loopback_device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def phone_list(self) -> List[Dict[str, Any]]:
        return self.request("mobile.workspace.list", {}).get("workspaces") or []

    def phone_order(self) -> List[str]:
        """The project's rows as the phone nests them: its list order."""
        return [up(w.get("id")) for w in self.phone_list() if up(w.get("supermux_project_id")) == self.project_id]

    def phone_window(self, workspace_id: str) -> List[str]:
        """The phone's list of the window holding `workspace_id`, in order."""
        rows = self.phone_list()
        window = next((w.get("window_id") for w in rows if up(w.get("id")) == workspace_id), None)
        return [up(w.get("id")) for w in rows if w.get("window_id") == window]

    def mac_order(self) -> List[str]:
        """The project's rows of this Mac (not mirrors) as its sidebar draws them."""
        for project in (self.sock.call("supermux.devices.sidebar_rows", {}) or {}).get("projects") or []:
            if up(project.get("project_id")) == self.project_id:
                return [up(r.get("workspace_id")) for r in project.get("rows") or [] if not r.get("device_name")]
        return []

    def named(self, ids: List[str]) -> List[str]:
        return [self.names.get(i, i[:8]) for i in ids]

    def wait_for_order(self, expected: List[str], label: str) -> Dict[str, Any]:
        def agree() -> Optional[Dict[str, Any]]:
            mac, phone = self.mac_order(), self.phone_order()
            if mac != expected or phone != expected:
                raise Failure(f"mac={self.named(mac)} phone={self.named(phone)} expected={self.named(expected)}")
            return {"order": self.named(expected)}
        return wait_for(label, agree, self.timeout)

    def phone_drag(self, moved: str, order: List[str]) -> Dict[str, Any]:
        """Sends the drop that shows `order` the way the phone does."""
        window = self.phone_window(moved)
        anchor = phone_anchor(order, moved, window)
        window_id = next(w.get("window_id") for w in self.phone_list() if up(w.get("id")) == moved)
        params: Dict[str, Any] = {"workspace_id": moved, "window_id": window_id}
        if anchor:
            params["before_workspace_id"] = anchor
        self.request("workspace.move", params)
        self.facts["moves"].append({"moved": self.names[moved], "shown": self.named(order),
                                    "before": self.names.get(anchor or "", anchor)})
        return self.wait_for_order(order, f"{self.names[moved]} moved to {self.named(order)}")

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
        def ready() -> Optional[Dict[str, Any]]:
            device = self.loopback_device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        device = wait_for("the loopback device to connect", ready, self.timeout)
        self.machine = device["machine"]
        return {"machine": self.machine}

    def project_with_three_rows(self) -> Dict[str, Any]:
        repo = self.root / "repo"
        repo.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=repo)
        git("-c", "user.email=e2e@example.com", "-c", "user.name=Supermux E2E", "commit", "-q", "--allow-empty", "-m", "init", cwd=repo)
        project = self.request("mobile.supermux.project.create", {"root_path": str(repo)}).get("project") or {}
        self.project_id = up(project.get("id"))
        if not self.project_id:
            raise Failure(f"project.create returned no project: {project}")
        for label in ("alpha", "beta", "gamma"):
            created = self.request("mobile.supermux.worktree.create", {
                "project_id": self.project_id,
                "workspace_name": f"reorder-{label}-{self.nonce}",
                "branch_name": f"reorder-{label}-{self.nonce}",
                "open": True,
            }, timeout_s=180)
            workspace_id = up(created.get("workspace_id"))
            if not workspace_id:
                raise Failure(f"worktree.create returned no workspace: {created}")
            self.names[workspace_id] = label
            self.created.append(workspace_id)
        loose_dir = self.root / "loose"
        loose_dir.mkdir()
        loose = self.sock.call("workspace.create", {"cwd": str(loose_dir)}) or {}
        loose_id = up(loose.get("workspace_id") or loose.get("id"))
        if not loose_id:
            raise Failure(f"workspace.create returned no workspace: {loose}")
        self.names[loose_id] = "loose"
        self.created.append(loose_id)
        rows = wait_for("three nested rows on the phone and the Mac",
                        lambda: len(self.phone_order()) == 3 and len(self.mac_order()) == 3 and self.phone_order(),
                        self.timeout)
        return {"project_id": self.project_id, "phone_order": self.named(rows)}

    def phone_matches_mac(self) -> Dict[str, Any]:
        return self.wait_for_order(self.mac_order(), "the phone to list the Mac sidebar's order")

    def ids(self, *labels: str) -> List[str]:
        by_label = {label: workspace_id for workspace_id, label in self.names.items()}
        return [by_label[label] for label in labels]

    def phone_drag_to_top(self) -> Dict[str, Any]:
        self.wait_for_order(self.ids("alpha", "beta", "gamma"), "the starting order")
        return self.phone_drag(self.ids("gamma")[0], self.ids("gamma", "alpha", "beta"))

    def phone_drag_to_end(self) -> Dict[str, Any]:
        outside = [t for t in self.phone_window(self.ids("gamma")[0]) if t not in self.ids("alpha", "beta", "gamma")]
        result = self.phone_drag(self.ids("gamma")[0], self.ids("alpha", "beta", "gamma"))
        after = [t for t in self.phone_window(self.ids("gamma")[0]) if t not in self.ids("alpha", "beta", "gamma")]
        if after != outside:
            raise Failure(f"tabs outside the project moved: {self.named(outside)} -> {self.named(after)}")
        return result

    def phone_drag_between(self) -> Dict[str, Any]:
        return self.phone_drag(self.ids("alpha")[0], self.ids("beta", "alpha", "gamma"))

    def mac_drag_reaches_phone(self) -> Dict[str, Any]:
        gamma, beta = self.ids("gamma", "beta")
        self.sock.call("workspace.reorder", {"workspace_id": gamma, "before_workspace_id": beta})
        return self.wait_for_order(self.ids("gamma", "beta", "alpha"), "the phone to follow the Mac's reorder")

    def sidebar_screenshot(self) -> Dict[str, Any]:
        shot = self.sock.call("debug.window.screenshot", {"label": "nested-reorder"}) or {}
        path = str(shot.get("path") or "")
        if not path:
            raise Failure(f"debug.window.screenshot returned no path: {shot}")
        kept = Path(self.args.report_path).with_suffix("").as_posix() + "-sidebar.png"
        Path(kept).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, kept)
        return {"screenshot": kept}

    def cleanup(self) -> None:
        try:
            for workspace_id in self.created:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            if self.project_id:
                self.request("mobile.supermux.project.delete", {"project_id": self.project_id})
        except (Failure, OSError) as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))
        if not self.args.keep:
            shutil.rmtree(self.root, ignore_errors=True)

    def run(self) -> bool:
        ok = self.step("setup", self.setup) and self.step("project_with_three_rows", self.project_with_three_rows)
        if ok:
            for name, check in [
                ("phone_matches_mac", self.phone_matches_mac),
                ("phone_drag_to_top", self.phone_drag_to_top),
                ("phone_drag_to_end", self.phone_drag_to_end),
                ("phone_drag_between", self.phone_drag_between),
                ("mac_drag_reaches_phone", self.mac_drag_reaches_phone),
                ("sidebar_screenshot", self.sidebar_screenshot),
            ]:
                ok = self.step(name, check) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--scratch", default=None, help="scratch folder for the test repo (default /tmp/<tag>-reorder)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per wait")
    parser.add_argument("--keep", action="store_true", help="keep the scratch repo")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    args.scratch = args.scratch or f"/tmp/{args.tag or 'socket'}-reorder"
    args.report_path = args.report or str(ARTIFACTS_DIR / f"loopback_nested_reorder_e2e-{args.tag or 'socket'}.json")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = NestedReorderE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except (OSError, Failure) as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-nested-reorder-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
