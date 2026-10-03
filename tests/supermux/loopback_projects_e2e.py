#!/usr/bin/env python3
"""End-to-end test for Supermux projects across Macs, on the loopback device.

Talks to a tagged DEBUG build launched with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1
and a scratch SUPERMUX_PROJECTS_FILE (never the user's real project list; see
plans/supermux-remote-workspaces/LOOPBACK-HARNESS.md and PROJECTS-API.md).
The loopback device is this same app, so its projects are this app's
projects: the checks exercise the viewer pipeline (remote-projects model,
unified merge, mirror nesting, sidebar presentation) and the host RPCs
(project.probe / project.clone) end to end. Merge rules for Macs with
different project lists are covered by the SupermuxKit package tests.

Steps:
  1. device_connected: the loopback device is connected and serves
     supermux.projects.v1 and supermux.project_setup.v1.
  2. project_registered: a scratch git repo (origin = a fake URL) is added as
     a project through the device's project.create.
  3. projects_list_carries_git_remote_url: the device's projects.list and the
     remote-projects model carry git_remote_url / its normalized identity.
  4. unified_merges_local_and_device_copy: the unified list has ONE project for
     that origin with two locations (This Mac + the loopback device).
  5. remote_worktree_create_nests_mirror: worktree.create over the device
     (the sidebar's remote New Worktree path) yields a device mirror that nests
     under the unified project and is hidden from the flat list.
  6. projectless_mirror_stays_flat: a mirror of a workspace that belongs to no
     project stays in the flat list (mirrors are never claimed by local path).
  7. remote_worktrees_listed: worktrees.list over the device includes the new
     worktree, open.
 7b. worktree_open_state_ignores_mirrors: with the worktree's device mirror
     listed first and selected (so its cwd is the same path on the other Mac),
     worktrees.list still reports the worktree open in the LOCAL workspace,
     never in the mirror (whose id the phone and other Macs never receive).
 7c. local_workspace_ignores_mirror_cwd: with that mirror still selected, a
     local workspace created without a working_directory does not start in
     the mirror's directory (a path on the other Mac).
  8. presentation_has_device_extras: the window's Projects presentation hands
     the local row its device location.
  9. probe_reports_repo_identity: project.probe over the device reports the
     repo, its origin, and a missing folder as missing.
 10. clone_registers_project: project.clone from a local bare repo registers a
     project whose origin is that repo; a second clone into the same folder is
     refused with destination_exists.
 11. removed_root_is_suppressed: after project.delete, probe reports the root
     as suppressed, so project sync never re-adds it.
 12. readd_by_other_build_keeps_suppression: another build that never saw the
     removal (this script, writing the shared projects file under its lock)
     registers the root again; folding that in here must not lift the
     suppression.
 13. suppression_shared_with_other_builds: removals are recorded next to the
     shared projects file, where every build reads them: this app's removal is
     listed there, and a removal another build recorded there is honored.
 14. project_sync_skips_loopback: a sync pass never treats the loopback
     device (which shares this app's list) as another Mac.
14b. projects_list_answers_while_a_folder_blocks: a project whose folder blocks
     every git command (its .git/config includes a named pipe nobody writes, as
     a folder behind an unanswered macOS privacy prompt blocks every file
     access) does not hold projects.list: the host answers within its bound
     (2 s, checked against 4 s) three times running, and over the link, and
     every answer keeps the healthy project's origin (the last one known).
14c. first_load_is_bounded_while_a_folder_blocks (with --app-path): the app is
     relaunched with that project still registered, so the first load waits in
     its `git worktree list` until the 30 s kill. Right after the link connects,
     projects.list (both projects, the healthy origin), run.state, project.icon,
     worktrees.list and preset.launch (a preset made for the step, into a fresh
     workspace) all answer within FIRST_LOAD_BOUND_S, and the launch opens exactly
     one terminal. A preset call that waits for the whole load misses the
     caller's 20 s deadline while the launch still runs there later.
 15. sidebar_screenshot: captures the window (nested mirror + device chip) to
     tests/supermux/artifacts/loopback_projects_e2e-<tag>.png.
 16. blocked_folder_git_never_outlives_its_bound (with --app-path): no git process
     the app starts in the blocked folder (named in its command line or running
     there) outlives its bound, checked while the pipe still blocks (the cleanup
     opens it for writing). None is left orphaned by step 14c's quit; the origin
     lookups projects.list starts there are gone 10 s later (the host kills each
     at 5 s); and a `git worktree list` still running there when the app quits
     (worktrees.list for the blocked project, 30 s kill) ends with the app. The
     app is then opened again for the cleanup.

Prints a JSON report, writes it to tests/supermux/artifacts/, exits non-zero on
any failed check. Stdlib only (the screenshot shells out to swiftc and
screencapture).

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_projects_e2e.py \
      --projects-file <the app's SUPERMUX_PROJECTS_FILE> [--keep] [--scratch /tmp/<tag>]
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
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

FAKE_ORIGIN = "git@github.com:supermux-e2e/loopback-app.git"
# Roots a user removed, shared by every build next to the projects file.
SUPPRESSION_FILE_NAME = "supermux-project-sync-suppressed.json"
FAKE_IDENTITY = "github.com/supermux-e2e/loopback-app"
# Step 14b: the host bounds each lookup projects.list makes at 2 s; this is that
# bound plus room for the socket and the main actor. A git command it waits for
# instead runs until the host kills it at 5 s.
BLOCKED_FOLDER_LIST_BOUND_S = 4.0
# Step 14c: during the first load each host call waits at most 2 s for it, and
# projects.list 2 s more for the origins and file facts; this is that plus room
# for the socket and the main actor. A call that waits for the whole load takes
# ~30 s (the blocked project's `git worktree list` runs until its kill).
FIRST_LOAD_BOUND_S = 8.0
# Step 14c is vacuous once the first load may have finished.
FIRST_LOAD_WINDOW_S = 25.0
# Step 16: the host kills an origin lookup (`git -C <root> config …`) at 5 s; a
# lookup in the blocked folder must be gone this long after it was seen.
ORIGIN_LOOKUP_GONE_S = 10.0
# Step 16: how long after the app is gone its git processes may take to be reaped.
GIT_AFTER_QUIT_S = 5.0

WINDOW_ID_SWIFT = r"""
import CoreGraphics
import Foundation
let owner = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (Int, Double) = (0, 0)
for info in list {
    guard let name = info[kCGWindowOwnerName as String] as? String, name.contains(owner),
          (info[kCGWindowLayer as String] as? Int) == 0,
          let bounds = info[kCGWindowBounds as String] as? [String: Any],
          let number = info[kCGWindowNumber as String] as? Int else { continue }
    let area = (bounds["Width"] as? Double ?? 0) * (bounds["Height"] as? Double ?? 0)
    if area > best.1 { best = (number, area) }
}
print(best.0)
"""


def git(*args: str, cwd: Optional[Path] = None) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise SmokeFailure(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


def git_working_directories() -> Dict[int, str]:
    """{pid: working directory} of every running process named git (lsof
    exits 1 when there is none)."""
    listing = subprocess.run(
        ["lsof", "-a", "-c", "git", "-d", "cwd", "-Fpcn"], capture_output=True, text=True, timeout=60
    ).stdout
    directories: Dict[int, str] = {}
    pid, name = 0, ""
    for line in listing.splitlines():
        if line.startswith("p"):
            pid, name = int(line[1:]), ""
        elif line.startswith("c"):
            name = line[1:]
        elif line.startswith("n") and name == "git":
            directories[pid] = line[1:]
    return directories


def update_shared_json(path: Path, mutate: Callable[[Dict[str, Any]], None]) -> None:
    """Edits a JSON document the way another build does: under the exclusive
    flock on its `<file>.lock` sidecar, re-read, mutate, atomic replace."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(f"{path}.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            document = json.loads(path.read_text()) if path.exists() else {}
            mutate(document)
            staged = path.with_name(f".{path.name}.{uuid.uuid4().hex}")
            staged.write_text(json.dumps(document, indent=2))
            os.replace(staged, path)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


