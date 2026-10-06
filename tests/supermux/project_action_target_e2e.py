#!/usr/bin/env python3
"""End-to-end test that a local project's action runs in the selected workspace,
against one tagged DEBUG build.

A project row's Actions menu runs the action's command as a new terminal tab in the
workspace the user is looking at, in that workspace's directory (like ⌘G and the
presets bar). `supermux.devices.project_action_run` drives the row's exact path
(`SupermuxWorkspaceOpening.runProjectAction`), so the checks need no clicking:

  1. setup                              the tagged app quit; a scratch git repo with a
                                        `sub/` folder registered as the only project,
                                        with one action `pwd -P > <marker>`; relaunched
  2. action_runs_in_selected_workspace  with a workspace at `sub/` selected, running
                                        the action adds no workspace, adds one terminal
                                        to the selected workspace, keeps it selected,
                                        and the marker holds `sub/`, not the project root
  3. cleanup                            the workspaces the run opened closed; the app quit

The user's own project list is never touched: the app runs with a scratch projects
document. Writes a JSON report (default
tests/supermux/artifacts/project_action_target_e2e-<tag>.json) with a window
screenshot, and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/project_action_target_e2e.py --app-path "<App path>" [--report PATH]
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
from typing import Any, Callable, Dict, List, Optional, Set

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_tab_sync_e2e import ARTIFACTS_DIR, Failure, socket_path_for_tag, up, wait_for  # noqa: E402
from tagged_app import TaggedApp, require_isolated  # noqa: E402


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


class ProjectActionTargetE2E:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.nonce = uuid.uuid4().hex[:8]
        self.root = Path(f"/tmp/{args.tag}-e2e/project-action-{self.nonce}")
        self.repo = self.root / "repo"
        self.sub = self.repo / "sub"
        self.marker = self.root / "action-ran-in"
        self.project_id = str(uuid.uuid4()).upper()
        self.action_id = str(uuid.uuid4()).upper()
        self.app = TaggedApp(args.app_path, args.socket or socket_path_for_tag(args.tag), args.tag,
                             str(self.root / "projects.json"), args.push_state_dir)
        self.steps: List[Dict[str, Any]] = []
        self.initial_workspaces: Set[str] = set()

    # -- socket ---------------------------------------------------------------------

    def call(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        return self.app.sock.call(method, params or {}) or {}

    def workspaces(self) -> List[Dict[str, Any]]:
        return self.call("workspace.list").get("workspaces") or []

    def workspace_ids(self) -> Set[str]:
        return {up(w.get("id")) for w in self.workspaces()}

    def selected_workspace(self) -> str:
        return up(self.call("workspace.current").get("workspace_id"))

    def terminal_count(self, workspace_id: str) -> int:
        return len(self.call("surface.list", {"workspace_id": workspace_id}).get("surfaces") or [])

    # -- steps ----------------------------------------------------------------------

    def step(self, name: str, action: Callable[[], Optional[Dict[str, Any]]]) -> bool:
        started = time.monotonic()
        record: Dict[str, Any] = {"name": name}
        try:
            record.update(action() or {})
            record["ok"] = True
        except (Failure, subprocess.CalledProcessError, OSError) as error:
            record["ok"] = False
            record["error"] = str(error)
        record["seconds"] = round(time.monotonic() - started, 2)
        self.steps.append(record)
        print(f"{'PASS' if record['ok'] else 'FAIL'} {name} ({record['seconds']}s)"
              + ("" if record["ok"] else f": {record['error']}"))
        return record["ok"]

    def setup(self) -> Dict[str, Any]:
        self.app.quit()
        self.sub.mkdir(parents=True)
        git(self.repo, "init", "-q", "-b", "main")
        (self.sub / "README.md").write_text("scratch\n", encoding="utf-8")
        project = {
            "id": self.project_id,
            "name": f"action-target-{self.nonce}",
            "rootPath": str(self.repo),
            "actions": [{"id": self.action_id, "name": "Where", "command": f"pwd -P > {self.marker}"}],
        }
        document = {"version": 3, "projects": [project], "isSectionCollapsed": False}
        (self.root / "projects.json").write_text(json.dumps(document, indent=2), encoding="utf-8")
        self.app.launch()
        self.initial_workspaces = self.workspace_ids()
        return {"repo": str(self.repo), "project_id": self.project_id, "action_id": self.action_id}

    def action_runs_in_selected_workspace(self) -> Dict[str, Any]:
        created = self.call("workspace.create", {
            "title": f"sub-{self.nonce}", "working_directory": str(self.sub), "focus": True,
        })
        looking = up(created.get("workspace_id") or created.get("id"))
        if not looking:
            raise Failure(f"workspace.create returned {created}")
        self.call("workspace.select", {"workspace_id": looking})
        wait_for("the sub/ workspace to be selected", lambda: self.selected_workspace() == looking, 10)
        before_ids = self.workspace_ids()
        before_terminals = wait_for("the sub/ workspace's terminal", lambda: self.terminal_count(looking), 10)

        self.call("supermux.devices.project_action_run", {"project_id": self.project_id, "action_id": self.action_id})
        wait_for("the action's marker", lambda: self.marker.exists() and self.marker.read_text().strip(), 30)

        ran_in = self.marker.read_text().strip()
        new_workspaces = sorted(self.workspace_ids() - before_ids)
        after_terminals = self.terminal_count(looking)
        selected = self.selected_workspace()
        facts = {
            "selected_workspace": looking,
            "ran_in": ran_in,
            "new_workspaces": new_workspaces,
            "terminals_before": before_terminals,
            "terminals_after": after_terminals,
            "selected_after": selected,
            "screenshot": self.app.screenshot("project-action-target"),
        }
        problems = []
        if new_workspaces:
            problems.append(f"the action opened {len(new_workspaces)} new workspace(s)")
        if after_terminals != before_terminals + 1:
            problems.append(f"the selected workspace has {after_terminals} terminals, expected {before_terminals + 1}")
        if selected != looking:
            problems.append(f"the selection moved to {selected}")
        if ran_in != os.path.realpath(self.sub):
            problems.append(f"the action ran in {ran_in}, not the selected workspace's {os.path.realpath(self.sub)}")
        if problems:
            raise Failure("; ".join(problems) + f" — {facts}")
        return facts

    def cleanup(self) -> Dict[str, Any]:
        opened = sorted(self.workspace_ids() - self.initial_workspaces)
        for workspace_id in opened:
            self.call("workspace.close", {"workspace_id": workspace_id})
        self.app.quit()
        shutil.rmtree(self.root, ignore_errors=True)
        return {"closed": opened}

    def run(self) -> bool:
        if not self.step("setup", self.setup):
            return False
        ok = self.step("action_runs_in_selected_workspace", self.action_runs_in_selected_workspace)
        return self.step("cleanup", self.cleanup) and ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="defaults to /tmp/cmux-debug-<tag>.sock")
    parser.add_argument("--app-path", required=True)
    parser.add_argument("--push-state-dir", help="scratch phone push state (default /tmp/<tag>-e2e/push-state)")
    parser.add_argument("--report")
    args = parser.parse_args()
    if not args.tag:
        parser.error("set CMUX_TAG or pass --tag")
    if not require_isolated(args.app_path, args.tag):
        return 1

    e2e = ProjectActionTargetE2E(args)
    passed = e2e.run()
    report = {
        "suite": "project_action_target_e2e",
        "tag": args.tag,
        "passed": passed,
        "finished_at": datetime.now(timezone.utc).isoformat(),
        "steps": e2e.steps,
    }
    path = Path(args.report) if args.report else ARTIFACTS_DIR / f"project_action_target_e2e-{args.tag}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"{'PASS' if passed else 'FAIL'} report: {path}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
