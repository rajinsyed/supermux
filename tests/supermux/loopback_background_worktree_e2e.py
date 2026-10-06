#!/usr/bin/env python3
"""End-to-end test for creating worktrees in the background, on the loopback device.

Pressing Create or Start Claude in the New Worktree sheet closes the sheet at
once. The create runs in the background, shown as a loading row under its
project in the sidebar, and its workspace opens without switching the window.
A failed create leaves a row that reopens the sheet with everything typed.

Talks to a tagged DEBUG build launched like run_all_loopback_e2e.sh does
(SUPERMUX_DEBUG_LOOPBACK_DEVICE=1, scratch SUPERMUX_PROJECTS_FILE). It drives
the DEBUG socket methods `supermux.devices.new_worktree.*`: `submit
{background: true}` hands the sheet to the same pending-worktree store the
sidebar's Create button does, and `pending` / `pending_action` read and act on
the rows the sidebar draws under the project.

Steps:
  1. device_connected / 2. project_registered: as in
     loopback_new_worktree_picker_e2e.py (a scratch repo on This Mac and the
     loopback device, nothing remembered as the last Mac).
  3. background_create_returns_at_once: with `git worktree add` slowed to 4 s,
     Create on This Mac answers in under 2 s and leaves a pending row under
     the project, titled with the typed workspace name, that shows git
     running with no Cancel (git cannot be taken back).
  4. pending_row_becomes_workspace: the row goes away only once the workspace
     is open in the window, titled as typed, and the selected workspace never
     changed.
  5. failed_create_keeps_row: Create with an unknown starting branch ends in a
     failed row carrying the error sentence, still there 2 s later.
  6. failed_row_reopens_sheet: reopening that row gives its sheet back,
     editable, with the error and every typed field; the row is gone.
  7. failed_row_dismisses: another failed row is dismissed and gone.
  8. background_start_claude: Start Claude (a harmless "echo" command) on This
     Mac returns at once with a pending row titled from the prompt; then the
     workspace opens unselected and its terminal echoes the prompt.
  9. remote_background_create: with git slowed again, Create on the Loopback
     Mac shows "Creating on <Mac>…" in its row; the row stays until the
     mirror is open, and the mirror opens unselected.

`--only a,b` runs just those steps (after 1-2) and records each result.

Prints a JSON report, writes it to tests/supermux/artifacts/ (or --report),
exits non-zero on any failed check. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_background_worktree_e2e.py [--keep] [--scratch /tmp/<tag>]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_device_smoke import ARTIFACTS_DIR, SmokeFailure, SocketClient, norm, socket_path_for_tag, wait_for  # noqa: E402
from loopback_new_worktree_picker_e2e import THIS_MAC, PickerE2E  # noqa: E402

# Background submit answers before git runs; this leaves room for a slow socket.
SUBMIT_BUDGET_S = 2.0
SLOW_GIT_S = 4


class BackgroundE2E(PickerE2E):
    def __init__(self, client: SocketClient, scratch: Path, timeout_s: float, keep: bool) -> None:
        super().__init__(client, scratch, timeout_s, keep)
        self.root = scratch / f"background-{self.nonce}"
        self.repo = self.root / "repo"
        self.facts["scratch"] = str(self.root)
        self.hooks: List[Path] = []
        self.plain: Dict[str, Any] = {}
        self.failed: Dict[str, Any] = {}

    # -- helpers -------------------------------------------------------------

    def pending(self) -> List[Dict[str, Any]]:
        """The pending rows the sidebar draws under the project."""
        return self.call("pending", {"project_id": self.project_id}).get("pending") or []

    def pending_row(self, pending_id: str) -> Optional[Dict[str, Any]]:
        return next((row for row in self.pending() if row.get("id") == pending_id), None)

    def window_workspaces(self) -> List[Dict[str, Any]]:
        return (self.client.call("workspace.list", {"window_id": self.window_id}) or {}).get("workspaces") or []

    def new_local_workspaces(self, known: set) -> List[Dict[str, Any]]:
        """This Mac's workspaces opened since `known`, queued for cleanup. The
        loopback device is this app, so auto-mirror also mirrors each new local
        workspace back here; those mirrors are left out of the result."""
        bindings = self.client.call("supermux.devices.bindings", {}) or {}
        mirrors = {norm(m.get("workspace_id")): m for m in bindings.get("mirrors") or []}
        new = [w for w in self.window_workspaces() if norm(w.get("id")) not in known]
        for workspace in new:
            mirror = mirrors.get(norm(workspace.get("id")))
            source = mirror.get("remote_workspace_id") if mirror else workspace["id"]
            self.created.append({"mirror": workspace["id"], "remote": source})
        return [w for w in new if norm(w.get("id")) not in mirrors]

    def submit_background(self, session: str, fields: Dict[str, Any]) -> Dict[str, Any]:
        """Presses Create / Start Claude as the sheet does, checking it did not wait."""
        started = time.monotonic()
        result = self.call("submit", {"session_id": session, **fields, "background": True})
        elapsed = time.monotonic() - started
        if not result.get("pending_id"):
            raise SmokeFailure(f"background submit returned no pending row: {result}")
        if elapsed > SUBMIT_BUDGET_S:
            raise SmokeFailure(f"background submit took {elapsed:.1f} s: it waited for the create")
        result["submit_seconds"] = round(elapsed, 2)
        return result

    def wait_gone(self, pending_id: str, what: str) -> None:
        wait_for(what, lambda: None if self.pending_row(pending_id) else True, self.timeout_s * 2)

    def failed_row(self, fields: Dict[str, Any]) -> Dict[str, Any]:
        state = self.open_session(preferred_device=THIS_MAC)
        result = self.submit_background(state["session_id"], fields)
        pending_id = result["pending_id"]

        def failed() -> Optional[Dict[str, Any]]:
            row = self.pending_row(pending_id)
            if row is None:
                raise SmokeFailure("the failed create's row went away")
            return row if row.get("state") == "failed" else None

        row = wait_for("the row to show the failure", failed, self.timeout_s)
        if not row.get("error") or row.get("can_cancel"):
            raise SmokeFailure(f"failed row lacks its error or still offers Cancel: {row}")
        return row

    # -- steps ---------------------------------------------------------------

    def check_background_create(self) -> Dict[str, Any]:
        self.hooks.append(self.slow_worktree_add(SLOW_GIT_S))
        state = self.open_session()
        if state.get("selected_entry_id") != THIS_MAC:
            raise SmokeFailure(f"the sheet preselected {state.get('selected_entry_id')}, want This Mac")
        self.call("load", {"session_id": state["session_id"]}, timeout_s=120)
        name, branch = f"bg plain {self.nonce}", f"bg-plain-{self.nonce}"
        selected_before = self.selected_workspaces()
        known = {norm(w.get("id")) for w in self.window_workspaces()}
        result = self.submit_background(state["session_id"], {"workspace_name": name, "branch_name": branch})
        pending_id = result["pending_id"]
        row = self.pending_row(pending_id)
        if row is None:
            raise SmokeFailure(f"no pending row under the project right after submit: {self.pending()}")
        if row.get("title") != name or row.get("state") == "failed":
            raise SmokeFailure(f"pending row is {row}, want {name!r} in progress")

        def git_running() -> Optional[Dict[str, Any]]:
            current = self.pending_row(pending_id)
            if current is None:
                raise SmokeFailure(f"the row went away before the {SLOW_GIT_S} s git finished")
            return current if current.get("state") == "creating" else None

        creating = wait_for("the row to show git running", git_running, self.timeout_s)
        if creating.get("can_cancel"):
            raise SmokeFailure(f"the row offers Cancel while git runs: {creating}")
        self.plain = {"pending_id": pending_id, "name": name, "branch": branch,
                      "selected_before": selected_before, "known": known}
        return {"submit_seconds": result["submit_seconds"], "row": row, "creating_row": creating}

    def check_pending_becomes_workspace(self) -> Dict[str, Any]:
        if not self.plain:
            raise SmokeFailure("background_create_returns_at_once did not run")
        self.wait_gone(self.plain["pending_id"], "the pending row to go away")
        # No gap: the workspace is already in the window when the row goes.
        new = self.new_local_workspaces(self.plain["known"])
        opened = [w for w in new if w.get("title") == self.plain["name"]]
        if len(opened) != 1:
            raise SmokeFailure(f"want one new workspace titled {self.plain['name']!r}, got {new}")
        if opened[0].get("selected") or opened[0].get("is_selected"):
            raise SmokeFailure("the background create switched the window to its workspace")
        if self.selected_workspaces() != self.plain["selected_before"]:
            raise SmokeFailure("the selected workspace changed while the create ran in the background")
        listed = [w for w in self.remote_worktrees() if w.get("branch") == self.plain["branch"]]
        if len(listed) != 1:
            raise SmokeFailure(f"the worktree {self.plain['branch']} is not listed: {listed}")
        for hook in self.hooks:
            hook.unlink(missing_ok=True)
        return {"workspace_id": opened[0]["id"], "worktree_path": listed[0].get("path")}

    def check_failed_keeps_row(self) -> Dict[str, Any]:
        fields = {"workspace_name": f"bg bad {self.nonce}", "branch_name": f"bg-bad-{self.nonce}",
                  "base_branch": f"no-such-base-{self.nonce}"}
        row = self.failed_row(fields)
        time.sleep(2.0)
        if self.pending_row(row["id"]) is None:
            raise SmokeFailure("the failed row went away on its own")
        self.failed = {"pending_id": row["id"], "fields": fields, "error": row["error"]}
        return {"row": row}

    def check_failed_reopens(self) -> Dict[str, Any]:
        if not self.failed:
            raise SmokeFailure("failed_create_keeps_row did not run")
        state = self.call("pending_action", {"pending_id": self.failed["pending_id"], "action": "reopen"})
        if not state.get("session_id"):
            raise SmokeFailure(f"reopen returned no sheet: {state}")
        self.sessions.append(state["session_id"])
        fields = self.failed["fields"]
        if state.get("phase") != "idle" or not state.get("can_create"):
            raise SmokeFailure(f"the reopened sheet is not editable: {state}")
        if state.get("error_message") != self.failed["error"]:
            raise SmokeFailure(f"the reopened sheet lost the error: {state.get('error_message')!r}")
        typed = {"workspace_name": state.get("workspace_name"), "branch_name": state.get("branch_name"),
                 "base_branch": state.get("base_branch")}
        if typed != fields:
            raise SmokeFailure(f"the reopened sheet lost what was typed: {typed}, want {fields}")
        if self.pending_row(self.failed["pending_id"]) is not None:
            raise SmokeFailure("the reopened row is still in the sidebar")
        return {"reopened": typed}

    def check_failed_dismisses(self) -> Dict[str, Any]:
        row = self.failed_row({"workspace_name": f"bg gone {self.nonce}", "branch_name": f"bg-gone-{self.nonce}",
                               "base_branch": f"no-such-base-{self.nonce}"})
        self.call("pending_action", {"pending_id": row["id"], "action": "dismiss"})
        if self.pending_row(row["id"]) is not None:
            raise SmokeFailure("the dismissed row is still in the sidebar")
        return {"dismissed": row["id"]}

    def check_background_start_claude(self) -> Dict[str, Any]:
        self.ensure_echo_command()
        session = self.open_session(preferred_device=THIS_MAC)["session_id"]
        state = self.call("load", {"session_id": session}, timeout_s=120)
        if "echo" not in (state.get("commands") or []):
            raise SmokeFailure(f"This Mac does not offer the test command: {state.get('commands')}")
        marker = f"bg-agent-{self.nonce}"
        selected_before = self.selected_workspaces()
        known = {norm(w.get("id")) for w in self.window_workspaces()}
        result = self.submit_background(session, {"prompt": f"say {marker}", "command": "echo"})
        pending_id = result["pending_id"]
        row = self.pending_row(pending_id)
        if row is None or not row.get("title") or row.get("state") == "failed":
            raise SmokeFailure(f"no pending Start Claude row: {row}")
        self.wait_gone(pending_id, "the Start Claude row to go away")
        new = self.new_local_workspaces(known)
        if len(new) != 1:
            raise SmokeFailure(f"want one new workspace, got {new}")
        workspace_id = new[0]["id"]
        if new[0].get("selected") or new[0].get("is_selected") or self.selected_workspaces() != selected_before:
            raise SmokeFailure("Start Claude in the background switched the window")

        def echoed() -> Optional[str]:
            surfaces = (self.client.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
            for surface in surfaces:
                surface_id = surface.get("id") or surface.get("surface_id")
                text = str((self.client.call(
                    "surface.read_text",
                    {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True},
                ) or {}).get("text") or "")
                if f"say {marker}" in text:
                    return surface_id
            return None

        surface = wait_for("the background Claude terminal to echo the prompt", echoed, self.timeout_s)
        return {"row": row, "workspace_id": workspace_id, "title": new[0].get("title"), "echo_surface_id": surface}

    def check_remote_background_create(self) -> Dict[str, Any]:
        state = self.open_session(preferred_device=self.machine)
        if state.get("selected_entry_id") != self.machine:
            raise SmokeFailure(f"preferred device ignored: {state.get('selected_entry_id')}")
        session = state["session_id"]
        state = self.call("load", {"session_id": session}, timeout_s=180)
        device_name = str((state.get("target") or {}).get("remote_device_name") or "")
        name, branch = f"bg remote {self.nonce}", f"bg-remote-{self.nonce}"
        selected_before = self.selected_workspaces()
        hook = self.slow_worktree_add(SLOW_GIT_S)
        self.hooks.append(hook)
        result = self.submit_background(session, {"workspace_name": name, "branch_name": branch})
        pending_id = result["pending_id"]

        def on_device() -> Optional[Dict[str, Any]]:
            row = self.pending_row(pending_id)
            if row is None:
                return {"gone": True}
            return row if device_name and device_name in str(row.get("status")) else None

        row = wait_for(f"the row to say it is creating on {device_name}", on_device, self.timeout_s)
        self.wait_gone(pending_id, "the remote create's row to go away")
        hook.unlink(missing_ok=True)
        worktree = next((w for w in self.remote_worktrees() if w.get("branch") == branch), None)
        remote_id = (worktree or {}).get("workspace_id")
        if not remote_id:
            raise SmokeFailure(f"the Loopback Mac lists no workspace for {branch}: {worktree}")
        bindings = self.client.call("supermux.devices.bindings", {}) or {}
        mirrors = [m for m in bindings.get("mirrors") or [] if norm(m.get("remote_workspace_id")) == norm(remote_id)]
        for mirror in mirrors:
            self.created.append({"mirror": mirror["workspace_id"], "remote": remote_id})
        if not mirrors:
            self.created.append({"mirror": remote_id, "remote": remote_id})
        if row.get("gone"):
            raise SmokeFailure(f"the row never said it was creating on {device_name!r}")
        if not any(m.get("is_bound") for m in mirrors):
            raise SmokeFailure(f"the row went away before the mirror was open: {mirrors}")
        if any(m.get("is_selected") for m in mirrors) or self.selected_workspaces() != selected_before:
            raise SmokeFailure("the background create on the other Mac switched the window")
        return {"row": row, "remote_workspace_id": remote_id, "mirrors": [m.get("workspace_id") for m in mirrors]}

    # -- run -----------------------------------------------------------------

    def cleanup(self) -> None:
        for hook in self.hooks:
            hook.unlink(missing_ok=True)
        try:
            for row in self.pending():
                if row.get("state") == "failed":
                    self.call("pending_action", {"pending_id": row["id"], "action": "dismiss"})
        except SmokeFailure as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))
        super().cleanup()

    def run(self, only: Optional[List[str]] = None) -> bool:
        plan: List[Any] = [
            ("background_create_returns_at_once", self.check_background_create),
            ("pending_row_becomes_workspace", self.check_pending_becomes_workspace),
            ("failed_create_keeps_row", self.check_failed_keeps_row),
            ("failed_row_reopens_sheet", self.check_failed_reopens),
            ("failed_row_dismisses", self.check_failed_dismisses),
            ("background_start_claude", self.check_background_start_claude),
            ("remote_background_create", self.check_remote_background_create),
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
    parser.add_argument("--report", help="report path (default: tests/supermux/artifacts/loopback_background_worktree_e2e-<tag>.json)")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    socket_path = args.socket or socket_path_for_tag(args.tag)
    scratch = Path(args.scratch or f"/tmp/{args.tag or 'supermux-e2e'}")

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with SocketClient(socket_path, timeout_s=60) as client:
            e2e = BackgroundE2E(client, scratch, timeout_s=args.timeout, keep=args.keep)
            passed = e2e.run(only=[n.strip() for n in args.only.split(",")] if args.only else None)
            steps, facts = e2e.steps, e2e.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-background-worktree-e2e",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    default_report = ARTIFACTS_DIR / f"loopback_background_worktree_e2e-{args.tag or 'socket'}.json"
    report_path = Path(args.report) if args.report else default_report
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