class ProjectsE2E:
    def __init__(
        self,
        client: SocketClient,
        tag: str,
        scratch: Path,
        projects_file: Path,
        timeout_s: float,
        keep: bool,
        app_path: Optional[str] = None,
        push_state_dir: Optional[str] = None,
    ) -> None:
        self.client = client
        self.app_path = app_path
        self.push_state_dir = push_state_dir
        self.first_load_preset_id: Optional[str] = None
        self.tag = tag
        self.projects_file = projects_file
        self.timeout_s = timeout_s
        self.keep = keep
        self.nonce = uuid.uuid4().hex[:8]
        self.root = scratch / f"e2e-{self.nonce}"
        self.repo = self.root / "repo"
        self.bare = self.root / "bare" / "app.git"
        self.clone = self.root / "clone" / "app"
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "scratch": str(self.root)}
        self.machine: Optional[str] = None
        self.project_id: Optional[str] = None
        self.clone_project_id: Optional[str] = None
        self.readded_project_id: Optional[str] = None
        self.suppressed_root: Optional[str] = None
        self.blocked_project_id: Optional[str] = None
        self.blocked_repo = self.root / "blocked"
        self.blocked_fifo = self.root / "blocked.fifo"
        self.worktree_path: Optional[str] = None
        self.opened_workspaces: List[str] = []

    # -- helpers -------------------------------------------------------------

    def request(self, method: str, params: Dict[str, Any], timeout_s: float = 60) -> Dict[str, Any]:
        result = self.client.call(
            "supermux.devices.request",
            {"machine": self.machine, "method": method, "params": params, "timeout_seconds": timeout_s},
            timeout_s=timeout_s + 5,
        ) or {}
        return result.get("result") or {}

    def unified(self) -> Dict[str, Any]:
        return self.client.call("supermux.devices.unified_projects", {}) or {}

    def unified_project(self, identity: str) -> Optional[Dict[str, Any]]:
        matches = [p for p in self.unified().get("projects") or [] if p.get("git_remote_identity") == identity]
        return matches[0] if len(matches) == 1 else None

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
        if not record["ok"]:
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
        capabilities = set(device.get("capabilities") or [])
        missing = {"supermux.projects.v1", "supermux.project_setup.v1"} - capabilities
        if missing:
            raise SmokeFailure(f"host does not advertise {sorted(missing)}")
        self.machine = device["machine"]
        return {"machine": self.machine}

    def register_project(self) -> Dict[str, Any]:
        self.repo.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=self.repo)
        git("config", "user.email", "e2e@example.com", cwd=self.repo)
        git("config", "user.name", "Supermux E2E", cwd=self.repo)
        (self.repo / "README.md").write_text(f"loopback projects e2e {self.nonce}\n")
        git("add", "README.md", cwd=self.repo)
        git("commit", "-q", "-m", "init", cwd=self.repo)
        git("remote", "add", "origin", FAKE_ORIGIN, cwd=self.repo)
        self.bare.parent.mkdir(parents=True)
        git("clone", "-q", "--bare", str(self.repo), str(self.bare))
        project = self.request("mobile.supermux.project.create", {"root_path": str(self.repo)}).get("project") or {}
        self.project_id = project.get("id")
        if not self.project_id:
            raise SmokeFailure(f"project.create returned no project: {project}")
        return {"project_id": self.project_id, "root_path": project.get("root_path")}

    def check_git_remote_url(self) -> Dict[str, Any]:
        listed = self.request("mobile.supermux.projects.list", {}).get("projects") or []
        dto = next((p for p in listed if norm(p.get("id")) == norm(self.project_id)), None)
        if dto is None or dto.get("git_remote_url") != FAKE_ORIGIN:
            raise SmokeFailure(f"projects.list lacks git_remote_url={FAKE_ORIGIN}: {dto}")

        def model_has_it() -> Optional[Dict[str, Any]]:
            devices = (self.client.call("supermux.devices.remote_projects", {}) or {}).get("devices") or []
            for device in devices:
                if device.get("machine") != self.machine:
                    continue
                for project in device.get("projects") or []:
                    if norm(project.get("id")) == norm(self.project_id) and project.get("git_remote_identity") == FAKE_IDENTITY:
                        return project
            return None

        project = wait_for("the remote-projects model to list the project", model_has_it, self.timeout_s)
        return {"git_remote_url": dto.get("git_remote_url"), "model_identity": project.get("git_remote_identity")}

    def check_unified_merge(self) -> Dict[str, Any]:
        def merged() -> Optional[Dict[str, Any]]:
            project = self.unified_project(FAKE_IDENTITY)
            if project and len(project.get("locations") or []) == 2:
                return project
            return None

        project = wait_for("one unified project with two locations", merged, self.timeout_s)
        places = sorted((location.get("place"), location.get("machine")) for location in project["locations"])
        if places != sorted([("this_mac", None), ("device", self.machine)]):
            raise SmokeFailure(f"unexpected locations {places}")
        if norm(project.get("local_project_id")) != norm(self.project_id) or project.get("is_remote_only"):
            raise SmokeFailure(f"unified project not anchored on the local project: {project}")
        return {"unified_id": project["id"], "locations": project["locations"]}

    def create_remote_worktree(self) -> Dict[str, Any]:
        branch = f"e2e-{self.nonce}"
        opened = self.client.call(
            "supermux.devices.remote_worktree_create",
            {
                "machine": self.machine,
                "project_id": self.project_id,
                "workspace_name": f"remote-{self.nonce}",
                "branch_name": branch,
                "focus": True,
            },
            timeout_s=180,
        ) or {}
        mirror_id = opened.get("workspace_id")
        remote_id = opened.get("remote_workspace_id")
        if not mirror_id or not remote_id:
            raise SmokeFailure(f"no mirror opened: {opened}")
        self.opened_workspaces += [mirror_id, remote_id]
        self.facts["mirror_workspace_id"] = mirror_id
        self.facts["worktree_workspace_id"] = remote_id  # the loopback's remote workspace is local

        def nested() -> Optional[Dict[str, Any]]:
            workspaces = (self.unified().get("nesting") or {}).get("workspaces") or []
            row = next((w for w in workspaces if norm(w.get("workspace_id")) == norm(mirror_id)), None)
            if row and row.get("is_device_mirror") and norm(row.get("project_id")) == norm(self.project_id) and not row.get("in_flat_list"):
                return row
            return None

        row = wait_for("the mirror to nest under the project", nested, self.timeout_s)
        owners = self.unified().get("mirror_owners") or {}
        if norm(owners.get(mirror_id) or owners.get(mirror_id.upper())) != norm(self.project_id):
            raise SmokeFailure(f"mirror_owners does not map the mirror: {owners}")
        return {"mirror": row, "remote_workspace_id": remote_id, "branch": branch}

    def check_projectless_mirror(self) -> Dict[str, Any]:
        # At the project's root path, so its mirror is exactly what path
        # matching would wrongly claim.
        source = self.client.call(
            "workspace.create",
            {"title": f"plain-{self.nonce}", "focus": False, "working_directory": str(self.repo)},
        ) or {}
        source_id = source.get("workspace_id") or source.get("id")
        if not source_id:
            raise SmokeFailure(f"workspace.create returned {source}")
        self.opened_workspaces.append(source_id)

        def mirrored() -> Optional[Dict[str, Any]]:
            return self.client.call(
                "supermux.devices.open",
                {"machine": self.machine, "remote_workspace_id": source_id, "focus": False, "create_starter_terminal": True},
                timeout_s=60,
            )

        opened = wait_for("a mirror of the plain workspace", mirrored, self.timeout_s, interval_s=1.0)
        mirror_id = opened["workspace_id"]
        self.opened_workspaces.insert(0, mirror_id)

        def flat() -> Optional[Dict[str, Any]]:
            workspaces = (self.unified().get("nesting") or {}).get("workspaces") or []
            row = next((w for w in workspaces if norm(w.get("workspace_id")) == norm(mirror_id)), None)
            if row and row.get("is_device_mirror") and row.get("in_flat_list") and row.get("project_id") is None:
                return row
            return None

        row = wait_for("the project-less mirror to stay in the flat list", flat, self.timeout_s)
        return {"mirror": row}

    def check_remote_worktrees(self) -> Dict[str, Any]:
        result = self.client.call(
            "supermux.devices.remote_worktrees", {"machine": self.machine, "project_id": self.project_id}
        ) or {}
        worktrees = result.get("worktrees") or []
        created = [w for w in worktrees if w.get("branch") == f"e2e-{self.nonce}"]
        if len(created) != 1 or not created[0].get("is_open"):
            raise SmokeFailure(f"worktrees.list lacks the open e2e worktree: {worktrees}")
        self.worktree_path = created[0]["path"]
        return {"worktree": created[0]}

    def check_worktree_open_state_ignores_mirrors(self) -> Dict[str, Any]:
        """The worktree's device mirror (same path on the other Mac) listed first
        and selected, so its cwd is that path: worktrees.list must still report
        the worktree open in the LOCAL workspace, never in the mirror."""
        mirror_id = self.facts["mirror_workspace_id"]
        source_id = self.facts["worktree_workspace_id"]
        self.client.call("workspace.reorder", {"workspace_id": mirror_id, "index": 0})
        self.client.call("workspace.select", {"workspace_id": mirror_id})

        def mirror_at_worktree() -> Optional[str]:
            rows = (self.client.call("workspace.list", {}) or {}).get("workspaces") or []
            row = next((w for w in rows if norm(w.get("id")) == norm(mirror_id)), None)
            directory = (row or {}).get("current_directory") or ""
            same = directory and os.path.realpath(directory) == os.path.realpath(self.worktree_path or "")
            return directory if same else None

        mirror_cwd = wait_for("the mirror's cwd to be the worktree path", mirror_at_worktree, self.timeout_s)
        self.facts["mirror_cwd"] = mirror_cwd
        worktrees = (self.client.call(
            "supermux.devices.remote_worktrees", {"machine": self.machine, "project_id": self.project_id}
        ) or {}).get("worktrees") or []
        row = next((w for w in worktrees if w.get("path") == self.worktree_path), None)
        if not row or not row.get("is_open") or norm(row.get("workspace_id")) != norm(source_id):
            raise SmokeFailure(f"the worktree is not open in the local workspace {source_id} (mirror {mirror_id}): {row}")
        return {"worktree": row, "mirror": mirror_id, "mirror_cwd": mirror_cwd}

    def check_local_workspace_ignores_mirror_cwd(self) -> Dict[str, Any]:
        """A local workspace created while the mirror is selected, with no
        working_directory (so "inherit the selected workspace's directory"
        applies), never starts in the mirror's directory: that path is on the
        other Mac."""
        mirror_id = self.facts["mirror_workspace_id"]
        self.client.call("workspace.select", {"workspace_id": mirror_id})
        created = self.client.call("workspace.create", {"title": f"local-{self.nonce}", "focus": False}) or {}
        workspace_id = created.get("workspace_id")
        if not workspace_id:
            raise SmokeFailure(f"workspace.create returned {created}")
        self.opened_workspaces.append(workspace_id)

        def new_directory() -> Optional[str]:
            rows = (self.client.call("workspace.list", {}) or {}).get("workspaces") or []
            row = next((w for w in rows if norm(w.get("id")) == norm(workspace_id)), None)
            return (row or {}).get("current_directory")

        directory = wait_for("the new local workspace's directory", new_directory, self.timeout_s)
        if os.path.realpath(directory) == os.path.realpath(self.facts["mirror_cwd"]):
            raise SmokeFailure(f"the local workspace inherited the selected mirror's directory {directory}")
        return {"workspace_id": workspace_id, "current_directory": directory, "mirror_cwd": self.facts["mirror_cwd"]}

    def check_presentation(self) -> Dict[str, Any]:
        result = self.client.call("supermux.devices.projects_presentation", {}) or {}
        row = next(
            (r for r in result.get("local_rows") or [] if norm(r.get("local_project_id")) == norm(self.project_id)),
            None,
        )
        if row is None or row.get("location_count") != 2 or row.get("remote_url") != FAKE_ORIGIN:
            raise SmokeFailure(f"local row lacks its device extras: {result}")
        return {"local_row": row, "remote_only_rows": len(result.get("remote_only_rows") or [])}

    def check_probe(self) -> Dict[str, Any]:
        present = self.request("mobile.supermux.project.probe", {"root_path": str(self.repo)})
        if not (present.get("exists") and present.get("is_directory") and present.get("is_git_repo")):
            raise SmokeFailure(f"probe of the repo: {present}")
        if present.get("git_remote_url") != FAKE_ORIGIN:
            raise SmokeFailure(f"probe origin {present.get('git_remote_url')!r}")
        missing = self.request("mobile.supermux.project.probe", {"root_path": str(self.root / "missing")})
        if missing.get("exists") or missing.get("is_git_repo"):
            raise SmokeFailure(f"probe of a missing folder: {missing}")
        return {"present": present, "missing": missing}

    def check_clone(self) -> Dict[str, Any]:
        params = {"remote_url": str(self.bare), "root_path": str(self.clone)}
        project = self.request("mobile.supermux.project.clone", params, timeout_s=300).get("project") or {}
        self.clone_project_id = project.get("id")
        if not self.clone_project_id or project.get("git_remote_url") != str(self.bare):
            raise SmokeFailure(f"clone returned {project}")
        if not (self.clone / ".git").exists():
            raise SmokeFailure("no checkout at the clone root")
        identity = str(self.bare)[:-4] if str(self.bare).endswith(".git") else str(self.bare)
        wait_for(
            "the cloned project in the unified list",
            lambda: self.unified_project(identity),
            self.timeout_s,
        )
        try:
            self.request("mobile.supermux.project.clone", params, timeout_s=60)
        except SmokeFailure as error:
            if "destination_exists" not in str(error):
                raise SmokeFailure(f"second clone failed with the wrong error: {error}")
            return {"project_id": self.clone_project_id, "second_clone": "destination_exists"}
        raise SmokeFailure("a second clone into the same folder was accepted")

    def check_suppression(self) -> Dict[str, Any]:
        self.request("mobile.supermux.project.delete", {"project_id": self.clone_project_id})
        self.clone_project_id = None

        def suppressed() -> Optional[Dict[str, Any]]:
            probe = self.request("mobile.supermux.project.probe", {"root_path": str(self.clone)})
            return probe if probe.get("is_suppressed") else None

        probe = wait_for("the removed root to be suppressed", suppressed, self.timeout_s, interval_s=1.0)
        self.suppressed_root = probe.get("root_path")
        return {"probe": probe}

    def check_readd_keeps_suppression(self) -> Dict[str, Any]:
        root = self.suppressed_root
        document = json.loads(self.projects_file.read_text())
        if not any(norm(p.get("id")) == norm(self.project_id) for p in document.get("projects") or []):
            raise SmokeFailure(f"{self.projects_file} is not this app's SUPERMUX_PROJECTS_FILE")
        record_id = str(uuid.uuid4()).upper()
        record = {"id": record_id, "name": self.clone.name, "rootPath": root}
        update_shared_json(self.projects_file, lambda d: d.setdefault("projects", []).append(record))
        self.readded_project_id = record_id
        # Any save here re-reads the shared file and folds the other build's project in.
        self.request(
            "mobile.supermux.project.update",
            {"project_id": self.project_id, "patch": {"color_hex": "#3366FF"}},
        )

        def adopted() -> Optional[Dict[str, Any]]:
            listed = self.request("mobile.supermux.projects.list", {}).get("projects") or []
            return next((p for p in listed if norm(p.get("id")) == norm(record_id)), None)

        wait_for("this app to fold in the other build's project", adopted, self.timeout_s)
        # Sync bookkeeping follows a list change by about a second; watch well past it.
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            probe = self.request("mobile.supermux.project.probe", {"root_path": root})
            if not probe.get("is_suppressed"):
                raise SmokeFailure(f"another build's re-add lifted the removal's suppression: {probe}")
            time.sleep(0.5)
        return {"readded_project_id": record_id, "root_path": root}

    def check_suppression_shared(self) -> Dict[str, Any]:
        path = self.projects_file.parent / SUPPRESSION_FILE_NAME
        roots = (json.loads(path.read_text()) if path.exists() else {}).get("roots") or []
        if self.suppressed_root not in roots:
            raise SmokeFailure(f"{path} does not list this app's removal {self.suppressed_root}: {roots}")
        elsewhere = self.root / "removed-elsewhere"
        elsewhere.mkdir(parents=True, exist_ok=True)
        update_shared_json(path, lambda d: d.setdefault("roots", []).append(str(elsewhere)))
        probe = self.request("mobile.supermux.project.probe", {"root_path": str(elsewhere)})
        if not probe.get("is_suppressed"):
            raise SmokeFailure(f"a removal another build recorded is not honored here: {probe}")
        return {"suppression_file": str(path), "other_build_root": str(elsewhere)}

    def check_sync_skips_loopback(self) -> Dict[str, Any]:
        report = self.client.call("supermux.devices.project_sync", {}, timeout_s=60) or {}
        if self.machine in (report.get("devices_checked") or []):
            raise SmokeFailure(f"sync checked the loopback device: {report}")
        if report.get("registered_here") or report.get("registered_on"):
            raise SmokeFailure(f"sync registered projects against the loopback: {report}")
        return {"report": report}

    def check_blocked_folder_list(self) -> Dict[str, Any]:
        repo = self.blocked_repo
        repo.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=repo)
        os.mkfifo(self.blocked_fifo)
        # From here on every git command in the repo blocks opening the pipe.
        with open(repo / ".git" / "config", "a") as config:
            config.write(f"[include]\n\tpath = {self.blocked_fifo}\n")
        # Registered the way another build adds a project (no git run here first),
        # so no origin lookup has finished and been cached for it.
        record_id = str(uuid.uuid4()).upper()
        record = {"id": record_id, "name": f"blocked-{self.nonce}", "rootPath": str(repo)}
        update_shared_json(self.projects_file, lambda d: d.setdefault("projects", []).append(record))
        self.blocked_project_id = record_id
        self.request("mobile.supermux.project.update", {"project_id": self.project_id, "patch": {"color_hex": "#33AA66"}})

        def hosted() -> List[Dict[str, Any]]:
            payload = (self.client.call("supermux.devices.local_projects", {}, timeout_s=60) or {}).get("host_payload") or {}
            return payload.get("projects") or []

        def ids(projects: List[Dict[str, Any]]) -> List[str]:
            return [norm(p.get("id")) for p in projects]

        wait_for("the blocked project in the host's projects list", lambda: norm(record_id) in ids(hosted()), self.timeout_s)
        timings: List[float] = []
        for _ in range(3):
            started = time.monotonic()
            projects = hosted()
            timings.append(round(time.monotonic() - started, 2))
            if norm(record_id) not in ids(projects):
                raise SmokeFailure("the blocked project left the host's projects list")
            self.require_healthy_origin(projects, "the host's projects.list")
        started = time.monotonic()
        listed = self.request("mobile.supermux.projects.list", {}).get("projects") or []
        over_link = round(time.monotonic() - started, 2)
        if not any(norm(p.get("id")) == norm(record_id) for p in listed):
            raise SmokeFailure("projects.list over the link lacks the blocked project")
        self.require_healthy_origin(listed, "projects.list over the link")
        slowest = max(timings + [over_link])
        if slowest > BLOCKED_FOLDER_LIST_BOUND_S:
            raise SmokeFailure(
                f"projects.list took {timings} s on the host and {over_link} s over the link while one project's"
                f" folder blocks (bound {BLOCKED_FOLDER_LIST_BOUND_S} s)"
            )
        return {"host_seconds": timings, "link_seconds": over_link, "blocked_project_id": record_id}

    def require_healthy_origin(self, projects: List[Dict[str, Any]], where: str) -> None:
        """The healthy project keeps its origin while another project's git blocks:
        a lookup not finished in time answers the last origin known."""
        main = next((p for p in projects if norm(p.get("id")) == norm(self.project_id)), None)
        if main is None or main.get("git_remote_url") != FAKE_ORIGIN:
            raise SmokeFailure(f"{where} lost the healthy project's git_remote_url={FAKE_ORIGIN}: {main}")

    def check_first_load_bounded(self) -> Dict[str, Any]:
        if not self.app_path:
            return {"skipped": True, "reason": "needs --app-path to relaunch the app"}
        if not self.blocked_fifo.exists():
            raise SmokeFailure("step 14b's blocked project is gone; this step relaunches with it registered")
        created = self.request(
            "mobile.supermux.preset.create",
            {"name": f"first-load-{self.nonce}", "command": f"echo supermux-first-load-{self.nonce}"},
        ).get("preset") or {}
        self.first_load_preset_id = created.get("id")
        if not self.first_load_preset_id:
            raise SmokeFailure(f"preset.create returned no preset: {created}")
        launched = self.relaunch()
        self.check_device()
        connected_after = round(time.monotonic() - launched, 2)
        workspace = (self.client.call("workspace.create", {"title": f"first-load-{self.nonce}", "focus": False}) or {}).get("workspace_id")
        if not workspace:
            raise SmokeFailure("workspace.create returned no workspace_id")
        self.opened_workspaces.append(workspace)
        terminals_before = set(self.terminal_ids(workspace))
        calls = {
            "projects.list": ("mobile.supermux.projects.list", {}),
            "run.state": ("mobile.supermux.run.state", {}),
            "project.icon": ("mobile.supermux.project.icon", {"project_id": self.project_id}),
            "worktrees.list": ("mobile.supermux.worktrees.list", {"project_id": self.project_id}),
            "preset.launch": ("mobile.supermux.preset.launch", {"preset_id": self.first_load_preset_id, "workspace_id": workspace}),
        }
        outcomes = self.request_concurrently(calls)
        checked_after = round(time.monotonic() - launched, 2)
        problems: List[str] = []
        for name, outcome in outcomes.items():
            allowed = ("ok", "not_found") if name == "project.icon" else ("ok",)  # the repo has no icon
            if outcome["code"] not in allowed:
                problems.append(f"{name} answered {outcome['code']}: {outcome.get('error')}")
            if outcome["seconds"] > FIRST_LOAD_BOUND_S:
                problems.append(f"{name} took {outcome['seconds']} s (bound {FIRST_LOAD_BOUND_S} s)")
        listed = (outcomes["projects.list"].get("result") or {}).get("projects") or []
        if outcomes["projects.list"]["code"] == "ok":
            listed_ids = [norm(p.get("id")) for p in listed]
            if norm(self.blocked_project_id) not in listed_ids or norm(self.project_id) not in listed_ids:
                problems.append(f"projects.list lacks one of the two projects: {listed_ids}")
            try:
                self.require_healthy_origin(listed, "projects.list during the first load")
            except SmokeFailure as error:
                problems.append(str(error))
        if checked_after >= FIRST_LOAD_WINDOW_S:
            problems.append(f"vacuous: the calls ended {checked_after} s after the launch, when the first load may be done")
        time.sleep(3.0)  # a launch the caller gave up on would still open its terminal meanwhile
        opened = [t for t in self.terminal_ids(workspace) if t not in terminals_before]
        if len(opened) != 1:
            problems.append(f"preset.launch opened {len(opened)} terminals, expected exactly one: {opened}")
        if problems:
            raise SmokeFailure("; ".join(problems))
        return {
            "connected_after_s": connected_after,
            "checked_after_s": checked_after,
            "calls": {name: outcome["seconds"] for name, outcome in outcomes.items()},
        }

    def check_blocked_git_bounded(self) -> Dict[str, Any]:
        """No git process the app starts in the blocked folder outlives its bound,
        checked while the pipe still blocks every reader: none left by step 14c's
        quit (launchd is its parent), the origin lookups projects.list starts are
        gone after the host's 5 s kill, and a git still running there when the
        app quits ends with the app."""
        if not self.app_path:
            return {"skipped": True, "reason": "needs --app-path to quit the app"}
        if not self.blocked_fifo.exists():
            raise SmokeFailure("step 14b's blocked project is gone; this step needs its folder still blocking")
        problems: List[str] = []
        orphans = [p for p in self.blocked_git_processes() if p["ppid"] == 1]
        if orphans:
            problems.append(f"git left running in the blocked folder by the app step 14c quit: {orphans}")

        lookups: List[Dict[str, Any]] = []
        for _ in range(3):  # a lookup that just ended is not shared: the next call starts one
            self.request("mobile.supermux.projects.list", {})
            lookups = [p for p in self.blocked_git_processes() if p["names_folder"] and p["ppid"] != 1]
            if lookups:
                break
        if not lookups:
            raise SmokeFailure("projects.list started no origin lookup (git -C <folder>) in the blocked folder")
        time.sleep(ORIGIN_LOOKUP_GONE_S)
        alive = {(p["pid"], p["command"]) for p in self.blocked_git_processes()}
        lingering = [p for p in lookups if (p["pid"], p["command"]) in alive]
        if lingering:
            problems.append(f"origin lookups in the blocked folder still run {ORIGIN_LOOKUP_GONE_S:.0f} s later: {lingering}")

        # worktrees.list runs `git worktree list` there (killed at 30 s): it still
        # runs when the app quits right after.
        before = {p["pid"] for p in self.blocked_git_processes()}
        self.request_in_background("mobile.supermux.worktrees.list", {"project_id": self.blocked_project_id})
        started = wait_for(
            "the git worktree list worktrees.list starts in the blocked folder",
            lambda: [p for p in self.blocked_git_processes() if p["pid"] not in before and "worktree" in p["command"]],
            self.timeout_s,
        )
        self.quit_app()
        try:
            survivors = self.blocked_git_processes()
            deadline = time.monotonic() + GIT_AFTER_QUIT_S
            while survivors and time.monotonic() < deadline:
                time.sleep(0.5)
                survivors = self.blocked_git_processes()
        finally:
            self.launch_app()
        if survivors:
            problems.append(f"git still runs in the blocked folder after the app quit: {survivors}")
        self.check_device()
        if problems:
            raise SmokeFailure("; ".join(problems))
        return {"origin_lookups": [p["pid"] for p in lookups], "worktree_lists": [p["pid"] for p in started]}

    def terminal_ids(self, workspace_id: str) -> List[str]:
        result = self.client.call("surface.list", {"workspace_id": workspace_id}) or {}
        return [norm(s["id"]) for s in result.get("surfaces") or [] if s.get("type") == "terminal"]

    def request_concurrently(self, calls: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
        """Sends each call over the link at once, each on its own socket, and
        times it: {name: {code, seconds, result | error}}."""
        outcomes: Dict[str, Dict[str, Any]] = {}

        def send(name: str, method: str, params: Dict[str, Any]) -> None:
            started = time.monotonic()
            outcome: Dict[str, Any] = {}
            try:
                with SocketClient(self.client.path, timeout_s=90) as other:
                    result = other.call(
                        "supermux.devices.request",
                        {"machine": self.machine, "method": method, "params": params, "timeout_seconds": 60},
                        timeout_s=70,
                    ) or {}
                outcome.update(code="ok", result=result.get("result") or {})
            except (SmokeFailure, OSError) as error:
                text = str(error)
                code = next((c for c in ("not_found", "unavailable", "timed_out") if c in text), "error")
                outcome.update(code=code, error=text)
            outcome["seconds"] = round(time.monotonic() - started, 2)
            outcomes[name] = outcome

        threads = [threading.Thread(target=send, args=(name, *call), daemon=True) for name, call in calls.items()]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=90)
        missing = [name for name in calls if name not in outcomes]
        if missing:
            raise SmokeFailure(f"no answer at all for {missing}")
        return outcomes

    def request_in_background(self, method: str, params: Dict[str, Any]) -> None:
        """Sends one call over the link on a socket of its own and never waits
        for its answer (the app may quit before it answers)."""

        def send() -> None:
            try:
                with SocketClient(self.client.path, timeout_s=90) as other:
                    other.call(
                        "supermux.devices.request",
                        {"machine": self.machine, "method": method, "params": params, "timeout_seconds": 60},
                        timeout_s=70,
                    )
            except (SmokeFailure, OSError, ValueError):
                pass  # the app quit first

        threading.Thread(target=send, daemon=True).start()

    def blocked_git_processes(self) -> List[Dict[str, Any]]:
        """Live git processes working in the blocked folder: named in their
        command line (`git -C <folder> …`) or running there (`git worktree list`)."""
        folders = {str(self.blocked_repo), os.path.realpath(self.blocked_repo)}
        in_folder = re.compile("(" + "|".join(re.escape(folder) for folder in folders) + r")(/|\s|$)")
        working_directories = git_working_directories()
        table = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,stat=,etime=,command="], capture_output=True, text=True, timeout=30
        ).stdout
        found: List[Dict[str, Any]] = []
        for row in table.splitlines():
            fields = row.split(None, 4)
            if len(fields) < 5 or fields[2].startswith("Z") or int(fields[0]) not in working_directories:
                continue
            pid, command = int(fields[0]), fields[4]
            names_folder = in_folder.search(command) is not None
            if names_folder or in_folder.match(working_directories[pid]):
                found.append(
                    {"pid": pid, "ppid": int(fields[1]), "elapsed": fields[3], "command": command, "names_folder": names_folder}
                )
        return found

    def relaunch(self) -> float:
        """Quits the app and opens it again with the runner's environment;
        returns when its socket answers, with the moment it was opened."""
        self.quit_app()
        return self.launch_app()

    def quit_app(self) -> None:
        """Quits the app; returns once it no longer runs."""
        app = str(self.app_path)
        bundle_id = plistlib.loads((Path(app) / "Contents" / "Info.plist").read_bytes())["CFBundleIdentifier"]
        self.client.__exit__()
        subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to quit'], check=False, capture_output=True)

        def running() -> bool:
            script = f'application id "{bundle_id}" is running'
            result = subprocess.run(["osascript", "-e", script], check=False, capture_output=True, text=True)
            return result.stdout.strip() == "true"

        wait_for("the app to quit", lambda: not running(), 60)

    def launch_app(self) -> float:
        """Opens the app with the runner's environment; returns when its socket
        answers, with the moment it was opened."""
        app = str(self.app_path)
        env = {"SUPERMUX_DEBUG_LOOPBACK_DEVICE": "1", "SUPERMUX_PROJECTS_FILE": str(self.projects_file)}
        if self.push_state_dir:
            env["SUPERMUX_PHONE_PUSH_STATE_DIR"] = self.push_state_dir
        env_args = [arg for key, value in env.items() for arg in ("--env", f"{key}={value}")]
        launched = time.monotonic()
        subprocess.run(["open", "-g", *env_args, app], check=True)

        def socket_alive() -> bool:
            try:
                with SocketClient(self.client.path, timeout_s=3) as probe:
                    probe.call("supermux.devices.list", {})
                return True
            except (OSError, SmokeFailure):
                return False

        wait_for("the relaunched app's socket", socket_alive, 60)
        self.client.__enter__()
        return launched

    def _unblock_folder(self) -> None:
        """Lets every git process waiting on the pipe go (an empty include) and
        removes it, so the blocked project deletes like any other. A git that an
        app which quit left behind there (launchd its parent: no deadline ends it
        any more, and the pipe may not wake it) is ended first."""
        if not self.blocked_fifo.exists():
            return
        try:
            orphans = [p["pid"] for p in self.blocked_git_processes() if p["ppid"] == 1]
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            orphans = []
            self.facts.setdefault("cleanup_errors", []).append(f"listing blocked git processes: {error}")
        for pid in orphans:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass  # already gone
        if orphans:
            self.facts["ended_orphaned_git"] = orphans
        try:
            os.close(os.open(self.blocked_fifo, os.O_WRONLY | os.O_NONBLOCK))
        except OSError:
            pass  # nobody is waiting on it
        self.blocked_fifo.unlink()

    def capture_screenshot(self) -> Dict[str, Any]:
        path = ARTIFACTS_DIR / f"loopback_projects_e2e-{self.tag}.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as scratch:
            source = Path(scratch) / "winid.swift"
            binary = Path(scratch) / "winid"
            source.write_text(WINDOW_ID_SWIFT)
            subprocess.run(["swiftc", "-O", "-o", str(binary), str(source)], check=True, capture_output=True, timeout=300)
            owner = self.tag or "cmux DEV"
            time.sleep(1.0)
            window = subprocess.run([str(binary), owner], capture_output=True, text=True, timeout=30).stdout.strip()
        if not window or window == "0":
            raise SmokeFailure(f"no on-screen window for {owner}")
        subprocess.run(["screencapture", "-x", "-o", "-l", window, str(path)], check=True, timeout=30)
        return {"screenshot": str(path), "window_number": int(window)}

    # -- cleanup -------------------------------------------------------------

    def cleanup(self) -> None:
        if self.keep:
            return
        for workspace_id in self.opened_workspaces:
            try:
                self.client.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except SmokeFailure as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))
        self._unblock_folder()
        for action in (self._remove_worktree, self._delete_projects):
            try:
                action()
            except SmokeFailure as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))
        shutil.rmtree(self.root, ignore_errors=True)

    def _remove_worktree(self) -> None:
        if self.worktree_path and self.project_id:
            self.request(
                "mobile.supermux.worktree.remove",
                {"project_id": self.project_id, "worktree_path": self.worktree_path, "force": True, "delete_branch": True},
                timeout_s=120,
            )

    def _delete_projects(self) -> None:
        if self.first_load_preset_id:
            self.request("mobile.supermux.preset.delete", {"preset_id": self.first_load_preset_id})
        for project_id in (self.blocked_project_id, self.clone_project_id, self.readded_project_id, self.project_id):
            if project_id:
                self.request("mobile.supermux.project.delete", {"project_id": project_id})

    def run(self) -> bool:
        try:
            self.step("device_connected", self.check_device)
            self.step("project_registered", self.register_project)
            self.step("projects_list_carries_git_remote_url", self.check_git_remote_url)
            self.step("unified_merges_local_and_device_copy", self.check_unified_merge)
            self.step("remote_worktree_create_nests_mirror", self.create_remote_worktree)
            self.step("projectless_mirror_stays_flat", self.check_projectless_mirror)
            self.step("remote_worktrees_listed", self.check_remote_worktrees)
            self.step("worktree_open_state_ignores_mirrors", self.check_worktree_open_state_ignores_mirrors)
            self.step("local_workspace_ignores_mirror_cwd", self.check_local_workspace_ignores_mirror_cwd)
            self.step("presentation_has_device_extras", self.check_presentation)
            self.step("probe_reports_repo_identity", self.check_probe)
            self.step("clone_registers_project", self.check_clone)
            self.step("removed_root_is_suppressed", self.check_suppression)
            self.step("readd_by_other_build_keeps_suppression", self.check_readd_keeps_suppression)
            self.step("suppression_shared_with_other_builds", self.check_suppression_shared)
            self.step("project_sync_skips_loopback", self.check_sync_skips_loopback)
            self.step("projects_list_answers_while_a_folder_blocks", self.check_blocked_folder_list)
            self.step("first_load_is_bounded_while_a_folder_blocks", self.check_first_load_bounded)
            self.step("sidebar_screenshot", self.capture_screenshot)
            self.step("blocked_folder_git_never_outlives_its_bound", self.check_blocked_git_bounded)
            return True
        except SmokeFailure:
            return False
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.steps.append({"name": "transport", "ok": False, "error": str(error)})
            return False
        finally:
            self.cleanup()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"), help="tagged build (default: $CMUX_TAG)")
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--scratch", help="scratch folder for test repos (default: /tmp/<tag>)")
    parser.add_argument(
        "--projects-file",
        required=True,
        help="the SUPERMUX_PROJECTS_FILE the app was launched with (edited as another build would)",
    )
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for each check")
    parser.add_argument("--keep", action="store_true", help="leave the workspaces, projects and repos in place")
    parser.add_argument("--app-path", help="the tagged .app to quit and relaunch for the first-load step (skipped without it)")
    parser.add_argument("--push-state-dir", help="SUPERMUX_PHONE_PUSH_STATE_DIR to relaunch with")
    parser.add_argument("--report", help="report path (default: tests/supermux/artifacts/loopback_projects_e2e-<tag>.json)")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    socket_path = args.socket or socket_path_for_tag(args.tag)
    scratch = Path(args.scratch or f"/tmp/{args.tag or 'supermux-e2e'}")

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with SocketClient(socket_path) as client:
            e2e = ProjectsE2E(
                client,
                args.tag or "",
                scratch,
                Path(args.projects_file),
                timeout_s=args.timeout,
                keep=args.keep,
                app_path=args.app_path,
                push_state_dir=args.push_state_dir,
            )
            passed = e2e.run()
            steps, facts = e2e.steps, e2e.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-projects-e2e",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_projects_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
