#!/usr/bin/env python3
"""End-to-end test of the orange agent-working indicator while an agent is
"Waiting" (its turn ended with background shells, subagents or crons still
running) and of the per-tab working spinner, against one tagged DEBUG build
running the loopback device.

The loopback device ("Loopback Mac") is this same app's own mobile host, so a
local workspace S also has a mirror M: M's rows and tabs show what another Mac
would see of S. `supermux.devices.mirror.tab_indicators` reads each tab of a
workspace straight from its pane tab bar (`is_loading` is the tab's working
spinner; a mirror tab names the terminal it shows as `remote_surface_id`).
Checks:

  1. setup                    the loopback linked and fetched, auto-mirror on
  2. source_with_two_tabs     a workspace S with two terminals T_A and T_B, and its
                              mirror M showing both
  3. waiting_spins_rows       T_A's agent Waiting (`backgroundWorkPending`): S's and
                              M's flat rows, M's mirror status and the phone's
                              `mobile.workspace.list` row all say `working`
  4. waiting_spins_tab        the same: T_A's tab spins on S and on M, T_B's does not
                              (window screenshots of S and M kept next to the report)
  5. spinner_follows_the_tab  T_A idle, T_B running: the spinner moves to T_B on S
                              and on M (per tab, not per workspace)
  6. settled_clears           both idle: no row is working and no tab spins
  7. hook_driven_waiting      a real `cmux claude-hook` turn: prompt-submit, then a
                              Stop with a background task still running. Each hook
                              runs with the environment cmux's `claude` wrapper gives
                              Claude Code and its hooks (CMUX_CLAUDE_PID of a live
                              stand-in running in T_A, the CMUX_AGENT_LAUNCH_* launch
                              capture): upstream shows an agent's pill only while a
                              live PID registered by SessionStart owns it, and
                              notifies only a pane whose resume binding (published
                              from the launch capture) names the session. Upstream's
                              grey "Waiting" pill shows (guard), no notification
                              arrives while waiting (guard), the rows and T_A's tab
                              keep the working indicator; a second Stop with no
                              background work settles it: nothing spins and the
                              completion notification arrives
  8. cleanup                  S closed (M closes with it), auto-mirror restored

Writes a JSON report (default tests/supermux/artifacts/loopback_agent_activity_e2e-<tag>.json)
and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_agent_activity_e2e.py [--scratch DIR] [--report PATH]
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import signal
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
    REPO_ROOT,
    Failure,
    Socket,
    hold,
    socket_path_for_tag,
    up,
    wait_for,
)

AGENT_KEY = "claude_code"
# The environment a hook run keeps from ours; everything agent- or cmux-shaped
# is dropped so the hook never reads as a nested agent or targets another app.
HOOK_ENV_KEYS = ("PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "CMUX_DERIVED_DATA")
# The Claude Code stand-in run in T_A: it records its PID, then becomes a long sleep
# under that same PID (exec), as cmux's `claude` wrapper execs Claude Code.
CLAUDE_STAND_IN = """#!/bin/sh
echo $$ > "$1"
exec sleep 900
"""


class AgentActivityE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.root = Path(args.scratch) / f"activity-{self.nonce}"
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "scratch": str(self.root)}
        self.machine = ""
        self.source = ""
        self.mirror = ""
        self.tab_a = ""
        self.tab_b = ""
        self.claude_pid: Optional[int] = None
        self.initial_auto_mirror: Optional[bool] = None

    # -- reads ----------------------------------------------------------------

    def request(self, method: str, params: Dict[str, Any], timeout_s: float = 60) -> Dict[str, Any]:
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

    def mirror_binding(self) -> Optional[Dict[str, Any]]:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        found = [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(self.source)]
        if len(found) > 1:
            raise Failure(f"{len(found)} mirrors of the source")
        return found[0] if found else None

    def terminals(self, workspace_id: str) -> List[str]:
        surfaces = (self.sock.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        return [up(s.get("id")) for s in surfaces if s.get("type") == "terminal"]

    def indicators(self, workspace_id: str) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.mirror.tab_indicators", {"workspace_id": workspace_id}) or {}

    def spinning(self) -> Dict[str, Dict[str, Any]]:
        """Whether T_A's and T_B's tabs spin, on S (by panel) and on M (by the
        terminal each mirror tab shows)."""
        found: Dict[str, Dict[str, Any]] = {"source": {}, "mirror": {}}
        for tab in self.indicators(self.source).get("tabs") or []:
            panel = up(tab.get("panel_id"))
            if panel in (self.tab_a, self.tab_b):
                found["source"][panel] = tab.get("is_loading")
        for tab in self.indicators(self.mirror).get("tabs") or []:
            remote = up(tab.get("remote_surface_id"))
            if remote in (self.tab_a, self.tab_b):
                found["mirror"][remote] = tab.get("is_loading")
        return found

    def activities(self) -> Dict[str, Any]:
        """S's and M's flat-row activity, M's mirror status activity and the
        phone's `supermux_activity` for S."""
        flat = (self.sock.call("supermux.devices.sidebar_rows", {}) or {}).get("flat") or []
        by_id = {up(r.get("workspace_id")): r.get("activity") for r in flat}
        binding = self.mirror_binding() or {}
        phone = next((w for w in self.request("mobile.workspace.list", {}).get("workspaces") or []
                      if up(w.get("id")) == up(self.source)), {})
        return {
            "source_row": by_id.get(up(self.source)),
            "mirror_row": by_id.get(up(self.mirror)),
            "mirror_status": (binding.get("status") or {}).get("activity"),
            "phone_source": phone.get("supermux_activity"),
        }

    def notifications_for_source(self) -> List[Dict[str, Any]]:
        records = (self.sock.call("supermux.devices.notification_records", {}) or {}).get("records") or []
        return [r for r in records if up(r.get("workspace_id")) == up(self.source)]

    def agent_pill(self) -> Optional[Dict[str, Any]]:
        entries = self.indicators(self.source).get("status_entries") or []
        return next((e for e in entries if e.get("key") == AGENT_KEY), None)

    # -- actions --------------------------------------------------------------

    def lifecycle(self, panel: str, value: str) -> None:
        self.sock.v1(f"set_agent_lifecycle {AGENT_KEY} {value} --tab={self.source} --panel={panel}")

    def hook(self, subcommand: str, payload: Dict[str, Any]) -> str:
        """Runs `cmux claude-hook <subcommand>` of the tagged build against S's
        T_A, as Claude Code's own hook would (JSON on stdin)."""
        if not self.args.tag:
            raise Failure("the claude-hook steps need CMUX_TAG (the tagged build's CLI)")
        env = {key: os.environ[key] for key in HOOK_ENV_KEYS if key in os.environ}
        env.update(
            CMUX_TAG=self.args.tag,
            CMUX_CLAUDE_HOOK_STATE_PATH=str(self.root / "claude-hook-sessions.json"),
            CMUX_CLI_SENTRY_DISABLED="1",
            CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1",
        )
        env.update(self.claude_wrapper_env())
        command = [str(REPO_ROOT / "scripts" / "cmux-debug-cli.sh"), "claude-hook", subcommand,
                   "--workspace", self.source, "--surface", self.tab_a]
        completed = subprocess.run(command, input=json.dumps(payload), env=env,
                                   capture_output=True, text=True, timeout=60, check=False)
        self.facts.setdefault("hook_runs", []).append({
            "subcommand": subcommand, "exit": completed.returncode,
            "stdout": completed.stdout.strip()[:300], "stderr": completed.stderr.strip()[:300],
        })
        if completed.returncode != 0:
            raise Failure(f"claude-hook {subcommand} exited {completed.returncode}: {completed.stderr.strip()[:300]}")
        return completed.stdout

    def claude_executable(self) -> Path:
        return self.root / "claude"

    def claude_wrapper_env(self) -> Dict[str, str]:
        """What cmux's `claude` wrapper exports to Claude Code, and so to every
        hook it runs: the agent's PID (the wrapper execs Claude Code, so its
        own $$) and the launch capture (kind, executable, cwd, argv) the hooks
        publish as the pane's resume binding."""
        if not self.claude_pid:
            return {}
        executable = str(self.claude_executable())
        return {
            "CMUX_CLAUDE_PID": str(self.claude_pid),
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": executable,
            "CMUX_AGENT_LAUNCH_CWD": str(self.root),
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64.b64encode((executable + "\0").encode()).decode(),
        }

    def start_claude_stand_in(self) -> int:
        """Runs the Claude Code stand-in in T_A, as typing `claude` there would,
        and returns its PID."""
        executable = self.claude_executable()
        executable.write_text(CLAUDE_STAND_IN)
        executable.chmod(0o755)
        pid_file = self.root / "claude.pid"
        pid_file.unlink(missing_ok=True)
        self.sock.call("surface.send_text", {"workspace_id": self.source, "surface_id": self.tab_a,
                                             "text": f"'{executable}' '{pid_file}'\n"})

        def started() -> Optional[int]:
            text = pid_file.read_text().strip() if pid_file.exists() else ""
            return int(text) if text.isdigit() else None

        self.claude_pid = wait_for("the Claude Code stand-in to start in T_A", started, self.timeout)
        self.facts["claude_stand_in_pid"] = self.claude_pid
        return self.claude_pid

    def stop_claude_stand_in(self) -> None:
        if self.claude_pid:
            try:
                os.kill(self.claude_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            self.claude_pid = None

    def screenshot(self, workspace_id: str, label: str) -> Optional[str]:
        """Best effort: selects the workspace and keeps a window screenshot
        next to the report."""
        try:
            self.sock.call("workspace.select", {"workspace_id": workspace_id})
            time.sleep(1.0)
            shot = self.sock.call("debug.window.screenshot", {"label": f"agent-activity-{label}"}) or {}
        except Failure as error:
            self.facts.setdefault("screenshot_errors", []).append(str(error))
            return None
        path = str(shot.get("path") or "")
        if not path or not Path(path).exists():
            return None
        kept = Path(self.args.report_path).with_suffix("").as_posix() + f"-{label}.png"
        Path(kept).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, kept)
        return kept

    # -- expectations ---------------------------------------------------------

    def expect_rows(self, working: bool, description: str) -> Dict[str, Any]:
        def check() -> Optional[Dict[str, Any]]:
            states = self.activities()
            phone_working = states["phone_source"] == "working"
            rows_working = [states[k] == "working" for k in ("source_row", "mirror_row", "mirror_status")]
            if working and all(rows_working) and phone_working:
                return states
            if not working and not any(rows_working) and not phone_working:
                return states
            raise Failure(f"activity {states}")

        return wait_for(description, check, self.timeout)

    def expect_tabs(self, working: set, description: str) -> Dict[str, Any]:
        """Waits until exactly the `working` terminals' tabs spin, on S and on M."""
        def check() -> Optional[Dict[str, Any]]:
            found = self.spinning()
            for side in ("source", "mirror"):
                if set(found[side]) != {self.tab_a, self.tab_b}:
                    raise Failure(f"the {side}'s tabs for T_A/T_B are not all there: {found}")
                for terminal, loading in found[side].items():
                    if bool(loading) != (terminal in working):
                        raise Failure(f"tab spinners {self.named(found)}")
            return self.named(found)

        return wait_for(description, check, self.timeout)

    def named(self, found: Dict[str, Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
        names = {self.tab_a: "T_A", self.tab_b: "T_B"}
        return {side: {names.get(k, k): v for k, v in tabs.items()} for side, tabs in found.items()}

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
        state = self.sock.call("supermux.devices.remote_macs_settings", {}) or {}
        self.initial_auto_mirror = state.get("auto_mirror")
        if not self.initial_auto_mirror:
            self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True})
        self.root.mkdir(parents=True, exist_ok=True)
        return {"machine": self.machine}

    def source_with_two_tabs(self) -> Dict[str, Any]:
        title = f"agent-activity-{self.nonce}"
        created = self.sock.call("workspace.create", {"title": title, "focus": False,
                                                      "working_directory": str(self.root)}) or {}
        self.source = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not self.source:
            raise Failure(f"workspace.create returned no id: {created}")
        self.sock.call("workspace.rename", {"workspace_id": self.source, "title": title})
        self.tab_a = wait_for("the source's first terminal", lambda: (self.terminals(self.source) or [None])[0], self.timeout)
        added = self.sock.call("surface.create", {"workspace_id": self.source, "type": "terminal"}) or {}
        self.tab_b = up(added.get("surface_id"))
        if not self.tab_b:
            raise Failure(f"surface.create returned no surface_id: {added}")
        self.mirror = up(wait_for("the source's mirror", self.mirror_binding, self.timeout).get("workspace_id"))

        def both_projected() -> Optional[Dict[str, Any]]:
            found = self.spinning()
            if set(found["source"]) == {self.tab_a, self.tab_b} and set(found["mirror"]) == {self.tab_a, self.tab_b}:
                return found
            raise Failure(f"tabs so far {self.named(found)}")

        wait_for("both tabs on the source and on its mirror", both_projected, self.timeout)
        self.facts.update(source=self.source, mirror=self.mirror, tab_a=self.tab_a, tab_b=self.tab_b)
        return {"source": self.source, "mirror": self.mirror, "tab_a": self.tab_a, "tab_b": self.tab_b}

    def waiting_spins_rows(self) -> Dict[str, Any]:
        # Upstream's "Waiting": the turn is over, background work still runs.
        self.lifecycle(self.tab_a, "backgroundWorkPending")
        return {"activity": self.expect_rows(True, "every row to show S's waiting agent as working")}

    def waiting_spins_tab(self) -> Dict[str, Any]:
        problems: List[str] = []
        try:
            tabs = self.expect_tabs({self.tab_a}, "T_A's tab to spin on S and on M")
        except Failure as error:
            problems.append(str(error))
            tabs = self.named(self.spinning())
        # The record of what the window draws, kept whether or not it passed.
        shots = {"source": self.screenshot(self.source, "source-tabs"),
                 "mirror": self.screenshot(self.mirror, "mirror-tabs")}
        self.facts["screenshots"] = shots
        if problems:
            raise Failure("; ".join(problems) + f" — screenshots {shots}")
        return {"tabs": tabs, "screenshots": shots}

    def spinner_follows_the_tab(self) -> Dict[str, Any]:
        self.lifecycle(self.tab_a, "idle")
        self.lifecycle(self.tab_b, "running")
        rows = self.expect_rows(True, "the rows to stay working with T_B's agent running")
        return {"activity": rows, "tabs": self.expect_tabs({self.tab_b}, "the spinner to move to T_B on S and on M")}

    def settled_clears(self) -> Dict[str, Any]:
        self.lifecycle(self.tab_a, "idle")
        self.lifecycle(self.tab_b, "idle")
        rows = self.expect_rows(False, "no row to be working once both agents are idle")
        return {"activity": rows, "tabs": self.expect_tabs(set(), "no tab to spin once both agents are idle")}

    def hook_driven_waiting(self) -> Dict[str, Any]:
        self.start_claude_stand_in()
        try:
            return self.hook_turn()
        finally:
            self.stop_claude_stand_in()

    def hook_turn(self) -> Dict[str, Any]:
        session = f"e2e-{self.nonce}-{uuid.uuid4().hex[:8]}"
        base = {"session_id": session, "cwd": str(self.root)}
        self.hook("session-start", {**base, "hook_event_name": "SessionStart", "source": "startup"})
        self.hook("prompt-submit", {**base, "hook_event_name": "UserPromptSubmit", "prompt": "e2e background work"})
        # Precondition (passes today): the hook reaches S's T_A at all.
        self.expect_rows(True, "the prompt to mark S working")
        before = len(self.notifications_for_source())
        self.hook("stop", {**base, "hook_event_name": "Stop", "stop_hook_active": False,
                           "last_assistant_message": f"agent-activity-{self.nonce} still running",
                           "background_tasks": [{"id": "bg1", "type": "shell", "status": "running"}]})

        # Guard (passes today): upstream decided this turn is "Waiting".
        def waiting_pill() -> Optional[Dict[str, Any]]:
            pill = self.agent_pill()
            if pill and pill.get("work_state") == "waiting":
                return pill
            raise Failure(f"agent pill {pill}")

        pill = wait_for("upstream's Waiting pill on S", waiting_pill, self.timeout)
        # Guard (passes today): no notification until the work is done.
        hold("no notification for S while waiting",
             lambda: len(self.notifications_for_source()) == before, seconds=3)

        problems: List[str] = []
        result: Dict[str, Any] = {"waiting_pill": pill}
        for name, check in (
            ("rows", lambda: self.expect_rows(True, "every row to keep S's waiting agent working")),
            ("tabs", lambda: self.expect_tabs({self.tab_a}, "T_A's tab to keep spinning while waiting")),
        ):
            try:
                result[f"waiting_{name}"] = check()
            except Failure as error:
                problems.append(str(error))

        self.hook("stop", {**base, "hook_event_name": "Stop", "stop_hook_active": False,
                           "last_assistant_message": f"agent-activity-{self.nonce} done",
                           "background_tasks": [{"id": "bg1", "type": "shell", "status": "completed"}]})
        for name, check in (
            ("rows", lambda: self.expect_rows(False, "no row to be working once the background work is done")),
            ("tabs", lambda: self.expect_tabs(set(), "no tab to spin once the background work is done")),
            ("notification", lambda: wait_for(
                "the completion notification once the work is done",
                lambda: len(self.notifications_for_source()) > before, self.timeout)),
        ):
            try:
                result[f"settled_{name}"] = check()
            except Failure as error:
                problems.append(str(error))
        result["notifications_after"] = len(self.notifications_for_source()) - before
        if problems:
            raise Failure("; ".join(problems))
        return result

    def cleanup(self) -> Dict[str, Any]:
        # Close the source only: auto-mirror closes its mirror once the remote
        # workspace is gone.
        if self.source:
            self.sock.call("workspace.close", {"workspace_id": self.source, "force": True})
            wait_for("the mirror to close with its source", lambda: self.mirror_binding() is None, self.timeout)
        if self.initial_auto_mirror is False:
            self.sock.call("supermux.devices.set_auto_mirror", {"enabled": False})
        if not self.args.keep:
            shutil.rmtree(self.root, ignore_errors=True)
        return {"closed": self.source or None}

    def run(self) -> bool:
        ok = self.step("setup", self.setup) and self.step("source_with_two_tabs", self.source_with_two_tabs)
        if ok:
            for name, check in [
                ("waiting_spins_rows", self.waiting_spins_rows),
                ("waiting_spins_tab", self.waiting_spins_tab),
                ("spinner_follows_the_tab", self.spinner_follows_the_tab),
                ("settled_clears", self.settled_clears),
                ("hook_driven_waiting", self.hook_driven_waiting),
            ]:
                ok = self.step(name, check) and ok
        return self.step("cleanup", self.cleanup) and ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    parser.add_argument("--scratch", default=None, help="scratch folder (default /tmp/<tag>-activity)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per wait")
    parser.add_argument("--keep", action="store_true", help="keep the scratch folder")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    args.scratch = args.scratch or f"/tmp/{args.tag or 'socket'}-activity"
    args.report_path = args.report or str(ARTIFACTS_DIR / f"loopback_agent_activity_e2e-{args.tag or 'socket'}.json")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = AgentActivityE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except (OSError, Failure) as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-agent-activity-e2e",
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
