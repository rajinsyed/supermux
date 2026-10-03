#!/usr/bin/env python3
"""End-to-end test for a project row's worktree pill ("⑂ N ›"), on the loopback device.

Talks to a tagged DEBUG build launched with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1
and a scratch SUPERMUX_PROJECTS_FILE (see
plans/supermux-remote-workspaces/LOOPBACK-HARNESS.md). The loopback device is
this same app, so a scratch project has a copy on This Mac and one on the
online "Loopback Mac": exactly the case where every project row used to show a
number-less pill. `supermux.devices.projects_presentation` reports each row's
pill as the row draws it (`worktree_disclosure {shown, count}`, built by the
same SupermuxWorktreeDisclosure the view uses). Nothing here expands a row or
calls `supermux.devices.remote_worktrees` (both load the other Mac's list on
their own); only the background refresh (`remote_projects {refresh: true}`,
what a link connect, a projects/run event or the safety-net timer runs) does.
That refresh starts the worktree sweep without waiting for it, so the steps
poll until the lists land.

Steps:
  1. device_connected: the loopback device is connected and serves
     supermux.projects.v1 and supermux.worktrees.v1.
  2. project_registered: a fresh scratch git repo (no worktrees, a unique fake
     origin) is registered through the device's project.create, and the
     unified list has it on This Mac and the loopback device.
  3. pill_hidden_without_worktrees: the project's row shows no pill (count 0),
     and the Loopback Mac's worktree list for it loads (empty) at refresh.
  4. pill_counts_worktree_loaded_at_refresh: after worktree.create {open:
     false} over the device, the pill shows with a count, and the row carries
     the Loopback Mac's copy of the worktree, still without any expand.
  5. pill_ignores_open_and_mirrored_worktrees: once that worktree and the
     main checkout are open here (and mirrored from the Loopback Mac), the
     pill is gone again (count 0).
  6. remote_only_rows_follow_the_rule: every remote-only row shows its pill
     only while its Mac is online and has a worktree to reveal. The loopback
     shares this Mac's list, so it has no remote-only rows: the step is then
     reported as skipped (`ok: null`), never as passed. That rule is checked
     by dogfooding on a real second Mac (a project only there shows no pill
     without worktrees, and "⑂ 1 ›" with one).

Steps 3 and 4 also capture the window (best effort, listed under
`facts.screenshots`: tests/supermux/artifacts/loopback_worktree_disclosure_e2e-<tag>-*.png)
for a visual check: no pill, then "⑂ N ›".

Prints a JSON report, writes it to tests/supermux/artifacts/ (or --report),
exits non-zero on any failed check. Stdlib only (the screenshots shell out to
swiftc and screencapture).

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_worktree_disclosure_e2e.py [--keep] [--scratch /tmp/<tag>]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_device_smoke import (  # noqa: E402
    ARTIFACTS_DIR,
    LOOPBACK_MACHINE_PREFIX,
    SmokeFailure,
    SocketClient,
    norm,
    socket_path_for_tag,
    wait_for,
)
from loopback_projects_e2e import WINDOW_ID_SWIFT, git  # noqa: E402


class DisclosureE2E:
    def __init__(self, client: SocketClient, tag: str, scratch: Path, timeout_s: float, keep: bool) -> None:
        self.client = client
        self.tag = tag
        self.timeout_s = timeout_s
        self.keep = keep
        self.nonce = uuid.uuid4().hex[:8]
        self.root = scratch / f"disclosure-{self.nonce}"
        self.repo = self.root / "repo"
        self.origin = f"git@github.com:supermux-e2e/disclosure-{self.nonce}.git"
        self.identity = f"github.com/supermux-e2e/disclosure-{self.nonce}"
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "scratch": str(self.root)}
        self.machine: Optional[str] = None
        self.project_id: Optional[str] = None
        self.worktree_path: Optional[str] = None
        self.sources: List[str] = []  # workspaces this test opened here
        self.mirrors: List[str] = []  # their mirrors

    # -- helpers -------------------------------------------------------------

    def request(self, method: str, params: Dict[str, Any], timeout_s: float = 60) -> Dict[str, Any]:
        result = self.client.call(
            "supermux.devices.request",
            {"machine": self.machine, "method": method, "params": params, "timeout_seconds": timeout_s},
            timeout_s=timeout_s + 5,
        ) or {}
        return result.get("result") or {}

    def refresh_remote(self) -> Dict[str, Any]:
        """The background refresh of every connected Mac (never an expand)."""
        return self.client.call("supermux.devices.remote_projects", {"refresh": True}, timeout_s=120) or {}

    def remote_worktree_list(self, remote: Dict[str, Any]) -> Optional[List[Dict[str, Any]]]:
        """The Loopback Mac's loaded worktree list for the project, or None before it loads."""
        device = next((d for d in remote.get("devices") or [] if d.get("machine") == self.machine), None)
        lists = (device or {}).get("worktrees") or {}
        return next((v for k, v in lists.items() if norm(k) == norm(self.project_id)), None)

    def local_row(self) -> Dict[str, Any]:
        presentation = self.client.call("supermux.devices.projects_presentation", {}) or {}
        row = next(
            (r for r in presentation.get("local_rows") or [] if norm(r.get("local_project_id")) == norm(self.project_id)),
            None,
        )
        if row is None:
            raise SmokeFailure(f"projects_presentation has no local row for {self.project_id}")
        if not isinstance(row.get("worktree_disclosure"), dict):
            raise SmokeFailure(f"the local row reports no worktree_disclosure: {row}")
        return row

    def nested_rows(self) -> List[str]:
        rows = self.client.call("supermux.devices.sidebar_rows", {}) or {}
        project = next((p for p in rows.get("projects") or [] if norm(p.get("project_id")) == norm(self.project_id)), {})
        return [norm(r.get("workspace_id")) for r in project.get("rows") or []]

    def open_with_mirror(self, label: str, result: Dict[str, Any]) -> Dict[str, str]:
        """Records a workspace the host opened here and waits for its mirror
        (the auto-mirror's, reused when it is already open or in flight)."""
        source = result.get("workspace_id")
        if not source:
            raise SmokeFailure(f"{label} opened no workspace: {result}")
        self.sources.append(source)
        opened = self.client.call(
            "supermux.devices.await_open",
            {"machine": self.machine, "remote_workspace_id": source, "focus": False, "timeout_seconds": self.timeout_s},
            timeout_s=self.timeout_s + 10,
        ) or {}
        mirror = opened.get("workspace_id")
        if not mirror:
            raise SmokeFailure(f"no mirror of the {label} workspace: {opened}")
        self.mirrors.append(mirror)
        return {"source": source, "mirror": mirror}

    def screenshot(self, name: str) -> None:
        """Best effort: the window as drawn, for a visual check of the pill."""
        path = ARTIFACTS_DIR / f"loopback_worktree_disclosure_e2e-{self.tag or 'socket'}-{name}.png"
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory() as scratch:
                source = Path(scratch) / "winid.swift"
                binary = Path(scratch) / "winid"
                source.write_text(WINDOW_ID_SWIFT)
                subprocess.run(["swiftc", "-O", "-o", str(binary), str(source)], check=True, capture_output=True, timeout=300)
                time.sleep(0.5)
                window = subprocess.run([str(binary), self.tag or "cmux DEV"], capture_output=True, text=True, timeout=30)
            number = window.stdout.strip()
            if not number or number == "0":
                raise OSError("no on-screen window")
            subprocess.run(["screencapture", "-x", "-o", "-l", number, str(path)], check=True, timeout=30)
            self.facts.setdefault("screenshots", []).append(str(path))
        except (OSError, subprocess.SubprocessError) as error:
            self.facts.setdefault("screenshot_errors", []).append(f"{name}: {error}")

    def step(self, name: str, action: Callable[[], Dict[str, Any]]) -> None:
        started = time.monotonic()
        record: Dict[str, Any] = {"name": name}
        try:
            record.update(action() or {})
            # A step with nothing to check says why under "skipped"; it is not a pass.
            record["ok"] = None if record.get("skipped") else True
        except SmokeFailure as error:
            record["ok"] = False
            record["error"] = str(error)
        record["seconds"] = round(time.monotonic() - started, 2)
        self.steps.append(record)
        if record["ok"] is False:
            raise SmokeFailure(f"{name}: {record['error']}")

    # -- steps ---------------------------------------------------------------

    def check_device(self) -> Dict[str, Any]:
        def probe() -> Optional[Dict[str, Any]]:
            devices = (self.client.call("supermux.devices.list", {"include_capabilities": True}) or {}).get("devices") or []
            for device in devices:
                if str(device.get("machine", "")).startswith(LOOPBACK_MACHINE_PREFIX) and device.get("link_state") == "connected":
                    return device
            raise SmokeFailure("no connected loopback device (is SUPERMUX_DEBUG_LOOPBACK_DEVICE=1 set?)")

        device = wait_for("the loopback device", probe, self.timeout_s)
        missing = {"supermux.projects.v1", "supermux.worktrees.v1"} - set(device.get("capabilities") or [])
        if missing:
            raise SmokeFailure(f"host does not advertise {sorted(missing)}")
        self.machine = device["machine"]
        return {"machine": self.machine}

    def register_project(self) -> Dict[str, Any]:
        self.repo.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=self.repo)
        git("config", "user.email", "e2e@example.com", cwd=self.repo)
        git("config", "user.name", "Supermux E2E", cwd=self.repo)
        (self.repo / "README.md").write_text(f"worktree disclosure e2e {self.nonce}\n")
        git("add", "README.md", cwd=self.repo)
        git("commit", "-q", "-m", "init", cwd=self.repo)
        git("remote", "add", "origin", self.origin, cwd=self.repo)
        project = self.request("mobile.supermux.project.create", {"root_path": str(self.repo)}).get("project") or {}
        self.project_id = project.get("id")
        if not self.project_id:
            raise SmokeFailure(f"project.create returned no project: {project}")

        def merged() -> Optional[Dict[str, Any]]:
            unified = self.client.call("supermux.devices.unified_projects", {}) or {}
            for candidate in unified.get("projects") or []:
                if candidate.get("git_remote_identity") == self.identity and len(candidate.get("locations") or []) == 2:
                    return candidate
            return None

        unified = wait_for("the project on This Mac and the loopback device", merged, self.timeout_s)
        return {"project_id": self.project_id, "unified_id": unified["id"]}

    def check_hidden_without_worktrees(self) -> Dict[str, Any]:
        """(a) No worktrees anywhere: no pill, even though the project's other
        copy is on an online Mac; that Mac's (empty) list loads at refresh."""
        first = wait_for("the project's local row", self.local_row, self.timeout_s)["worktree_disclosure"]
        if first.get("shown") or first.get("count") != 0:
            raise SmokeFailure(f"the worktree pill shows for a project with no worktrees: {first}")

        def loaded() -> Optional[Dict[str, Any]]:
            listed = self.remote_worktree_list(self.refresh_remote())
            return {"worktrees": listed} if listed is not None else None

        try:
            listed = wait_for("the Loopback Mac's worktree list to load at refresh", loaded, self.timeout_s)["worktrees"]
        except SmokeFailure as error:
            raise SmokeFailure(f"{error}: a refresh never loads it (only an expand does)") from None
        if listed:
            raise SmokeFailure(f"a fresh repo lists worktrees on the Loopback Mac: {listed}")
        disclosure = self.local_row()["worktree_disclosure"]
        if disclosure.get("shown") or disclosure.get("count") != 0:
            raise SmokeFailure(f"the worktree pill shows for a project with no worktrees: {disclosure}")
        self.screenshot("no-worktrees")
        return {"worktree_disclosure": disclosure, "loopback_worktrees": listed}

    def check_counts_worktree(self) -> Dict[str, Any]:
        """(b) A worktree made on the other Mac shows in the pill with its
        number, from a refresh alone."""
        created = self.request(
            "mobile.supermux.worktree.create",
            {"project_id": self.project_id, "branch_name": f"disclosure-{self.nonce}", "open": False},
            timeout_s=120,
        )
        self.worktree_path = (created.get("worktree") or {}).get("path")
        if not self.worktree_path:
            raise SmokeFailure(f"worktree.create returned no worktree: {created}")

        def counted() -> Optional[Dict[str, Any]]:
            self.refresh_remote()
            row = self.local_row()
            disclosure = row["worktree_disclosure"]
            remote_paths = [w.get("path") for w in row.get("worktrees") or []]
            if disclosure.get("shown") and disclosure.get("count", 0) >= 1 and self.worktree_path in remote_paths:
                return row
            return None

        try:
            row = wait_for("the pill to count the new worktree from the Loopback Mac's list", counted, self.timeout_s)
        except SmokeFailure as error:
            raise SmokeFailure(f"{error}; last row: {self.local_row()}") from None
        self.screenshot("one-worktree")
        return {"worktree_path": self.worktree_path, "worktree_disclosure": row["worktree_disclosure"],
                "loopback_worktrees": row.get("worktrees")}

    def check_ignores_open_and_mirrored(self) -> Dict[str, Any]:
        """(c) Open worktrees (here, and there with a mirror here) and the
        main checkout's workspace add nothing to the pill."""
        worktree = self.open_with_mirror("worktree", self.request(
            "mobile.supermux.worktree.open",
            {"project_id": self.project_id, "worktree_path": self.worktree_path, "select": False},
        ))
        root = self.open_with_mirror("main checkout", self.request(
            "mobile.supermux.project.open", {"project_id": self.project_id, "select": False},
        ))
        expected = {norm(w) for w in (*worktree.values(), *root.values())}

        def cleared() -> Optional[Dict[str, Any]]:
            self.refresh_remote()
            if not expected <= set(self.nested_rows()):
                return None
            row = self.local_row()
            disclosure = row["worktree_disclosure"]
            if not disclosure.get("shown") and disclosure.get("count") == 0:
                return row
            return None

        try:
            row = wait_for("the pill to clear once every worktree is open here", cleared, self.timeout_s)
        except SmokeFailure as error:
            raise SmokeFailure(f"{error}; nested {self.nested_rows()}, want {sorted(expected)}; "
                               f"last row: {self.local_row()}") from None
        return {"worktree": worktree, "main_checkout": root, "worktree_disclosure": row["worktree_disclosure"]}

    def check_remote_only_rows(self) -> Dict[str, Any]:
        """(d) A remote-only row follows the same rule: a pill only while its
        Mac is online and has an unopened worktree. Skipped when there is no
        such row (always on loopback, which shares this Mac's project list)."""
        rows = (self.client.call("supermux.devices.projects_presentation", {}) or {}).get("remote_only_rows") or []
        if not rows:
            return {"skipped": "no remote-only project rows (the loopback shares this Mac's project list); "
                               "check the remote-only pill on a real second Mac"}
        checked = []
        for row in rows:
            disclosure = row.get("worktree_disclosure")
            if not isinstance(disclosure, dict):
                raise SmokeFailure(f"a remote-only row reports no worktree_disclosure: {row}")
            count = len(row.get("worktrees") or [])
            want = bool(row.get("is_online")) and count > 0
            if disclosure.get("shown") != want or disclosure.get("count") != count:
                raise SmokeFailure(f"remote-only row {row.get('name')!r} pill {disclosure}, want shown={want} count={count}")
            checked.append({"name": row.get("name"), "is_online": row.get("is_online"), "worktree_disclosure": disclosure})
        return {"remote_only_rows_checked": len(checked), "rows": checked}

    # -- cleanup -------------------------------------------------------------

    def cleanup(self) -> None:
        if self.keep:
            return
        errors: List[str] = []

        def attempt(action: Callable[[], Any]) -> None:
            try:
                action()
            except SmokeFailure as error:
                errors.append(str(error))

        # Sources first: auto-mirror then closes their mirrors.
        for workspace_id in [*self.sources, *self.mirrors]:
            attempt(lambda w=workspace_id: self.close_workspace_if_open(w))
        if self.project_id and self.machine:
            if self.worktree_path:
                attempt(lambda: self.request(
                    "mobile.supermux.worktree.remove",
                    {"project_id": self.project_id, "worktree_path": self.worktree_path, "force": True, "delete_branch": True},
                    timeout_s=120,
                ))
            attempt(lambda: self.request("mobile.supermux.project.delete", {"project_id": self.project_id}))
        shutil.rmtree(self.root, ignore_errors=True)
        if errors:
            self.facts["cleanup_errors"] = errors

    def close_workspace_if_open(self, workspace_id: str) -> None:
        time.sleep(0.3)
        for window in (self.client.call("window.list", {}) or {}).get("windows") or []:
            window_id = window.get("id") or window.get("window_id")
            rows = (self.client.call("workspace.list", {"window_id": window_id}) or {}).get("workspaces") or []
            if any(norm(r.get("id")) == norm(workspace_id) for r in rows):
                self.client.call("workspace.close", {"workspace_id": workspace_id, "force": True})
                return

    def run(self) -> bool:
        try:
            self.step("device_connected", self.check_device)
            self.step("project_registered", self.register_project)
            self.step("pill_hidden_without_worktrees", self.check_hidden_without_worktrees)
            self.step("pill_counts_worktree_loaded_at_refresh", self.check_counts_worktree)
            self.step("pill_ignores_open_and_mirrored_worktrees", self.check_ignores_open_and_mirrored)
            self.step("remote_only_rows_follow_the_rule", self.check_remote_only_rows)
            return True
        except SmokeFailure:
            return False
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            self.steps.append({"name": "transport", "ok": False, "error": repr(error)})
            return False
        finally:
            self.cleanup()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"), help="tagged build (default: $CMUX_TAG)")
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--scratch", help="scratch folder for the test repo (default: /tmp/<tag>)")
    parser.add_argument("--timeout", type=float, default=45.0, help="seconds to wait for each check")
    parser.add_argument("--keep", action="store_true", help="leave the workspaces, worktree and project in place")
    parser.add_argument("--report", help="report path (default: tests/supermux/artifacts/loopback_worktree_disclosure_e2e-<tag>.json)")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    socket_path = args.socket or socket_path_for_tag(args.tag)
    scratch = Path(args.scratch or f"/tmp/{args.tag or 'supermux-e2e'}")

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with SocketClient(socket_path, timeout_s=60) as client:
            e2e = DisclosureE2E(client, args.tag or "", scratch, timeout_s=args.timeout, keep=args.keep)
            passed = e2e.run()
            steps, facts = e2e.steps, e2e.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-worktree-disclosure-e2e",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    default_report = ARTIFACTS_DIR / f"loopback_worktree_disclosure_e2e-{args.tag or 'socket'}.json"
    report_path = Path(args.report) if args.report else default_report
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
