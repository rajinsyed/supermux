#!/usr/bin/env python3
"""End-to-end test of the sidebar rows that show other Macs' workspaces (device
mirrors), against one tagged DEBUG build running the loopback device.

The loopback device ("Loopback Mac") is this same app's own mobile host, so
every local workspace also has a mirror. `supermux.devices.sidebar_rows`
reports the rows exactly as the sidebar builds them (the Projects section's
nested rows in display order, and the flat list's row snapshots), and
`supermux.devices.close_prompt` builds the mirror close prompt without
showing it. Checks:

  1. setup                               the loopback linked and fetched, auto-mirror on
  2. project_with_local_and_mirror_rows  a scratch project with two local worktree
                                         workspaces, each with its mirror nested under it
  3. nested_rows_local_first             inside the project, this Mac's rows come first
                                         (in their own order), then each Mac's mirrors
                                         grouped, even when a mirror is moved to the top
  4. nested_mirror_label_names_mac       a nested mirror's accessibility label says which
                                         Mac it is on; a local row's label is its title
  5. nested_rows_show_status             `set_status` / `set_progress` on a local workspace
                                         show on its nested row and on its mirror's
  6. flat_mirror_subtitle_omits_mac      a flat mirror's directory line does not repeat the
                                         Mac name (its chip already names it)
  7. close_prompt_is_safe                "Close on <Mac>" is destructive and not the Return
                                         default; Cancel is; the Mac name appears at most
                                         once in the text and once in the button; the text
                                         says the worktree stays and explains Hide Here

Writes a JSON report (default tests/supermux/artifacts/loopback_sidebar_rows_e2e-<tag>.json)
and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_sidebar_rows_e2e.py [--scratch /tmp/<tag>/rows] [--report PATH]
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


class SidebarRowsE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.root = Path(args.scratch) / f"rows-{self.nonce}"
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "scratch": str(self.root)}
        self.machine = ""
        self.mac_name = ""
        self.project_id = ""
        self.locals: List[str] = []
        self.mirrors: Dict[str, str] = {}
        self.created: List[str] = []
        self.initial_auto_mirror: Optional[bool] = None

    # -- reads and actions ----------------------------------------------------

    def request(self, method: str, params: Dict[str, Any], timeout_s: float = 120) -> Dict[str, Any]:
        result = self.sock.call(
            "supermux.devices.request",
            {"machine": self.machine, "method": method, "params": params, "timeout_seconds": timeout_s},
            timeout_s=timeout_s + 5,
        ) or {}
        return result.get("result") or {}

    def loopback_device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def mirror_of(self, source_id: str) -> Optional[str]:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        found = [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(source_id)]
        if len(found) > 1:
            raise Failure(f"{len(found)} mirrors of {source_id}")
        return up(found[0].get("workspace_id")) if found else None

    def rows(self) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.sidebar_rows", {}) or {}

    def project_rows(self) -> List[Dict[str, Any]]:
        for project in self.rows().get("projects") or []:
            if up(project.get("project_id")) == up(self.project_id):
                return project.get("rows") or []
        return []

    def row(self, workspace_id: str) -> Optional[Dict[str, Any]]:
        return next((r for r in self.project_rows() if up(r.get("workspace_id")) == up(workspace_id)), None)

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
        self.mac_name = device.get("name") or ""
        state = self.sock.call("supermux.devices.remote_macs_settings", {}) or {}
        self.initial_auto_mirror = state.get("auto_mirror")
        if not self.initial_auto_mirror:
            self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True})
        return {"machine": self.machine, "mac_name": self.mac_name}

    def project_with_rows(self) -> Dict[str, Any]:
        repo = self.root / "repo"
        repo.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=repo)
        git("-c", "user.email=e2e@example.com", "-c", "user.name=Supermux E2E", "commit", "-q", "--allow-empty", "-m", "init", cwd=repo)
        project = self.request("mobile.supermux.project.create", {"root_path": str(repo)}).get("project") or {}
        self.project_id = up(project.get("id"))
        if not self.project_id:
            raise Failure(f"project.create returned no project: {project}")
        for label in ("alpha", "beta"):
            created = self.request("mobile.supermux.worktree.create", {
                "project_id": self.project_id,
                "workspace_name": f"rows-{label}-{self.nonce}",
                "branch_name": f"rows-{label}-{self.nonce}",
                "open": True,
            }, timeout_s=180)
            workspace_id = up(created.get("workspace_id"))
            if not workspace_id:
                raise Failure(f"worktree.create returned no workspace: {created}")
            self.locals.append(workspace_id)
            self.created.append(workspace_id)
            self.mirrors[workspace_id] = wait_for(f"the {label} mirror", lambda: self.mirror_of(workspace_id), self.timeout)

        def nested() -> Optional[List[Dict[str, Any]]]:
            ids = {up(r.get("workspace_id")) for r in self.project_rows()}
            wanted = set(self.locals) | set(self.mirrors.values())
            return self.project_rows() if wanted <= ids else None

        rows = wait_for("all four rows to nest under the project", nested, self.timeout)
        return {"project_id": self.project_id, "locals": self.locals, "mirrors": self.mirrors, "rows": len(rows)}

    def nested_rows_local_first(self) -> Dict[str, Any]:
        # Put a mirror first in the window's tab order: the nested rows must
        # still list this Mac's workspaces first.
        first_mirror = self.mirrors[self.locals[0]]
        self.sock.call("workspace.reorder", {"workspace_id": first_mirror, "index": 0})

        def ordered() -> Optional[List[str]]:
            rows = self.project_rows()
            ours = [r for r in rows if up(r.get("workspace_id")) in set(self.locals) | set(self.mirrors.values())]
            if len(ours) != 4:
                return None
            kinds = ["mirror" if r.get("device_name") else "local" for r in ours]
            if kinds != ["local", "local", "mirror", "mirror"]:
                raise Failure(f"row order {[(r.get('title'), r.get('device_name')) for r in ours]}")
            return [up(r.get("workspace_id")) for r in ours]

        order = wait_for("local rows before the mirrors", ordered, self.timeout)
        tabs = [up(w.get("id") or w.get("workspace_id")) for w in (self.sock.call("workspace.list", {}) or {}).get("workspaces") or []]
        locals_in_tab_order = [w for w in tabs if w in self.locals]
        if order[:2] != locals_in_tab_order:
            raise Failure(f"local rows {order[:2]} are not in tab order {locals_in_tab_order}")
        return {"order": order}

    def nested_mirror_label_names_mac(self) -> Dict[str, Any]:
        mirror = self.row(self.mirrors[self.locals[0]]) or {}
        local = self.row(self.locals[0]) or {}
        label = mirror.get("accessibility_label") or ""
        if self.mac_name not in label:
            raise Failure(f"the mirror's label {label!r} does not name {self.mac_name!r}")
        if local.get("accessibility_label") != local.get("title"):
            raise Failure(f"the local row's label {local.get('accessibility_label')!r} is not its title {local.get('title')!r}")
        return {"mirror_label": label, "local_label": local.get("accessibility_label")}

    def nested_rows_show_status(self) -> Dict[str, Any]:
        source = self.locals[0]
        text = f"hello-{self.nonce}"
        self.sock.v1(f"set_status e2e_rows_pill {text} --icon=star.fill --tab={source}")
        self.sock.v1(f"set_progress 0.4 --label=building --tab={source}")

        def shown(workspace_id: str) -> Callable[[], Optional[Dict[str, Any]]]:
            def probe() -> Optional[Dict[str, Any]]:
                row = self.row(workspace_id) or {}
                pills = [p.get("text") for p in row.get("status_pills") or []]
                progress = row.get("progress") or {}
                if text in pills and abs((progress.get("value") or 0) - 0.4) < 1e-6 and progress.get("label") == "building":
                    return {"pills": pills, "progress": progress}
                raise Failure(f"row {workspace_id}: pills={pills} progress={progress or None}")
            return probe

        local = wait_for("the pill and progress on the local nested row", shown(source), self.timeout)
        mirror = wait_for("the pill and progress on the mirror's nested row", shown(self.mirrors[source]), self.timeout)
        self.sock.v1(f"clear_status e2e_rows_pill --tab={source}")
        self.sock.v1(f"clear_progress --tab={source}")
        return {"local": local, "mirror": mirror}

    def flat_mirror_subtitle_omits_mac(self) -> Dict[str, Any]:
        folder = self.root / "flat-dir"
        folder.mkdir(parents=True, exist_ok=True)
        created = self.sock.call("workspace.create", {
            "title": f"rows-flat-{self.nonce}", "focus": False, "working_directory": str(folder),
        }) or {}
        source = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not source:
            raise Failure(f"workspace.create returned no id: {created}")
        self.created.append(source)
        mirror = wait_for("the flat workspace's mirror", lambda: self.mirror_of(source), self.timeout)

        def subtitle() -> Optional[Dict[str, Any]]:
            flat = next((r for r in self.rows().get("flat") or [] if up(r.get("workspace_id")) == mirror), None)
            if flat is None:
                raise Failure("the mirror is not in the flat list")
            lines = (flat.get("subtitle_candidates") or []) + [c for line in flat.get("branch_directory_lines") or [] for c in line]
            if not any(str(folder.name) in line for line in lines):
                raise Failure(f"no directory line yet: {lines}")
            return {"lines": lines, "device_label": flat.get("device_label")}

        found = wait_for("the mirror's directory line", subtitle, self.timeout)
        repeated = [line for line in found["lines"] if self.mac_name and self.mac_name in line]
        if repeated:
            raise Failure(f"the directory line repeats the Mac name: {repeated}")
        return found

    def close_prompt_is_safe(self) -> Dict[str, Any]:
        prompt = self.sock.call("supermux.devices.close_prompt", {"workspace_id": self.mirrors[self.locals[0]]}) or {}
        buttons = {b.get("role"): b for b in prompt.get("buttons") or []}
        close, hide, cancel = buttons.get("close_on_mac"), buttons.get("hide"), buttons.get("cancel")
        problems: List[str] = []
        if close is None or cancel is None or hide is None:
            raise Failure(f"expected Close on <Mac>, Hide Here and Cancel: {prompt.get('buttons')}")
        if not close.get("destructive"):
            problems.append("Close on <Mac> is not marked destructive")
        if close.get("key_equivalent") == "\r":
            problems.append("Close on <Mac> is the Return default")
        if cancel.get("key_equivalent") != "\r":
            problems.append(f"Cancel is not the default (key {cancel.get('key_equivalent')!r})")
        if prompt.get("escape_role") != "cancel":
            problems.append(f"Esc answers {prompt.get('escape_role')!r}, not Cancel")
        text = (prompt.get("message_text") or "") + "\n" + (prompt.get("informative_text") or "")
        if text.count(self.mac_name) > 1:
            problems.append(f"the text names the Mac {text.count(self.mac_name)} times")
        if (close.get("title") or "").count(self.mac_name) != 1:
            problems.append(f"the Close button names the Mac {(close.get('title') or '').count(self.mac_name)} times")
        if "worktree" not in text.lower():
            problems.append("the text does not say what happens to the worktree")
        if "Hide Here" not in text:
            problems.append("the text does not explain Hide Here")
        if problems:
            raise Failure("; ".join(problems) + f" — prompt: {prompt}")
        return {"prompt": prompt}

    # -- run ------------------------------------------------------------------

    def cleanup(self) -> None:
        # Close the sources only: auto-mirror closes each mirror once its
        # remote workspace is gone. (Hiding the mirrors and unhiding them
        # afterwards raced that removal and could reopen a mirror.)
        try:
            for workspace_id in self.created:
                self.sock.call("workspace.close", {"workspace_id": workspace_id})
            wait_for("the mirrors to close with their sources",
                     lambda: not any(self.mirror_of(w) for w in self.created), self.timeout)
            if self.project_id:
                self.request("mobile.supermux.project.delete", {"project_id": self.project_id})
            if self.initial_auto_mirror is False:
                self.sock.call("supermux.devices.set_auto_mirror", {"enabled": False})
        except (Failure, OSError) as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))
        if not self.args.keep:
            shutil.rmtree(self.root, ignore_errors=True)

    def run(self) -> bool:
        ok = self.step("setup", self.setup) and self.step("project_with_local_and_mirror_rows", self.project_with_rows)
        if ok:
            for name, check in [
                ("nested_rows_local_first", self.nested_rows_local_first),
                ("nested_mirror_label_names_mac", self.nested_mirror_label_names_mac),
                ("nested_rows_show_status", self.nested_rows_show_status),
                ("flat_mirror_subtitle_omits_mac", self.flat_mirror_subtitle_omits_mac),
                ("close_prompt_is_safe", self.close_prompt_is_safe),
            ]:
                ok = self.step(name, check) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    parser.add_argument("--scratch", default=None, help="scratch folder for the test repos (default /tmp/<tag>-rows)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per wait")
    parser.add_argument("--keep", action="store_true", help="keep the scratch repos")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    args.scratch = args.scratch or f"/tmp/{args.tag or 'socket'}-rows"
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = SidebarRowsE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except (OSError, Failure) as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-sidebar-rows-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_sidebar_rows_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
