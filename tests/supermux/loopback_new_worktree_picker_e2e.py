#!/usr/bin/env python3
"""End-to-end test for the New Worktree sheet's device picker, on the loopback device.

Talks to a tagged DEBUG build launched with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1
and a scratch SUPERMUX_PROJECTS_FILE (see
plans/supermux-remote-workspaces/LOOPBACK-HARNESS.md). It drives the DEBUG
socket methods `supermux.devices.new_worktree.*`, which build a real
SupermuxNewWorktreeSheetModel exactly the way a project row does (same device
rows, default Mac, targets, create flow and mirror open); only the SwiftUI view
is absent. The loopback device is this same app, so "Loopback Mac" has the same
projects, and the workspace it creates is also a local workspace here (its id
is the remote workspace id).

Steps:
  1. device_connected: the loopback device is connected and serves
     supermux.worktrees.v1 and supermux.agent_launch.v1.
  2. project_registered: a scratch git repo (main + a second branch, fake
     origin) is registered and the unified list has it on This Mac and the
     loopback device. The remembered Mac (one global UserDefaults key) is
     cleared first and restored at the end (DEBUG `last_device {set}`).
  3. picker_lists_this_mac_and_loopback: the sheet's rows for the project are
     This Mac first, then the Loopback Mac, both able to create, and the picker
     shows.
  4. remote_branches_load: selecting the Loopback Mac makes it the target and
     loads its branches (worktrees.list include_branches) and Claude commands
     (agent.options), whose shell dialect lets its launch line be previewed.
  5. remote_error_is_localized: a create with an unknown starting branch fails
     with the other Mac's sentence (no raw code), the sheet is editable again,
     and nothing is remembered (the remembered Mac stays This Mac).
  6. plain_create_selects_mirror: Create on the Loopback Mac runs
     worktree.create over the device; the returned workspace's mirror opens,
     is bound to it, and is the selected workspace of the window, with no
     second mirror from the auto-mirror coordinator; the worktree is listed on
     the device.
  7. last_device_persisted: the remembered Mac is the Loopback Mac, and a new
     sheet preselects it.
 7b. last_device_is_global: a second project (its own origin, on both Macs)
     preselects the Loopback Mac too: one choice serves every project.
 7c. global_device_offline_falls_back_to_this_mac: with the remembered Mac's
     link held down, that second project's new sheet preselects This Mac.
 7d. fallback_create_keeps_remembered_mac: with that link held down again,
     Create on the row the second project's sheet fell back to (This Mac, no
     row picked) succeeds and leaves the remembered Mac the Loopback Mac: only
     a Mac the user chose replaces it.
  8. prompt_start_runs_agent_start: with a harmless Claude command ("echo")
     configured, Start Claude on the Loopback Mac runs agent.start; its
     workspace's terminal echoes the prompt, and its mirror opens selected.
     The command list is restored afterwards.
  9. availability_is_live: with the Loopback Mac selected and fields typed,
     its link is held down (DEBUG `supermux.devices.link`) while its options
     load: the open sheet disables it, the dropped load never shows a raw
     CancellationError, after the redial it is selectable again, and the typed
     fields and the selection survive both edges.
 10. dropped_link_create_reports_unknown_outcome /
 11. dropped_link_start_claude_reports_unknown_outcome: the link drops while
     the other Mac is still creating (a post-checkout hook slows its
     `git worktree add`): the sheet ends editable with a sentence naming the
     Mac that says the connection dropped, never silently idle and never a
     raw CancellationError.
 12. host_open_keeps_selection_for_other_macs: worktree.create {open},
     worktree.open, project.open and agent.start with `select: false` (what
     another Mac sends) leave every window's selection alone; project.open
     without it (the phone) still selects.
 13. unfocused_remote_create_keeps_selection: a remote create whose mirror
     opens without focus changes no selection on either side.
 14. prompt_images_need_text: an image attached on the Loopback Mac puts the
     sheet in Start Claude mode, hides the (not yet known) launch line and
     keeps Start disabled until there is text; a non-image is refused with a
     sentence, the same image is not added twice, and removing it re-enables
     Create.
 15. prompt_images_reach_other_mac: Start Claude on the Loopback Mac with 10
     images (the most a prompt takes) uploads them (agent.attachment.upload)
     in one operation: the terminal there echoes the prompt followed by
     "Attached images:" and all 10 paths, in order, in one folder of that
     Mac's attachment store, whose bytes match, with that folder as the one
     --add-dir (one per image overflowed the 1000-byte launch line).
 16. prompt_images_on_this_mac: the same on This Mac copies the image into a
     private folder of its own (0700, file 0600) under the cmux state
     directory, and the launch line names it the same way.
 17. agent_start_rejects_foreign_attachment_paths: agent.start with an
     attachment path outside an upload folder of the attachment store (a
     file that exists, a path that climbs out of the store, a file directly
     in the store whose --add-dir would be the whole store) is rejected
     before git runs, so no caller can make Claude read another folder
     without asking.
 18. prompt_images_convert_and_follow_links: a HEIC photo attaches as a JPEG,
     an opaque TIFF as a PNG (both copies of the image at its size), an SVG
     (which only NSImage reads) as a PNG, and a symlink to an image as the
     file it points to.

`--only a,b` runs just those steps (after 1-2) and records each result.

Prints a JSON report, writes it to tests/supermux/artifacts/ (or --report),
exits non-zero on any failed check. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_new_worktree_picker_e2e.py [--keep] [--scratch /tmp/<tag>]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import threading
import time
import uuid
import zlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

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

FAKE_ORIGIN = "git@github.com:supermux-e2e/picker-app.git"
FAKE_IDENTITY = "github.com/supermux-e2e/picker-app"
THIS_MAC = "this-mac"
PREFIX = "supermux.devices.new_worktree."


def git(*args: str, cwd: Optional[Path] = None) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise SmokeFailure(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()



def real_paths(paths: Optional[List[str]]) -> List[str]:
    """`paths` with symlinks resolved: the app drops /private from /tmp paths, Python adds it."""
    return [os.path.realpath(path) for path in paths or []]


class PickerE2E:
    def __init__(self, client: SocketClient, scratch: Path, timeout_s: float, keep: bool) -> None:
        self.client = client
        self.timeout_s = timeout_s
        self.keep = keep
        self.nonce = uuid.uuid4().hex[:8]
        self.root = scratch / f"picker-{self.nonce}"
        self.repo = self.root / "repo"
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "scratch": str(self.root)}
        self.machine: Optional[str] = None
        self.project_id: Optional[str] = None
        self.unified_id: Optional[str] = None
        self.window_id: Optional[str] = None
        self.sessions: List[str] = []
        self.created: List[Dict[str, Any]] = []  # {mirror, remote}
        self.previous_commands: Optional[Dict[str, Any]] = None
        # The remembered Mac before this run (restored in cleanup), once captured.
        self.previous_last_device: Optional[Dict[str, Any]] = None
        self.other_project_id: Optional[str] = None
        # Projects this run created, with their main checkout (deleted in cleanup).
        self.registered: Dict[str, str] = {}
        # Folders the launches copied or uploaded test images into (deleted in cleanup).
        self.image_folders: List[Path] = []

    # -- helpers -------------------------------------------------------------

    def call(self, name: str, params: Dict[str, Any], timeout_s: float = 60) -> Dict[str, Any]:
        return self.client.call(PREFIX + name, params, timeout_s=timeout_s) or {}

    def request(self, method: str, params: Dict[str, Any], timeout_s: float = 60) -> Dict[str, Any]:
        result = self.client.call(
            "supermux.devices.request",
            {"machine": self.machine, "method": method, "params": params, "timeout_seconds": timeout_s},
            timeout_s=timeout_s + 5,
        ) or {}
        return result.get("result") or {}

    def open_session(self, **extra: Any) -> Dict[str, Any]:
        state = self.call("open", {"project_id": self.project_id, **extra})
        self.sessions.append(state["session_id"])
        return state

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

    def last_device(self, **params: Any) -> Dict[str, Any]:
        """The remembered Mac (`set` replaces it and returns the previous one).
        `project_id` is ignored by the global store; older builds keyed it per
        project, so it is still sent."""
        return self.call("last_device", {"project_id": self.unified_id, **params})

    def probe_sheet(self, project_id: str) -> Dict[str, Any]:
        """A New Worktree sheet opened for `project_id` and closed again, so
        the steps' own session (`self.sessions[-1]`) stays the latest."""
        state = self.call("open", {"project_id": project_id})
        self.call("close", {"session_id": state["session_id"]})
        return state

    def remote_worktrees(self, project_id: Optional[str] = None) -> List[Dict[str, Any]]:
        """The Loopback Mac's worktrees of a project (default: the first one)."""
        listed = self.request("mobile.supermux.worktrees.list", {"project_id": project_id or self.project_id})
        return listed.get("worktrees") or []

    def selected_workspaces(self) -> List[str]:
        """Every window's selected workspace (the loopback's two Macs share them)."""
        selected: List[str] = []
        for window in (self.client.call("window.list", {}) or {}).get("windows") or []:
            window_id = window.get("id") or window.get("window_id")
            rows = (self.client.call("workspace.list", {"window_id": window_id}) or {}).get("workspaces") or []
            selected += [norm(r.get("id")) for r in rows if r.get("selected") or r.get("is_selected")]
        return sorted(selected)

    def load_on_second_connection(self, session: str) -> None:
        """Runs the sheet's `load` without blocking this connection."""
        try:
            with SocketClient(self.client.path, timeout_s=120) as other:
                other.call(PREFIX + "load", {"session_id": session}, timeout_s=120)
        except (OSError, SmokeFailure):
            pass

    def set_link(self, action: str) -> None:
        self.client.call("supermux.devices.link", {"machine": self.machine, "action": action})

    def wait_link_connected(self) -> None:
        def connected() -> Optional[bool]:
            devices = (self.client.call("supermux.devices.list", {}) or {}).get("devices") or []
            return any(d.get("machine") == self.machine and d.get("link_state") == "connected" for d in devices) or None

        wait_for("the Loopback Mac to reconnect", connected, self.timeout_s)

    def slow_worktree_add(self, seconds: int) -> Path:
        """A post-checkout hook, so `git worktree add` on the other Mac takes `seconds`."""
        hook = self.repo / ".git" / "hooks" / "post-checkout"
        hook.write_text(f"#!/bin/sh\nsleep {seconds}\n")
        hook.chmod(0o755)
        return hook

    def adopt_orphan(self, branch: str, project_id: Optional[str] = None) -> Optional[Dict[str, Any]]:
        """The worktree a create made (a dropped one, or one on This Mac that
        returns no workspace ids), its workspace and auto-mirror queued for cleanup."""
        worktree = next((w for w in self.remote_worktrees(project_id) if w.get("branch") == branch), None)
        remote_id = (worktree or {}).get("workspace_id")
        if remote_id:
            def mirrors() -> Optional[List[Dict[str, Any]]]:
                bindings = self.client.call("supermux.devices.bindings", {}) or {}
                rows = [m for m in bindings.get("mirrors") or [] if norm(m.get("remote_workspace_id")) == norm(remote_id)]
                return rows if any(m.get("is_bound") for m in rows) else None

            try:  # let auto-mirror finish, so cleanup never races a mirror mid-open
                rows = wait_for("the orphan's auto-mirror", mirrors, self.timeout_s)
            except SmokeFailure:
                rows = []
            for mirror in rows:
                self.created.append({"mirror": mirror["workspace_id"], "remote": remote_id})
            if not rows:
                self.created.append({"mirror": remote_id, "remote": remote_id})
        return worktree

    def check_mirror_selected(self, result: Dict[str, Any]) -> Dict[str, Any]:
        mirror = result.get("mirror") or {}
        remote_id = result.get("remote_workspace_id")
        if not result.get("finished") or not remote_id or not mirror.get("workspace_id"):
            raise SmokeFailure(f"create did not finish with a mirror: {result}")
        self.created.append({"mirror": mirror["workspace_id"], "remote": remote_id})
        if norm(mirror.get("remote_workspace_id")) != norm(remote_id) or mirror.get("machine") != self.machine:
            raise SmokeFailure(f"the mirror shows another workspace: {mirror}")
        if norm(mirror.get("window_id")) != norm(self.window_id):
            raise SmokeFailure(f"the mirror opened in another window: {mirror}")

        def selected() -> Optional[Dict[str, Any]]:
            bindings = self.client.call("supermux.devices.bindings", {}) or {}
            row = next(
                (m for m in bindings.get("mirrors") or [] if norm(m.get("workspace_id")) == norm(mirror["workspace_id"])),
                None,
            )
            if row and row.get("is_bound") and row.get("is_selected") and norm(row.get("remote_workspace_id")) == norm(remote_id):
                return row
            return None

        row = wait_for("the new mirror to be bound and selected", selected, self.timeout_s)
        time.sleep(2.0)  # let auto-mirror run: nothing may steal the selection or open a second mirror
        if not selected():
            raise SmokeFailure("the mirror lost the selection right after opening")
        bindings = self.client.call("supermux.devices.bindings", {}) or {}
        copies = [m for m in bindings.get("mirrors") or [] if norm(m.get("remote_workspace_id")) == norm(remote_id)]
        if len(copies) != 1:
            raise SmokeFailure(f"{len(copies)} mirrors of one remote workspace (auto-mirror raced the open): {copies}")
        if norm(remote_id) in self.selected_workspaces():
            raise SmokeFailure("the owning Mac selected its new workspace (it must open it in the background)")
        return {"mirror_workspace_id": mirror["workspace_id"], "remote_workspace_id": remote_id,
                "mirror_title": row.get("title"), "reused_in_flight_or_existing": mirror.get("reused")}

    # -- steps ---------------------------------------------------------------

    def check_device(self) -> Dict[str, Any]:
        def probe() -> Optional[Dict[str, Any]]:
            devices = (self.client.call("supermux.devices.list", {"include_capabilities": True}) or {}).get("devices") or []
            for device in devices:
                if str(device.get("machine", "")).startswith(LOOPBACK_MACHINE_PREFIX) and device.get("link_state") == "connected":
                    return device
            raise SmokeFailure("no connected loopback device (is SUPERMUX_DEBUG_LOOPBACK_DEVICE=1 set?)")

        device = wait_for("the loopback device", probe, self.timeout_s)
        missing = {"supermux.worktrees.v1", "supermux.agent_launch.v1"} - set(device.get("capabilities") or [])
        if missing:
            raise SmokeFailure(f"host does not advertise {sorted(missing)}")
        self.machine = device["machine"]
        windows = (self.client.call("window.list", {}) or {}).get("windows") or []
        if not windows:
            raise SmokeFailure("no window")
        key = next((w for w in windows if w.get("key") or w.get("is_key")), windows[0])
        self.window_id = key.get("id") or key.get("window_id")
        return {"machine": self.machine, "device_name": device.get("name"), "window_id": self.window_id}

    def create_project(self, repo: Path, origin: str, identity: str) -> Dict[str, Any]:
        """A scratch repo (main + a second branch) registered through the
        device; returns its ids once the unified list has it on both Macs."""
        repo.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=repo)
        git("config", "user.email", "e2e@example.com", cwd=repo)
        git("config", "user.name", "Supermux E2E", cwd=repo)
        (repo / "README.md").write_text(f"picker e2e {self.nonce}\n")
        git("add", "README.md", cwd=repo)
        git("commit", "-q", "-m", "init", cwd=repo)
        git("branch", f"feature-{self.nonce}", cwd=repo)
        git("remote", "add", "origin", origin, cwd=repo)
        project = self.request("mobile.supermux.project.create", {"root_path": str(repo)}).get("project") or {}
        if not project.get("id"):
            raise SmokeFailure(f"project.create returned no project: {project}")
        self.registered[project["id"]] = str(repo)

        def merged() -> Optional[Dict[str, Any]]:
            unified = self.client.call("supermux.devices.unified_projects", {}) or {}
            for candidate in unified.get("projects") or []:
                if candidate.get("git_remote_identity") == identity and len(candidate.get("locations") or []) == 2:
                    return candidate
            return None

        unified = wait_for(f"{repo.name} on This Mac and the loopback device", merged, self.timeout_s)
        return {"project_id": project["id"], "unified_id": unified["id"]}

    def register_project(self) -> Dict[str, Any]:
        created = self.create_project(self.repo, FAKE_ORIGIN, FAKE_IDENTITY)
        self.project_id, self.unified_id = created["project_id"], created["unified_id"]
        # Start with nothing remembered; cleanup puts the previous Mac back.
        self.previous_last_device = self.last_device(set=None)
        return {**created, "previous_last_device": self.previous_last_device.get("previous")}

    def ensure_other_project(self) -> str:
        """A second project on both Macs, with its own origin so it never
        merges with the first."""
        if self.other_project_id is None:
            origin = f"git@github.com:supermux-e2e/picker-app-b-{self.nonce}.git"
            identity = f"github.com/supermux-e2e/picker-app-b-{self.nonce}"
            self.other_project_id = self.create_project(self.root / "repo-b", origin, identity)["project_id"]
        return self.other_project_id

    def check_rows(self) -> Dict[str, Any]:
        state = self.open_session()
        entries = state.get("entries") or []
        keys = [e.get("device_key") for e in entries]
        if keys[:2] != [THIS_MAC, self.machine]:
            raise SmokeFailure(f"rows are {keys}, want This Mac then {self.machine}")
        if not all(e.get("kind") == "create" and e.get("can_create") for e in entries[:2]):
            raise SmokeFailure(f"a row cannot create: {entries}")
        if not state.get("shows_picker"):
            raise SmokeFailure("the picker is hidden for a project on two Macs")
        if norm(state.get("unified_project_id")) != norm(self.unified_id):
            raise SmokeFailure(f"sheet keyed to {state.get('unified_project_id')}, want {self.unified_id}")
        loopback = entries[1]
        if "Loopback" not in str(loopback.get("name")):
            raise SmokeFailure(f"loopback row name {loopback.get('name')!r}")
        return {"rows": [{k: e.get(k) for k in ("device_key", "name", "availability", "kind")} for e in entries],
                "default_row": state.get("selected_entry_id")}

    def check_remote_branches(self) -> Dict[str, Any]:
        session = self.sessions[-1]
        state = self.call("select", {"session_id": session, "entry_id": self.machine})
        target = state.get("target") or {}
        if state.get("selected_entry_id") != self.machine or target.get("remote_device_name") is None:
            raise SmokeFailure(f"the Loopback Mac did not become the target: {state}")
        if norm(target.get("project_id")) != norm(self.project_id):
            raise SmokeFailure(f"remote target uses project {target.get('project_id')}")
        state = self.call("load", {"session_id": session}, timeout_s=180)
        branches = state.get("branches") or []
        if not state.get("branches_loaded") or "main" not in branches or f"feature-{self.nonce}" not in branches:
            raise SmokeFailure(f"remote branches did not load: {state}")
        if state.get("base_branch") != "main":
            raise SmokeFailure(f"base branch {state.get('base_branch')!r}, want main")
        if not state.get("commands"):
            raise SmokeFailure(f"no Claude commands from agent.options: {state}")
        # The other Mac names its shell's dialect in agent.options, so its
        # launch line is previewed from the same code (loopback: this shell).
        preview = str(state.get("preview_line") or "")
        if not preview.startswith(str(state.get("command"))):
            raise SmokeFailure(f"the other Mac's launch line is not previewed: {preview!r}")
        return {"branches": branches, "commands": state.get("commands"), "command": state.get("command"),
                "ai_naming_configured": state.get("ai_naming_configured")}

    def check_remote_error(self) -> Dict[str, Any]:
        session = self.sessions[-1]
        # Remember This Mac, so a failed create on the Loopback Mac that was
        # remembered anyway shows up as a change.
        self.last_device(set=THIS_MAC)
        before = self.last_device().get("device_key")
        result = self.call(
            "submit",
            {"session_id": session, "workspace_name": f"bad-{self.nonce}", "branch_name": f"bad-{self.nonce}",
             "base_branch": f"no-such-base-{self.nonce}"},
            timeout_s=180,
        )
        message = result.get("error_message") or ""
        if result.get("finished") or not message:
            raise SmokeFailure(f"an unknown base branch did not fail: {result}")
        if "invalid_params" in message or result.get("phase") != "idle" or not result.get("can_create"):
            raise SmokeFailure(f"failure left the sheet unusable or shows a raw code: {result}")
        after = self.last_device().get("device_key")
        if after != before:
            raise SmokeFailure(f"a failed create was remembered: {before} -> {after}")
        return {"error_message": message}

    def check_plain_create(self) -> Dict[str, Any]:
        session = self.sessions[-1]
        branch = f"picker-plain-{self.nonce}"
        # Undo the previous step's starting-branch pick: reopen on the same Mac.
        self.call("close", {"session_id": session})
        state = self.open_session(preferred_device=self.machine)
        session = state["session_id"]
        if state.get("selected_entry_id") != self.machine:
            raise SmokeFailure(f"preferred device ignored: {state.get('selected_entry_id')}")
        self.call("load", {"session_id": session}, timeout_s=180)
        result = self.call(
            "submit",
            {"session_id": session, "workspace_name": f"picker plain {self.nonce}", "branch_name": branch},
            timeout_s=240,
        )
        facts = self.check_mirror_selected(result)
        listed = [w for w in self.remote_worktrees() if w.get("branch") == branch]
        if len(listed) != 1 or norm(listed[0].get("workspace_id")) != norm(facts["remote_workspace_id"]):
            raise SmokeFailure(f"worktrees.list lacks {branch} opened in the returned workspace: {listed}")
        facts["worktree_path"] = listed[0].get("path")
        return facts

    def check_last_device(self) -> Dict[str, Any]:
        stored = self.last_device().get("device_key")
        if stored != self.machine:
            raise SmokeFailure(f"last device {stored!r}, want {self.machine}")
        state = self.open_session()
        if state.get("selected_entry_id") != self.machine:
            raise SmokeFailure(f"a new sheet preselected {state.get('selected_entry_id')}, want the last device")
        return {"last_device": stored, "new_sheet_default": state.get("selected_entry_id")}

    def check_last_device_is_global(self) -> Dict[str, Any]:
        """The Mac the first project's worktree was just created on is the
        default for another project too. The sheet is checked first, so a
        build that remembers per project fails on what the user sees."""
        state = self.probe_sheet(self.ensure_other_project())
        entries = state.get("entries") or []
        if len(entries) < 2 or entries[1].get("device_key") != self.machine or not entries[1].get("can_create"):
            raise SmokeFailure(f"the second project's rows lack a creatable Loopback Mac: {entries}")
        if state.get("selected_entry_id") != self.machine:
            raise SmokeFailure(
                f"the second project's new sheet preselected {state.get('selected_entry_id')}, "
                f"want the Mac remembered from the first project ({self.machine})"
            )
        stored = self.call("last_device", {}).get("device_key")
        if stored != self.machine:
            raise SmokeFailure(f"the remembered Mac (no project given) is {stored!r}, want {self.machine}")
        return {"last_device": stored, "other_project_id": self.other_project_id,
                "other_sheet_default": state.get("selected_entry_id")}

    def check_global_device_offline_fallback(self) -> Dict[str, Any]:
        """The remembered Mac cannot take a create while its link is down:
        the second project's sheet falls back to This Mac."""
        other = self.ensure_other_project()
        self.last_device(set=self.machine)
        self.set_link("stop")
        try:
            def offline_sheet() -> Optional[Dict[str, Any]]:
                state = self.probe_sheet(other)
                row = next((e for e in state.get("entries") or [] if e.get("device_key") == self.machine), None)
                return state if row is not None and not row.get("can_create") else None

            state = wait_for("the second project's sheet to list the Loopback Mac as unavailable", offline_sheet, self.timeout_s)
        finally:
            self.set_link("restore")
            self.wait_link_connected()
        if state.get("selected_entry_id") != THIS_MAC:
            raise SmokeFailure(f"with the remembered Mac offline the sheet preselected {state.get('selected_entry_id')}, want {THIS_MAC}")
        loopback = next(e for e in state.get("entries") or [] if e.get("device_key") == self.machine)
        return {"selected_entry_id": state.get("selected_entry_id"),
                "offline_row": {k: loopback.get(k) for k in ("device_key", "availability", "can_create")}}

    def check_fallback_create_keeps_remembered_mac(self) -> Dict[str, Any]:
        """Create on the Mac the sheet fell back to is not a choice: with the
        remembered Mac's link down, the second project's sheet preselects This
        Mac, Create there (no row picked) finishes, and the remembered Mac is
        still the Loopback Mac."""
        other = self.ensure_other_project()
        self.last_device(set=self.machine)
        branch = f"fallback-{self.nonce}"
        session: Optional[str] = None
        self.set_link("stop")
        try:
            def offline_sheet() -> Optional[Dict[str, Any]]:
                state = self.call("open", {"project_id": other})
                row = next((e for e in state.get("entries") or [] if e.get("device_key") == self.machine), None)
                if row is not None and not row.get("can_create"):
                    return state
                self.call("close", {"session_id": state["session_id"]})
                return None

            state = wait_for("the second project's sheet to list the Loopback Mac as unavailable", offline_sheet, self.timeout_s)
            session = state["session_id"]
            if state.get("selected_entry_id") != THIS_MAC:
                raise SmokeFailure(f"with the remembered Mac offline the sheet preselected {state.get('selected_entry_id')}, want {THIS_MAC}")
            result = self.call(
                "submit",
                {"session_id": session, "workspace_name": f"fallback {self.nonce}", "branch_name": branch},
                timeout_s=240,
            )
            if not result.get("finished"):
                raise SmokeFailure(f"Create on This Mac did not finish: {result}")
        finally:
            self.set_link("restore")
            if session:
                self.call("close", {"session_id": session})
            self.wait_link_connected()
            created = self.adopt_orphan(branch, project_id=other)
        stored = self.last_device().get("device_key")
        if stored != self.machine:
            raise SmokeFailure(
                f"a create on the Mac the sheet fell back to replaced the remembered Mac: {stored!r}, want {self.machine}"
            )
        return {"default_row": THIS_MAC, "worktree_path": (created or {}).get("path"), "last_device": stored}

    def ensure_echo_command(self) -> None:
        """Offers a harmless "echo" Claude command (restored in cleanup), so no
        agent.start here ever launches the real Claude."""
        if self.previous_commands is not None:
            return
        self.previous_commands = self.call("set_agent_commands", {})
        previous = self.previous_commands.get("previous") or []
        self.call("set_agent_commands", {"commands": ["echo", *[c for c in previous if c != "echo"]],
                                         "selected": self.previous_commands.get("previous_selected")})

    def check_prompt_start(self) -> Dict[str, Any]:
        self.ensure_echo_command()
        session = self.sessions[-1]
        state = self.call("load", {"session_id": session}, timeout_s=180)
        if "echo" not in (state.get("commands") or []):
            raise SmokeFailure(f"the Loopback Mac does not offer the test command: {state.get('commands')}")
        marker = f"picker-agent-{self.nonce}"
        result = self.call(
            "submit",
            {"session_id": session, "prompt": f"say {marker}", "command": "echo"},
            timeout_s=300,
        )
        facts = self.check_mirror_selected(result)
        preview = str(result.get("preview_line") or "")
        if not preview.startswith("echo") or marker not in preview:
            raise SmokeFailure(f"the other Mac's launch line is not previewed with the prompt: {preview!r}")
        facts["preview_line"] = preview
        source_id = facts["remote_workspace_id"]  # loopback: the remote workspace is local too

        def echoed() -> Optional[str]:
            surfaces = (self.client.call("surface.list", {"workspace_id": source_id}) or {}).get("surfaces") or []
            for surface in surfaces:
                surface_id = surface.get("id") or surface.get("surface_id")
                text = str((self.client.call(
                    "surface.read_text",
                    {"workspace_id": source_id, "surface_id": surface_id, "scrollback": True},
                ) or {}).get("text") or "")
                if f"say {marker}" in text and "echo" in text:
                    return surface_id
            return None

        surface = wait_for("the agent.start terminal to echo the prompt", echoed, self.timeout_s)
        worktree = next((w for w in self.remote_worktrees() if norm(w.get("workspace_id")) == norm(source_id)), None)
        if worktree is None:
            raise SmokeFailure("agent.start created no worktree for its workspace")
        facts.update({"echo_surface_id": surface, "agent_worktree_branch": worktree.get("branch"),
                      "agent_worktree_path": worktree.get("path")})
        return facts

    def check_live_availability(self) -> Dict[str, Any]:
        state = self.open_session(preferred_device=self.machine)
        session = state["session_id"]
        typed = {"prompt": f"live {self.nonce}", "workspace_name": f"live ws {self.nonce}",
                 "branch_name": f"live-{self.nonce}"}
        self.call("fill", {"session_id": session, **typed})

        def loopback_row(current: Dict[str, Any]) -> Dict[str, Any]:
            return next(e for e in current.get("entries") or [] if e.get("device_key") == self.machine)

        def kept(current: Dict[str, Any]) -> None:
            lost = {k: current.get(k) for k in typed if current.get(k) != typed[k]}
            if lost or current.get("selected_entry_id") != self.machine:
                raise SmokeFailure(f"the link change reset the sheet: {lost}, selected {current.get('selected_entry_id')}")

        # The drop lands while that Mac's options load (a second connection,
        # as the sheet's own load runs beside the user's typing).
        loading = threading.Thread(target=self.load_on_second_connection, args=(session,), daemon=True)
        loading.start()
        time.sleep(1.0)
        self.set_link("stop")
        try:
            loading.join(self.timeout_s)

            def dropped() -> Optional[Dict[str, Any]]:
                current = self.call("state", {"session_id": session})
                row = loopback_row(current)
                if row.get("availability") != "online" and not row.get("can_create") and not current.get("can_create"):
                    return current
                return None

            down = wait_for("the dropped Mac to be disabled in the open sheet", dropped, self.timeout_s)
            kept(down)
            raw = [str(down.get(k)) for k in ("branch_load_error", "models_error") if "CancellationError" in str(down.get(k))]
            if raw:
                raise SmokeFailure(f"a load the link dropped under shows the raw error: {raw}")
        finally:
            self.set_link("restore")

        def back() -> Optional[Dict[str, Any]]:
            current = self.call("state", {"session_id": session})
            row = loopback_row(current)
            if row.get("availability") == "online" and row.get("can_create") and current.get("can_create"):
                return current
            return None

        up = wait_for("the reconnected Mac to be selectable again in the open sheet", back, self.timeout_s)
        kept(up)
        return {"while_down": loopback_row(down).get("availability"), "after_restore": loopback_row(up).get("availability")}

    def check_dropped_link(self, prompt: bool) -> Dict[str, Any]:
        """The link drops after the create went out: the sheet must say the
        outcome is unknown (naming the Mac), never idle silently or show a raw
        CancellationError."""
        self.wait_link_connected()
        state = self.open_session(preferred_device=self.machine)
        session = state["session_id"]
        self.call("load", {"session_id": session}, timeout_s=180)
        branch = f"drop-{'agent' if prompt else 'plain'}-{self.nonce}"
        params: Dict[str, Any] = {"session_id": session, "workspace_name": f"drop {self.nonce}",
                                  "branch_name": branch, "await_open": False, "stop_link_after_seconds": 1.0}
        if prompt:
            self.ensure_echo_command()
            params.update({"prompt": f"say drop {self.nonce}", "command": "echo"})
        hook = self.slow_worktree_add(4)
        try:
            result = self.call("submit", params, timeout_s=240)
        finally:
            self.set_link("restore")
            self.wait_link_connected()
            time.sleep(5.0)  # the other Mac finishes its git work after the drop
            hook.unlink(missing_ok=True)
            orphan = self.adopt_orphan(branch)
        message = str(result.get("error_message") or "")
        device_name = str((result.get("target") or {}).get("remote_device_name") or "")
        if result.get("finished") or result.get("phase") != "idle":
            raise SmokeFailure(f"a dropped create did not end editable and unfinished: {result}")
        if "CancellationError" in message or "dropped" not in message or device_name not in message:
            raise SmokeFailure(f"a dropped create must say the outcome is unknown on {device_name!r}, got {message!r}")
        return {"error_message": message, "created_anyway": orphan is not None}

    def check_host_open_keeps_selection(self) -> Dict[str, Any]:
        """Opens requested by another Mac (`select: false`) never switch this
        Mac's selected workspace; the phone's default (no param) still does."""
        self.wait_link_connected()
        self.ensure_echo_command()
        before = self.selected_workspaces()
        opened: Dict[str, str] = {}

        def unchanged(label: str, result: Dict[str, Any]) -> None:
            workspace_id = result.get("workspace_id")
            if not workspace_id:
                raise SmokeFailure(f"{label} opened no workspace: {result}")
            opened[label] = workspace_id
            self.created.append({"mirror": workspace_id, "remote": workspace_id})
            time.sleep(0.5)
            after = self.selected_workspaces()
            if after != before:
                raise SmokeFailure(f"{label} {{select: false}} changed the selection: {before} -> {after}")

        created = self.request("mobile.supermux.worktree.create", {
            "project_id": self.project_id, "branch_name": f"keep-{self.nonce}", "open": True, "select": False,
        }, timeout_s=120)
        unchanged("worktree.create", created)
        path = (created.get("worktree") or {}).get("path")
        unchanged("worktree.open", self.request("mobile.supermux.worktree.open", {
            "project_id": self.project_id, "worktree_path": path, "select": False}))
        unchanged("project.open", self.request("mobile.supermux.project.open", {
            "project_id": self.project_id, "select": False}))
        unchanged("agent.start", self.request("mobile.supermux.agent.start", {
            "project_id": self.project_id, "prompt": f"say keep {self.nonce}", "command": "echo",
            "workspace_name": f"keep agent {self.nonce}", "branch_name": f"keep-agent-{self.nonce}",
            "select": False,
        }, timeout_s=300))
        # Opened in the background, each still reaches the other Mac: its
        # auto-mirror opens (and cleanup then never races a mirror mid-open).
        sources = sorted({norm(w) for w in opened.values()})

        def mirrored() -> Optional[List[str]]:
            bindings = self.client.call("supermux.devices.bindings", {}) or {}
            rows = [m for m in bindings.get("mirrors") or [] if norm(m.get("remote_workspace_id")) in sources]
            bound = {norm(m.get("remote_workspace_id")) for m in rows if m.get("is_bound")}
            return [m["workspace_id"] for m in rows] if bound == set(sources) else None

        mirrors = wait_for("auto-mirrors of the background-opened workspaces", mirrored, self.timeout_s)
        if self.selected_workspaces() != before:
            raise SmokeFailure(f"auto-mirroring a background-opened workspace changed the selection: {before}")
        # The phone passes nothing and keeps today's behavior: the workspace is selected.
        default = self.request("mobile.supermux.project.open", {"project_id": self.project_id})
        if norm(default.get("workspace_id")) not in self.selected_workspaces():
            raise SmokeFailure(f"project.open without select no longer selects: {default}")
        return {"opened": opened, "mirrors": mirrors, "selected_before": before}

    def check_unfocused_remote_create(self) -> Dict[str, Any]:
        """A viewer-side remote create that does not focus leaves every
        window's selection alone: the owning Mac did not select its new
        workspace either."""
        before = self.selected_workspaces()
        result = self.client.call("supermux.devices.remote_worktree_create", {
            "machine": self.machine, "project_id": self.project_id,
            "workspace_name": f"unfocused {self.nonce}", "branch_name": f"unfocused-{self.nonce}", "focus": False,
        }, timeout_s=240) or {}
        remote_id, mirror_id = result.get("remote_workspace_id"), result.get("workspace_id")
        if not remote_id or not mirror_id:
            raise SmokeFailure(f"remote_worktree_create returned no workspaces: {result}")
        self.created.append({"mirror": mirror_id, "remote": remote_id})
        time.sleep(1.0)
        after = self.selected_workspaces()
        if after != before:
            raise SmokeFailure(f"an unfocused remote create changed the selection: {before} -> {after}")
        return {"remote_workspace_id": remote_id, "mirror_workspace_id": mirror_id}

    # -- prompt images ---------------------------------------------------------

    def write_png(self, name: str) -> Tuple[Path, str]:
        """A small valid PNG (stdlib only, its pixels keyed to the run) and its SHA-256."""
        width, height = 4, 4
        seed = int(self.nonce[:6], 16)
        pixel = bytes([seed >> 16 & 0xFF, seed >> 8 & 0xFF, seed & 0xFF])
        raw = b"".join(b"\x00" + pixel * width for _ in range(height))

        def chunk(kind: bytes, data: bytes) -> bytes:
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

        png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
        path = self.root / name
        path.write_bytes(png)
        return path, hashlib.sha256(png).hexdigest()

    def echoed_attachment(self, workspace_id: str, marker: str, file_name: str) -> Dict[str, Any]:
        """Waits for the echo launch in `workspace_id` and returns the image
        path and --add-dir folder its output names (soft wraps removed; the
        typed line quotes its arguments, so only the output matches)."""
        pattern = re.compile(r"Attached images:(/\S+?/" + re.escape(file_name) + ")")

        def found() -> Optional[Dict[str, Any]]:
            surfaces = (self.client.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
            for surface in surfaces:
                surface_id = surface.get("id") or surface.get("surface_id")
                text = str((self.client.call(
                    "surface.read_text",
                    {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True},
                ) or {}).get("text") or "")
                flat = text.replace("\r", "").replace("\n", "")
                match = pattern.search(flat) if f"say {marker}" in flat else None
                if match:
                    path = match.group(1)
                    return {"path": path, "add_dir": f"--add-dir {os.path.dirname(path)} --" in flat,
                            "surface_id": surface_id}
            return None

        return wait_for("the launch to echo the prompt and its image path", found, self.timeout_s)

    def echoed_attachments(self, workspace_id: str, marker: str, file_names: List[str]) -> Dict[str, Any]:
        """Like ``echoed_attachment`` for several images: their paths in the
        echoed output, in order, and whether the line passed their one folder
        as --add-dir."""
        last = self.echoed_attachment(workspace_id, marker, file_names[-1])
        text = str((self.client.call(
            "surface.read_text",
            {"workspace_id": workspace_id, "surface_id": last["surface_id"], "scrollback": True},
        ) or {}).get("text") or "")
        flat = text.replace("\r", "").replace("\n", "")
        listed = flat[flat.rindex("Attached images:") + len("Attached images:"):]
        paths = re.findall(r"(/\S*?/(?:" + "|".join(re.escape(n) for n in file_names) + "))", listed)
        if [os.path.basename(p) for p in paths[:len(file_names)]] != file_names:
            raise SmokeFailure(f"the launch did not list all {len(file_names)} images in order: {paths}")
        paths = paths[:len(file_names)]
        return {"paths": paths, "add_dir": f"--add-dir {os.path.dirname(paths[0])} --" in flat}

    def check_image_copy(self, echoed: Dict[str, Any], digest: str, store: Path) -> Dict[str, Any]:
        path = Path(echoed["path"])
        if store not in path.parents:
            raise SmokeFailure(f"the image path {path} is not in {store}")
        if path.parent not in self.image_folders:
            self.image_folders.append(path.parent)
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise SmokeFailure(f"{path} is missing or differs from the attached image")
        if not echoed["add_dir"]:
            raise SmokeFailure(f"the launch line does not pass --add-dir {path.parent}")
        return {"image_path": str(path), "folder_mode": oct(stat.S_IMODE(path.parent.stat().st_mode)),
                "file_mode": oct(stat.S_IMODE(path.stat().st_mode))}

    def check_prompt_images_need_text(self) -> Dict[str, Any]:
        self.ensure_echo_command()
        image, _ = self.write_png(f"img-{self.nonce}-check.png")
        not_image = self.root / f"notes-{self.nonce}.txt"
        not_image.write_text("not an image\n", encoding="utf-8")
        session = self.open_session(preferred_device=self.machine)["session_id"]
        state = self.call("load", {"session_id": session}, timeout_s=180)
        if not state.get("can_attach_images") or not (state.get("target") or {}).get("supports_prompt_attachments"):
            raise SmokeFailure(f"the Loopback Mac does not take prompt images: {state}")
        state = self.call("fill", {"session_id": session, "prompt": "", "attachments": [str(image)]})
        if real_paths(state.get("attachments")) != [os.path.realpath(image)] or not state.get("has_prompt"):
            raise SmokeFailure(f"the image did not attach in Start Claude mode: {state}")
        if state.get("can_create") or state.get("preview_line") is not None:
            raise SmokeFailure(f"images without text must keep Start disabled and the line unpreviewed: {state}")
        state = self.call("fill", {"session_id": session, "attachments": [str(not_image), str(image)]})
        if real_paths(state.get("attachments")) != [os.path.realpath(image)] or not state.get("error_message"):
            raise SmokeFailure(f"a non-image was not refused with a sentence (or the image doubled): {state}")
        refusal = state.get("error_message")
        state = self.call("remove_attachment", {"session_id": session, "index": 0})
        if state.get("attachments") or state.get("has_prompt") or not state.get("can_create"):
            raise SmokeFailure(f"removing the image did not restore the plain sheet: {state}")
        self.call("close", {"session_id": session})
        return {"refusal": refusal}

    def check_prompt_images_reach_other_mac(self) -> Dict[str, Any]:
        self.ensure_echo_command()
        names = [f"img-{self.nonce}-remote-{index}.png" for index in range(10)]
        images = [self.write_png(name) for name in names]
        session = self.open_session(preferred_device=self.machine)["session_id"]
        self.call("load", {"session_id": session}, timeout_s=180)
        marker = f"picker-image-{self.nonce}"
        result = self.call(
            "submit",
            {"session_id": session, "prompt": f"say {marker}", "command": "echo",
             "attachments": [str(image) for image, _ in images]},
            timeout_s=300,
        )
        facts = self.check_mirror_selected(result)
        echoed = self.echoed_attachments(facts["remote_workspace_id"], marker, names)
        folders = {os.path.dirname(path) for path in echoed["paths"]}
        if len(folders) != 1:
            raise SmokeFailure(f"10 small images did not share one upload folder: {sorted(folders)}")
        store = Path.home() / ".cache" / "cmux" / "task-attachments"
        for path, (_, digest) in zip(echoed["paths"], images):
            copy = self.check_image_copy({"path": path, "add_dir": echoed["add_dir"]}, digest, store)
        facts.update(copy)
        facts["image_count"] = len(echoed["paths"])
        return facts

    def check_prompt_images_on_this_mac(self) -> Dict[str, Any]:
        self.ensure_echo_command()
        name = f"img-{self.nonce}-local.png"
        image, digest = self.write_png(name)
        branch = f"picker-image-local-{self.nonce}"
        session = self.open_session(preferred_device=THIS_MAC)["session_id"]
        state = self.call("load", {"session_id": session}, timeout_s=180)
        if state.get("selected_entry_id") != THIS_MAC:
            raise SmokeFailure(f"the sheet did not open on This Mac: {state.get('selected_entry_id')}")
        marker = f"picker-image-local-{self.nonce}"
        result = self.call(
            "submit",
            {"session_id": session, "prompt": f"say {marker}", "command": "echo", "attachments": [str(image)],
             "workspace_name": f"picker image {self.nonce}", "branch_name": branch},
            timeout_s=300,
        )
        if not result.get("finished"):
            raise SmokeFailure(f"Start Claude on This Mac did not finish: {result}")
        worktree = self.adopt_orphan(branch)
        if not worktree or not worktree.get("workspace_id"):
            raise SmokeFailure(f"the launch on This Mac opened no workspace for {branch}: {worktree}")
        echoed = self.echoed_attachment(worktree["workspace_id"], marker, name)
        store = Path.home() / ".local" / "state" / "cmux" / "supermux-agent-attachments"
        facts = self.check_image_copy(echoed, digest, store)
        if facts["folder_mode"] != "0o700" or facts["file_mode"] != "0o600":
            raise SmokeFailure(f"the copy is not private: {facts}")
        if Path(facts["image_path"]) == image:
            raise SmokeFailure("the launch names the attached file itself, not a private copy")
        facts["workspace_id"] = worktree["workspace_id"]
        return facts

    def check_foreign_attachment_paths(self) -> Dict[str, Any]:
        self.ensure_echo_command()
        store = Path.home() / ".cache" / "cmux" / "task-attachments"
        outside, _ = self.write_png(f"img-{self.nonce}-outside.png")
        in_store_root = store / f"img-{self.nonce}-store-root.png"
        store.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(outside, in_store_root)
        attempts = {"outside": str(outside), "climbs_out": f"{store}/{os.path.relpath(outside, store)}",
                    "store_root": str(in_store_root)}
        try:
            rejected = self.attempt_foreign_paths(attempts)
        finally:
            in_store_root.unlink(missing_ok=True)
        return {"rejected": rejected}

    def attempt_foreign_paths(self, attempts: Dict[str, str]) -> Dict[str, str]:
        """Sends agent.start with each path; every one must be refused before git runs."""
        rejected: Dict[str, str] = {}
        for label, path in attempts.items():
            branch = f"foreign-{label.replace('_', '-')}-{self.nonce}"
            try:
                result = self.request(
                    "mobile.supermux.agent.start",
                    {"project_id": self.project_id, "prompt": "say nothing", "command": "echo",
                     "branch_name": branch, "attachment_paths": [path], "select": False},
                    timeout_s=120,
                )
            except SmokeFailure as error:
                if "invalid_params" not in str(error):
                    raise
                rejected[label] = str(error)
            else:
                raise SmokeFailure(f"agent.start accepted attachment path {path}: {result}")
            if any(w.get("branch") == branch for w in self.remote_worktrees()):
                raise SmokeFailure(f"a rejected agent.start still created {branch}")
        return rejected

    def check_prompt_images_convert_and_follow_links(self) -> Dict[str, Any]:
        png, _ = self.write_png(f"img-{self.nonce}-source.png")
        heic = self.root / f"img-{self.nonce}-photo.heic"
        tiff = self.root / f"img-{self.nonce}-scan.tiff"
        for fmt, out in (("heic", heic), ("tiff", tiff)):
            subprocess.run(["sips", "-s", "format", fmt, str(png), "--out", str(out)],
                           check=True, capture_output=True, timeout=60)
        svg = self.root / f"img-{self.nonce}-drawing.svg"
        svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">'
                       '<rect width="8" height="8" fill="#336699"/></svg>', encoding="utf-8")
        link = self.root / f"img-{self.nonce}-link.png"
        link.symlink_to(png)
        session = self.open_session(preferred_device=THIS_MAC)["session_id"]
        self.call("load", {"session_id": session}, timeout_s=180)
        state = self.call("fill", {"session_id": session, "attachments": [str(heic), str(tiff), str(svg), str(link)]})
        attached = state.get("attachments") or []
        self.call("close", {"session_id": session})
        if state.get("error_message") or len(attached) != 4:
            raise SmokeFailure(f"the HEIC, TIFF, SVG and symlink did not all attach: {state}")
        photo, scan, drawing, linked = (Path(path) for path in attached)
        for converted in (photo, scan, drawing):
            if converted.parent not in self.image_folders:
                self.image_folders.append(converted.parent)
        if photo.suffix not in (".jpg", ".jpeg") or not photo.read_bytes().startswith(b"\xff\xd8\xff"):
            raise SmokeFailure(f"the HEIC photo did not convert to a JPEG: {photo}")
        if scan.suffix != ".png" or not scan.read_bytes().startswith(b"\x89PNG"):
            raise SmokeFailure(f"the opaque TIFF did not convert to a PNG: {scan}")
        if drawing.suffix != ".png" or not drawing.read_bytes().startswith(b"\x89PNG"):
            raise SmokeFailure(f"the SVG did not render to a PNG: {drawing}")
        dimensions = [subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(p)],
                                     check=True, capture_output=True, text=True, timeout=60).stdout.split()[-3::2]
                      for p in (photo, scan)]
        if any(d != ["4", "4"] for d in dimensions):
            raise SmokeFailure(f"a converted image changed size: {dimensions}")
        if real_paths([str(linked)]) != [os.path.realpath(png)] or linked.name != png.name:
            raise SmokeFailure(f"the symlink did not attach as the file it points to: {linked}")
        return {"photo": photo.name, "scan": scan.name, "drawing": drawing.name, "linked": str(linked)}

    # -- cleanup -------------------------------------------------------------

    def cleanup(self) -> None:
        errors: List[str] = []

        def attempt(action: Callable[[], Any]) -> None:
            try:
                action()
            except SmokeFailure as error:
                errors.append(str(error))

        if self.previous_commands is not None:
            attempt(lambda: self.call("set_agent_commands", {
                "commands": self.previous_commands.get("previous"),
                "selected": self.previous_commands.get("previous_selected"),
            }))
        if self.previous_last_device is not None:
            attempt(lambda: self.last_device(set=self.previous_last_device.get("previous")))
        for session in self.sessions:
            attempt(lambda session=session: self.call("close", {"session_id": session}))
        if not self.keep:
            # Source first: auto-mirror then closes its mirror. Closing the
            # mirror first would let auto-mirror re-mirror the source just
            # before it closes.
            closed: set = set()
            for created in self.created:
                for key in ("remote", "mirror"):
                    if norm(created[key]) not in closed:
                        closed.add(norm(created[key]))
                        attempt(lambda w=created[key]: self.close_workspace_if_open(w))
                attempt(lambda c=created: self.client.call(
                    "supermux.devices.unhide", {"machine": self.machine, "remote_workspace_id": c["remote"]}))
            if self.machine:
                for project_id, checkout in self.registered.items():
                    for worktree in self.remote_worktrees_safe(project_id):
                        if worktree.get("path") != checkout:
                            attempt(lambda p=project_id, w=worktree: self.request(
                                "mobile.supermux.worktree.remove",
                                {"project_id": p, "worktree_path": w["path"], "force": True, "delete_branch": True},
                                timeout_s=120,
                            ))
            for project_id in self.registered:
                attempt(lambda p=project_id: self.request("mobile.supermux.project.delete", {"project_id": p}))
            for folder in self.image_folders:
                shutil.rmtree(folder, ignore_errors=True)
            shutil.rmtree(self.root, ignore_errors=True)
        if errors:
            self.facts["cleanup_errors"] = errors

    def close_workspace_if_open(self, workspace_id: str) -> None:
        """Closes a workspace unless it is already gone (a closed source takes its mirror along)."""
        time.sleep(0.3)
        for window in (self.client.call("window.list", {}) or {}).get("windows") or []:
            window_id = window.get("id") or window.get("window_id")
            rows = (self.client.call("workspace.list", {"window_id": window_id}) or {}).get("workspaces") or []
            if any(norm(r.get("id")) == norm(workspace_id) for r in rows):
                self.client.call("workspace.close", {"workspace_id": workspace_id, "force": True})
                return

    def remote_worktrees_safe(self, project_id: Optional[str] = None) -> List[Dict[str, Any]]:
        try:
            return self.remote_worktrees(project_id)
        except SmokeFailure:
            return []

    def run(self, only: Optional[List[str]] = None) -> bool:
        """Runs every step, stopping at the first failure; with `only`, runs
        just those steps (after the two setup steps) and records each result."""
        plan: List[Any] = [
            ("picker_lists_this_mac_and_loopback", self.check_rows),
            ("remote_branches_load", self.check_remote_branches),
            ("remote_error_is_localized", self.check_remote_error),
            ("plain_create_selects_mirror", self.check_plain_create),
            ("last_device_persisted", self.check_last_device),
            ("last_device_is_global", self.check_last_device_is_global),
            ("global_device_offline_falls_back_to_this_mac", self.check_global_device_offline_fallback),
            ("fallback_create_keeps_remembered_mac", self.check_fallback_create_keeps_remembered_mac),
            ("prompt_start_runs_agent_start", self.check_prompt_start),
            ("availability_is_live", self.check_live_availability),
            ("dropped_link_create_reports_unknown_outcome", lambda: self.check_dropped_link(prompt=False)),
            ("dropped_link_start_claude_reports_unknown_outcome", lambda: self.check_dropped_link(prompt=True)),
            ("host_open_keeps_selection_for_other_macs", self.check_host_open_keeps_selection),
            ("unfocused_remote_create_keeps_selection", self.check_unfocused_remote_create),
            ("prompt_images_need_text", self.check_prompt_images_need_text),
            ("prompt_images_reach_other_mac", self.check_prompt_images_reach_other_mac),
            ("prompt_images_on_this_mac", self.check_prompt_images_on_this_mac),
            ("agent_start_rejects_foreign_attachment_paths", self.check_foreign_attachment_paths),
            ("prompt_images_convert_and_follow_links", self.check_prompt_images_convert_and_follow_links),
        ]
        try:
            self.step("device_connected", self.check_device)
            self.step("project_registered", self.register_project)
            for name, action in plan:
                if only and name not in only:
                    continue
                try:
                    self.step(name, action)
                except SmokeFailure:
                    if not only:
                        raise
            return all(step["ok"] for step in self.steps)
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
    parser.add_argument("--keep", action="store_true", help="leave the workspaces, worktrees and project in place")
    parser.add_argument("--only", help="comma-separated step names to run (after the setup steps), each recorded even if another fails")
    parser.add_argument("--report", help="report path (default: tests/supermux/artifacts/loopback_new_worktree_picker_e2e-<tag>.json)")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    socket_path = args.socket or socket_path_for_tag(args.tag)
    scratch = Path(args.scratch or f"/tmp/{args.tag or 'supermux-e2e'}")

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with SocketClient(socket_path, timeout_s=60) as client:
            e2e = PickerE2E(client, scratch, timeout_s=args.timeout, keep=args.keep)
            passed = e2e.run(only=[n.strip() for n in args.only.split(",")] if args.only else None)
            steps, facts = e2e.steps, e2e.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-new-worktree-picker-e2e",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    default_report = ARTIFACTS_DIR / f"loopback_new_worktree_picker_e2e-{args.tag or 'socket'}.json"
    report_path = Path(args.report) if args.report else default_report
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
