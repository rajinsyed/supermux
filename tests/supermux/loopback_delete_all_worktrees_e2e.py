#!/usr/bin/env python3
"""End-to-end test for a project row's "Delete All Worktrees", on the loopback device.

Talks to a tagged DEBUG build launched with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1
and a scratch SUPERMUX_PROJECTS_FILE (see
plans/supermux-remote-workspaces/LOOPBACK-HARNESS.md). The loopback device is
this same app, so a scratch project has a copy on This Mac and one on the
online "Loopback Mac": its row offers Delete All for both Macs, and deleting
on the Loopback Mac goes over the device link (`worktrees.list`, then one
`worktree.remove` per worktree), exactly like another Mac.

`supermux.devices.projects_presentation` reports which Macs the row's menu
offers (`delete_all_worktrees`, built by the same SupermuxDeleteAllWorktreesMenu
the view uses). `supermux.devices.delete_all_worktrees` runs the menu item's
flow (fresh list, delete that list, then a forced pass over the dirty ones)
with the alerts' answers passed as params: `delete_branches` for the
checkbox, `force_dirty` for "Delete Anyway".

Steps:
  1. device_connected: the loopback device is connected and serves
     supermux.projects.v1 and supermux.worktrees.v1.
  2. project_registered: a scratch git repo is registered through the
     device's project.create, and the unified list has it on This Mac and the
     loopback device.
  3. menu_hidden_without_worktrees: the row offers no Delete All.
  4. menu_offers_every_mac_with_worktrees: with one worktree under
     <root>/.worktrees (worktree.create) and one made by plain git outside the
     repository, the row offers Delete All on This Mac and on the Loopback Mac.
  5. this_mac_deletes_worktrees_outside_the_folder: Delete All on This Mac
     lists and removes both worktrees (the outside one included) and their
     branches; the main checkout stays.
  6. loopback_mac_keeps_dirty_until_forced: Delete All on the Loopback Mac
     removes the clean worktrees (inside and outside the folder) and keeps the
     dirty one; a second run with "Delete Anyway" removes it too.
  7. menu_hidden_after_delete_all: no worktree is left anywhere, the main
     checkout and its files are intact, and the row offers no Delete All.

Prints a JSON report, writes it to tests/supermux/artifacts/ (or --report),
exits non-zero on any failed check. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_delete_all_worktrees_e2e.py [--keep] [--scratch /tmp/<tag>]
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
from loopback_device_smoke import (  # noqa: E402
    ARTIFACTS_DIR,
    LOOPBACK_MACHINE_PREFIX,
    SmokeFailure,
    SocketClient,
    norm,
    socket_path_for_tag,
    wait_for,
)
from loopback_projects_e2e import git  # noqa: E402


def real(path: Any) -> str:
    """Symlink-resolved path (/tmp is /private/tmp), as git and the app report it."""
    return os.path.realpath(str(path))


class DeleteAllE2E:
    def __init__(self, client: SocketClient, scratch: Path, timeout_s: float, keep: bool) -> None:
        self.client = client
        self.timeout_s = timeout_s
        self.keep = keep
        self.nonce = uuid.uuid4().hex[:8]
        self.root = scratch / f"delete-all-{self.nonce}"
        self.repo = self.root / "repo"
        self.outside = self.root / "outside"
        self.origin = f"git@github.com:supermux-e2e/delete-all-{self.nonce}.git"
        self.identity = f"github.com/supermux-e2e/delete-all-{self.nonce}"
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "scratch": str(self.root)}
        self.machine: Optional[str] = None
        self.project_id: Optional[str] = None

    # -- helpers -------------------------------------------------------------

    def request(self, method: str, params: Dict[str, Any], timeout_s: float = 60) -> Dict[str, Any]:
        result = self.client.call(
            "supermux.devices.request",
            {"machine": self.machine, "method": method, "params": params, "timeout_seconds": timeout_s},
            timeout_s=timeout_s + 5,
        ) or {}
        return result.get("result") or {}

    def refresh(self) -> None:
        """Both Macs' lists: the background refresh lists the Loopback Mac's
        worktrees, and that `worktrees.list` re-reads This Mac's (same app)."""
        self.client.call("supermux.devices.remote_projects", {"refresh": True}, timeout_s=120)
        self.client.call(
            "supermux.devices.remote_worktrees",
            {"machine": self.machine, "project_id": self.project_id},
            timeout_s=120,
        )

    def menu(self) -> List[Dict[str, Any]]:
        """The Macs the project row's Delete All offers, as the row draws them."""
        presentation = self.client.call("supermux.devices.projects_presentation", {}) or {}
        row = next(
            (r for r in presentation.get("local_rows") or [] if norm(r.get("local_project_id")) == norm(self.project_id)),
            None,
        )
        if row is None:
            raise SmokeFailure(f"projects_presentation has no local row for {self.project_id}")
        entries = row.get("delete_all_worktrees")
        if not isinstance(entries, list):
            raise SmokeFailure(f"the local row reports no delete_all_worktrees: {row}")
        return entries

    def delete_all(self, machine: Optional[str], *, delete_branches: bool, force_dirty: bool) -> Dict[str, Any]:
        params: Dict[str, Any] = {
            "project_id": self.project_id,
            "delete_branches": delete_branches,
            "force_dirty": force_dirty,
        }
        if machine:
            params["machine"] = machine
        return self.client.call("supermux.devices.delete_all_worktrees", params, timeout_s=300) or {}

    def add_outside_worktree(self, name: str) -> str:
        path = self.outside / name
        git("worktree", "add", "-q", "-b", name, str(path), cwd=self.repo)
        return real(path)

    def add_folder_worktree(self, name: str) -> str:
        created = self.request(
            "mobile.supermux.worktree.create",
            {"project_id": self.project_id, "branch_name": name, "open": False},
            timeout_s=120,
        )
        path = (created.get("worktree") or {}).get("path")
        if not path:
            raise SmokeFailure(f"worktree.create returned no worktree: {created}")
        return real(path)

    def git_worktrees(self) -> List[str]:
        """Linked worktrees of the scratch repo, straight from git."""
        listing = git("worktree", "list", "--porcelain", cwd=self.repo)
        paths = [line[len("worktree "):] for line in listing.splitlines() if line.startswith("worktree ")]
        return [real(p) for p in paths if real(p) != real(self.repo)]

    def branches(self) -> List[str]:
        return git("for-each-ref", "--format=%(refname:short)", "refs/heads", cwd=self.repo).split()

    def step(self, name: str, action: Callable[[], Dict[str, Any]]) -> None:
        started = time.monotonic()
        record: Dict[str, Any] = {"name": name}
        try:
            record.update(action() or {})
            record["ok"] = True
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
        self.outside.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=self.repo)
        git("config", "user.email", "e2e@example.com", cwd=self.repo)
        git("config", "user.name", "Supermux E2E", cwd=self.repo)
        (self.repo / "README.md").write_text(f"delete all worktrees e2e {self.nonce}\n")
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
        self.refresh()
        entries = wait_for("the project's local row", lambda: {"menu": self.menu()}, self.timeout_s)["menu"]
        if entries:
            raise SmokeFailure(f"Delete All is offered for a project with no worktrees: {entries}")
        return {"delete_all_worktrees": entries}

    def check_offers_every_mac(self) -> Dict[str, Any]:
        inside = self.add_folder_worktree(f"inside-{self.nonce}")
        outside = self.add_outside_worktree(f"outside-{self.nonce}")
        if not inside.startswith(real(self.repo / ".worktrees") + "/"):
            raise SmokeFailure(f"worktree.create made {inside}, not under <root>/.worktrees")
        want = [{"place": "this_mac", "machine": None}, {"place": "device", "machine": self.machine}]

        def offered() -> Optional[List[Dict[str, Any]]]:
            self.refresh()
            entries = self.menu()
            got = [{"place": e.get("place"), "machine": e.get("machine")} for e in entries]
            return entries if got == want and all(e.get("is_online") for e in entries) else None

        try:
            entries = wait_for("Delete All on This Mac and the Loopback Mac", offered, self.timeout_s)
        except SmokeFailure as error:
            raise SmokeFailure(f"{error}; last menu: {self.menu()}") from None
        return {"inside": inside, "outside": outside, "delete_all_worktrees": entries}

    def check_this_mac(self) -> Dict[str, Any]:
        before = sorted(self.git_worktrees())
        result = self.delete_all(None, delete_branches=True, force_dirty=False)
        listed = sorted(real(p) for p in result.get("listed") or [])
        removed = sorted(real(p) for p in result.get("removed") or [])
        if listed != before:
            raise SmokeFailure(f"Delete All on This Mac listed {listed}, git has {before}")
        if removed != before or result.get("dirty") or result.get("failures"):
            raise SmokeFailure(f"Delete All on This Mac did not remove every worktree: {result}")
        left = self.git_worktrees()
        if left:
            raise SmokeFailure(f"git still lists worktrees after Delete All on This Mac: {left}")
        if any(Path(p).exists() for p in before):
            raise SmokeFailure(f"worktree folders survive Delete All on This Mac: {[p for p in before if Path(p).exists()]}")
        if self.branches() != ["main"]:
            raise SmokeFailure(f"Delete All with delete_branches left branches: {self.branches()}")
        if not (self.repo / "README.md").exists():
            raise SmokeFailure("the main checkout lost its files")
        return {"result": result}

    def check_loopback_mac(self) -> Dict[str, Any]:
        inside = self.add_folder_worktree(f"remote-inside-{self.nonce}")
        outside = self.add_outside_worktree(f"remote-outside-{self.nonce}")
        dirty = self.add_outside_worktree(f"remote-dirty-{self.nonce}")
        (Path(dirty) / "wip.txt").write_text("uncommitted\n")

        first = self.delete_all(self.machine, delete_branches=False, force_dirty=False)
        listed = sorted(real(p) for p in first.get("listed") or [])
        if listed != sorted([inside, outside, dirty]):
            raise SmokeFailure(f"Delete All on the Loopback Mac listed {listed}, want {sorted([inside, outside, dirty])}")
        removed = sorted(real(p) for p in first.get("removed") or [])
        kept = [real(p) for p in first.get("dirty") or []]
        if removed != sorted([inside, outside]) or kept != [dirty] or first.get("failures"):
            raise SmokeFailure(f"want the clean worktrees removed and the dirty one kept, got {first}")
        if not (Path(dirty) / "wip.txt").exists():
            raise SmokeFailure("the dirty worktree's files went without Delete Anyway")
        if self.git_worktrees() != [dirty]:
            raise SmokeFailure(f"git lists {self.git_worktrees()} after the first pass, want only {dirty}")

        forced = self.delete_all(self.machine, delete_branches=False, force_dirty=True)
        if [real(p) for p in forced.get("removed") or []] != [dirty] or forced.get("dirty") or forced.get("failures"):
            raise SmokeFailure(f"Delete Anyway did not remove the dirty worktree: {forced}")
        if Path(dirty).exists():
            raise SmokeFailure("the dirty worktree's folder survives Delete Anyway")
        if sorted(self.branches()) != sorted(["main", f"remote-inside-{self.nonce}", f"remote-outside-{self.nonce}",
                                              f"remote-dirty-{self.nonce}"]):
            raise SmokeFailure(f"branches went without the checkbox: {self.branches()}")
        return {"first": first, "forced": forced}

    def check_hidden_after(self) -> Dict[str, Any]:
        if self.git_worktrees():
            raise SmokeFailure(f"git still lists worktrees: {self.git_worktrees()}")
        if not (self.repo / "README.md").exists():
            raise SmokeFailure("the main checkout lost its files")

        def hidden() -> Optional[Dict[str, Any]]:
            self.refresh()
            entries = self.menu()
            return {"menu": entries} if not entries else None

        try:
            entries = wait_for("Delete All to leave the menu", hidden, self.timeout_s)["menu"]
        except SmokeFailure as error:
            raise SmokeFailure(f"{error}; last menu: {self.menu()}") from None
        return {"delete_all_worktrees": entries}

    # -- cleanup -------------------------------------------------------------

    def cleanup(self) -> None:
        if self.keep:
            return
        if self.project_id and self.machine:
            try:
                self.request("mobile.supermux.project.delete", {"project_id": self.project_id})
            except SmokeFailure as error:
                self.facts["cleanup_errors"] = [str(error)]
        shutil.rmtree(self.root, ignore_errors=True)

    def run(self) -> bool:
        try:
            self.step("device_connected", self.check_device)
            self.step("project_registered", self.register_project)
            self.step("menu_hidden_without_worktrees", self.check_hidden_without_worktrees)
            self.step("menu_offers_every_mac_with_worktrees", self.check_offers_every_mac)
            self.step("this_mac_deletes_worktrees_outside_the_folder", self.check_this_mac)
            self.step("loopback_mac_keeps_dirty_until_forced", self.check_loopback_mac)
            self.step("menu_hidden_after_delete_all", self.check_hidden_after)
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
    parser.add_argument("--keep", action="store_true", help="leave the project and repo in place")
    parser.add_argument("--report", help="report path (default: tests/supermux/artifacts/loopback_delete_all_worktrees_e2e-<tag>.json)")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    socket_path = args.socket or socket_path_for_tag(args.tag)
    scratch = Path(args.scratch or f"/tmp/{args.tag or 'supermux-e2e'}")

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with SocketClient(socket_path, timeout_s=60) as client:
            e2e = DeleteAllE2E(client, scratch, timeout_s=args.timeout, keep=args.keep)
            passed = e2e.run()
            steps, facts = e2e.steps, e2e.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-delete-all-worktrees-e2e",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    default_report = ARTIFACTS_DIR / f"loopback_delete_all_worktrees_e2e-{args.tag or 'socket'}.json"
    report_path = Path(args.report) if args.report else default_report
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
