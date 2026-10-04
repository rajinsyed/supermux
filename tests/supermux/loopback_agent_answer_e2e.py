#!/usr/bin/env python3
"""End-to-end test that the working indicator comes back once the user answers
a Claude Code prompt (a question, a plan approval or a tool permission),
against one tagged DEBUG build running the loopback device.

Claude Code stops for the user on AskUserQuestion, on ExitPlanMode and on a
tool's permission prompt. It runs the tool's PreToolUse, then its
PermissionRequest hook (`cmux hooks feed`, which raises a Feed request beside
the terminal's own dialog) and a permission_prompt Notification; the rows and
the tab show "needs input". When the user answers in the terminal no hook says
so: Claude Code abandons the PermissionRequest hook, and its next hook is the
answered tool's PostToolUse (or, for a tool permission, the next tool's
PreToolUse). Each step replays those hooks through the tagged build's CLI with
the environment cmux's `claude` wrapper gives them (see
loopback_agent_activity_e2e.py), then reads S's and its mirror M's flat rows,
M's mirror status, the phone's row for S, T_A's tab spinner on S and on M and
S's pills:

  1. setup                     the loopback linked and fetched, auto-mirror on
  2. source_with_two_tabs      a workspace S with terminals T_A and T_B, and its mirror M
  3. answer_hook_installed     the settings cmux gives Claude Code run
                               `claude-hook post-tool-use` after AskUserQuestion
                               and ExitPlanMode
  4. question_answered_spins   (bypass permissions) a turn asks an
                               AskUserQuestion: every row says needsInput; its
                               PostToolUse (the answer): every row says working,
                               T_A's tab spins on S and on M and no pill says
                               "Needs input"; the next tool keeps it working;
                               Stop settles it
  5. plan_approved_spins       the same for an ExitPlanMode plan approval
  6. permission_answered_spins (default permissions) a Bash call's permission
                               prompt: needsInput; once the user approves in the
                               terminal, the next tool's PreToolUse: working
                               again and no pill says "Needs input"
  7. cleanup                   S closed (M closes with it), auto-mirror restored

Writes a JSON report (default
tests/supermux/artifacts/loopback_agent_answer_e2e-<tag>.json) and exits
non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_agent_answer_e2e.py [--scratch DIR] [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_agent_activity_e2e import AgentActivityE2E  # noqa: E402
from loopback_auto_mirror_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    REPO_ROOT,
    Failure,
    Socket,
    socket_path_for_tag,
    wait_for,
)

ANSWERED_TOOLS = ("AskUserQuestion", "ExitPlanMode")


class AgentAnswerE2E(AgentActivityE2E):
    # -- expectations ---------------------------------------------------------

    def expect_activity(self, value: str, description: str) -> Dict[str, Any]:
        """Waits until S's and M's rows, M's status and the phone all say `value`
        (the phone spells it in snake case)."""
        def same(state: Any) -> bool:
            return str(state).replace("_", "").lower() == value.lower()

        def check() -> Optional[Dict[str, Any]]:
            states = self.activities()
            if all(same(state) for state in states.values()):
                return states
            raise Failure(f"activity {states}")

        return wait_for(description, check, self.timeout)

    def expect_no_needs_input_pill(self) -> Dict[str, Any]:
        """Neither the agent's pill nor Feed's overlay still says Needs input."""
        def check() -> Optional[Dict[str, Any]]:
            entries = self.indicators(self.source).get("status_entries") or []
            bells = [e for e in entries if e.get("icon") == "bell.fill"]
            if bells:
                raise Failure(f"needs-input pills {bells}")
            return {"pill": self.agent_pill()}

        return wait_for("no pill to say Needs input", check, self.timeout)

    # -- hooks ----------------------------------------------------------------

    def tool_payload(self, base: Dict[str, Any], event: str, tool: str, tool_use_id: str,
                     tool_input: Dict[str, Any], mode: str) -> Dict[str, Any]:
        """A tool hook's stdin, shaped like Claude Code's own (its
        PermissionRequest names no tool_use_id)."""
        payload = {**base, "hook_event_name": event, "permission_mode": mode, "tool_name": tool,
                   "tool_input": tool_input}
        if event != "PermissionRequest":
            payload["tool_use_id"] = tool_use_id
        if event == "PostToolUse":
            payload["tool_response"] = {"ok": True}
        return payload

    def answer(self, base: Dict[str, Any], tool: str, tool_use_id: str, tool_input: Dict[str, Any],
               mode: str) -> None:
        """The user answers: Claude Code runs the answered tool's PostToolUse.
        A build without the hook only records the refusal, so the step fails on
        what the user sees (the rows), not on the hook's exit status."""
        try:
            self.hook("post-tool-use", self.tool_payload(base, "PostToolUse", tool, tool_use_id, tool_input, mode))
        except Failure as error:
            self.facts.setdefault("answer_hook_errors", []).append(str(error))

    def ask(self, base: Dict[str, Any], tool: str, tool_use_id: str, tool_input: Dict[str, Any],
            mode: str, message: str) -> subprocess.Popen:
        """Claude Code stops on `tool` for the user: its PreToolUse, its
        PermissionRequest (Feed) and the permission prompt notification."""
        self.hook("pre-tool-use", self.tool_payload(base, "PreToolUse", tool, tool_use_id, tool_input, mode))
        request = self.start_permission_request(
            self.tool_payload(base, "PermissionRequest", tool, tool_use_id, tool_input, mode))
        self.hook("notification", {**base, "hook_event_name": "Notification", "notification_type": "permission_prompt",
                                   "message": message})
        return request

    def reap(self, request: Optional[subprocess.Popen]) -> None:
        """Records how the PermissionRequest hook ended (Claude Code abandons it
        once the user answers in the terminal)."""
        if request is None:
            return
        try:
            request.wait(timeout=5)
            reply = (request.stdout.read() if request.stdout else "").strip()[:200]
        except subprocess.TimeoutExpired:
            request.kill()
            reply = "still waiting 5 s after the answer"
        self.facts.setdefault("permission_request_replies", []).append(reply)

    def start_turn(self, mode: str) -> Dict[str, Any]:
        session = f"e2e-{self.nonce}-{uuid.uuid4().hex[:8]}"
        base = {"session_id": session, "cwd": str(self.root), "transcript_path": str(self.root / f"{session}.jsonl")}
        self.hook("session-start", {**base, "hook_event_name": "SessionStart", "source": "startup"})
        self.hook("prompt-submit", {**base, "hook_event_name": "UserPromptSubmit", "permission_mode": mode,
                                    "prompt": "e2e prompt answer"})
        self.expect_activity("working", "the prompt to mark S working")
        return base

    def finish_turn(self, base: Dict[str, Any], mode: str, result: Dict[str, Any]) -> None:
        """The next tool keeps S working and Stop settles it."""
        self.hook("pre-tool-use", self.tool_payload(base, "PreToolUse", "Bash", f"toolu_{uuid.uuid4().hex[:12]}",
                                                    {"command": "echo next"}, mode))
        result["next_tool"] = self.expect_activity("working", "the next tool to keep S working")
        self.hook("stop", {**base, "hook_event_name": "Stop", "stop_hook_active": False,
                           "last_assistant_message": f"agent-answer-{self.nonce} done"})
        result["settled"] = wait_for("Stop to settle S", lambda: (
            all(state != "working" for state in self.activities().values()) or None), self.timeout)

    # -- steps ----------------------------------------------------------------

    def answer_hook_installed(self) -> Dict[str, Any]:
        """The settings cmux injects into Claude Code route the answered tools'
        PostToolUse to `claude-hook post-tool-use`."""
        env = {key: os.environ[key] for key in ("PATH", "HOME", "USER", "TMPDIR") if key in os.environ}
        env["CMUX_TAG"] = self.args.tag
        completed = subprocess.run([str(REPO_ROOT / "scripts" / "cmux-debug-cli.sh"), "hooks", "claude",
                                    "inject-settings"], env=env, capture_output=True, text=True,
                                   timeout=60, check=False)
        if completed.returncode != 0:
            raise Failure(f"inject-settings exited {completed.returncode}: {completed.stderr.strip()[:300]}")
        groups = (json.loads(completed.stdout).get("hooks") or {}).get("PostToolUse") or []
        for group in groups:
            matched = set(str(group.get("matcher", "")).split("|"))
            commands = " ".join(str(hook.get("command", "")) for hook in group.get("hooks") or [])
            if set(ANSWERED_TOOLS) <= matched and "post-tool-use" in commands:
                return {"group_matcher": group.get("matcher")}
        raise Failure(f"no PostToolUse post-tool-use group for {ANSWERED_TOOLS}: "
                      f"{[g.get('matcher') for g in groups]}")

    def answered_turn(self, tool: str, tool_input: Dict[str, Any]) -> Dict[str, Any]:
        """A bypass-permissions turn blocks on `tool`, the user answers, it works on."""
        mode = "bypassPermissions"
        self.start_claude_stand_in()
        request: Optional[subprocess.Popen] = None
        try:
            base = self.start_turn(mode)
            tool_use_id = f"toolu_{uuid.uuid4().hex[:12]}"
            request = self.ask(base, tool, tool_use_id, tool_input, mode, "Claude needs your permission")
            # Guard (passes today): the prompt shows as needs input.
            result: Dict[str, Any] = {"asked": self.expect_activity("needsInput", f"{tool} to mark S needs input")}
            self.answer(base, tool, tool_use_id, tool_input, mode)
            result["answered"] = self.expect_activity("working", f"the answer to {tool} to mark S working again")
            result["tab"] = self.expect_loading(lambda: self.local_tab(self.source, self.tab_a), True,
                                                "T_A's tab to spin again once answered")
            result["mirror_tab"] = self.expect_loading(lambda: self.mirror_tab(self.mirror, self.tab_a), True,
                                                       "the mirror's T_A tab to spin again once answered")
            result["pill"] = self.expect_no_needs_input_pill()
            self.finish_turn(base, mode, result)
            return result
        finally:
            self.reap(request)
            self.stop_claude_stand_in()

    def question_answered_spins(self) -> Dict[str, Any]:
        return self.answered_turn("AskUserQuestion", {"questions": [{
            "question": "Red or blue?", "header": "Color", "multiSelect": False,
            "options": [{"label": "Red", "description": "red"}, {"label": "Blue", "description": "blue"}]}]})

    def plan_approved_spins(self) -> Dict[str, Any]:
        return self.answered_turn("ExitPlanMode", {"plan": "1. Edit the file\n2. Run the tests"})

    def tagged_cli(self) -> Path:
        """The tagged build's bundled CLI, as scripts/cmux-debug-cli.sh finds it."""
        derived = os.environ.get("CMUX_DERIVED_DATA") or str(
            Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData" / f"cmux-{self.args.tag}")
        return Path(derived) / "Build" / "Products" / "Debug" / f"cmux DEV {self.args.tag}.app" / "Contents" / "Resources" / "bin" / "cmux"

    def start_permission_request(self, payload: Dict[str, Any]) -> subprocess.Popen:
        """Claude Code's PermissionRequest hook (`cmux hooks feed --source
        claude`), run from T_A's environment as Claude Code runs it: it raises
        a Feed request beside the terminal's own dialog and waits for a Feed
        decision that never comes when the user answers in the terminal.
        (scripts/cmux-debug-cli.sh drops the CMUX_SURFACE_ID it routes by.)"""
        cli = self.tagged_cli()
        if not cli.exists():
            raise Failure(f"no tagged CLI at {cli}")
        env = {key: os.environ[key] for key in ("PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG") if key in os.environ}
        env.update(CMUX_TAG=self.args.tag, CMUX_SOCKET_PATH=self.sock.path, CMUX_BUNDLED_CLI_PATH=str(cli),
                   CMUX_WORKSPACE_ID=self.source, CMUX_SURFACE_ID=self.tab_a,
                   CMUX_CLI_SENTRY_DISABLED="1", CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1")
        env.update(self.claude_wrapper_env())
        process = subprocess.Popen([str(cli), "hooks", "feed", "--source", "claude"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
        assert process.stdin is not None
        process.stdin.write(json.dumps(payload))
        process.stdin.close()
        return process

    def permission_answered_spins(self) -> Dict[str, Any]:
        """A default-permissions Bash call waits on Claude's permission prompt;
        the user approves it in the terminal and Claude runs its next tool."""
        mode = "default"
        self.start_claude_stand_in()
        request: Optional[subprocess.Popen] = None
        try:
            base = self.start_turn(mode)
            tool_use_id = f"toolu_{uuid.uuid4().hex[:12]}"
            tool_input = {"command": "sleep 1; echo approved"}
            request = self.ask(base, "Bash", tool_use_id, tool_input, mode, "Claude needs your permission to use Bash")
            result: Dict[str, Any] = {"asked": self.expect_activity("needsInput", "the permission prompt to mark S needs input")}
            # The user approves in the terminal: no hook says so; the tool runs
            # and Claude Code's next hook is its next tool's PreToolUse.
            self.hook("pre-tool-use", self.tool_payload(base, "PreToolUse", "Read", f"toolu_{uuid.uuid4().hex[:12]}",
                                                        {"file_path": str(self.root / "README.md")}, mode))
            result["answered"] = self.expect_activity("working", "the next tool after the approval to mark S working again")
            result["tab"] = self.expect_loading(lambda: self.local_tab(self.source, self.tab_a), True,
                                                "T_A's tab to spin again once approved")
            result["pill"] = self.expect_no_needs_input_pill()
            self.hook("stop", {**base, "hook_event_name": "Stop", "stop_hook_active": False,
                               "last_assistant_message": f"agent-answer-{self.nonce} done"})
            return result
        finally:
            self.reap(request)
            self.stop_claude_stand_in()

    def run(self) -> bool:
        ok = self.step("setup", self.setup) and self.step("source_with_two_tabs", self.source_with_two_tabs)
        if ok:
            for name, check in [
                ("answer_hook_installed", self.answer_hook_installed),
                ("question_answered_spins", self.question_answered_spins),
                ("plan_approved_spins", self.plan_approved_spins),
                ("permission_answered_spins", self.permission_answered_spins),
            ]:
                ok = self.step(name, check) and ok
        return self.step("cleanup", self.cleanup) and ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock)")
    parser.add_argument("--scratch", default=None, help="scratch folder (default /tmp/<tag>-answer)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per wait")
    parser.add_argument("--keep", action="store_true", help="keep the scratch folder")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag:
        parser.error("set CMUX_TAG (or pass --tag): the hook steps run the tagged build's CLI")
    args.scratch = args.scratch or f"/tmp/{args.tag}-answer"
    args.report_path = args.report or str(ARTIFACTS_DIR / f"loopback_agent_answer_e2e-{args.tag}.json")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = AgentAnswerE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except (OSError, Failure) as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-agent-answer-e2e",
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
