#!/usr/bin/env python3
"""Capture Claude Code stream-json fixtures from a real local CLI process.

Examples:
  python3 capture_fixtures.py all
  python3 capture_fixtures.py simple
  python3 capture_fixtures.py controls
  python3 capture_fixtures.py resume

The normal turn fixtures contain stdout exactly as emitted by Claude Code.
controls.jsonl additionally interleaves the exact control_request lines written
by this driver so each request/response pair is preserved in one NDJSON file.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
import uuid
from typing import Any, Callable

FIXTURES = Path(__file__).resolve().parent
WORKDIR = Path("/tmp/supermux-claude-harness-fixtures")
DEFAULT_CLAUDE = shutil.which("claude") or "claude"
DEFAULT_CCX = "/Users/syedrajin/.local/bin/ccx"

JsonObject = dict[str, Any]


def compact_json(value: JsonObject) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


class StreamSession:
    def __init__(
        self,
        launcher: str,
        *,
        extra_args: list[str] | None = None,
        env: dict[str, str] | None = None,
        record_stdin: bool = False,
    ) -> None:
        WORKDIR.mkdir(parents=True, exist_ok=True)
        args = [
            launcher,
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--include-partial-messages",
            "--include-hook-events",
            "--verbose",
            "--permission-prompt-tool",
            "stdio",
            "--replay-user-messages",
        ]
        args.extend(extra_args or [])
        self.process = subprocess.Popen(
            args,
            cwd=WORKDIR,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        self.record_stdin = record_stdin
        self.transcript: list[str] = []
        self.events: list[tuple[str, JsonObject | None]] = []
        self.stderr_lines: list[str] = []
        self._condition = threading.Condition()
        self._stdout_done = threading.Event()
        self._stderr_done = threading.Event()
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self.process.stdout is not None
        for raw in self.process.stdout:
            line = raw.rstrip("\n")
            parsed: JsonObject | None = None
            if line.lstrip().startswith("{"):
                try:
                    value = json.loads(line)
                    if isinstance(value, dict):
                        parsed = value
                except json.JSONDecodeError:
                    pass
            with self._condition:
                self.transcript.append(line)
                self.events.append((line, parsed))
                self._condition.notify_all()
        self._stdout_done.set()
        with self._condition:
            self._condition.notify_all()

    def _read_stderr(self) -> None:
        assert self.process.stderr is not None
        for raw in self.process.stderr:
            self.stderr_lines.append(raw.rstrip("\n"))
        self._stderr_done.set()

    def send(self, value: JsonObject, *, record: bool | None = None) -> None:
        line = compact_json(value)
        if record if record is not None else self.record_stdin:
            with self._condition:
                self.transcript.append(line)
                self.events.append((line, value))
                self._condition.notify_all()
        if self.process.stdin is None:
            raise RuntimeError("stdin unavailable")
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

    def send_user(self, text: str) -> None:
        self.send(
            {
                "type": "user",
                "message": {
                    "role": "user",
                    "content": [{"type": "text", "text": text}],
                },
            },
            record=False,
        )

    def wait_for(
        self,
        predicate: Callable[[JsonObject], bool],
        *,
        start: int = 0,
        timeout: float = 120.0,
    ) -> tuple[int, JsonObject]:
        deadline = time.monotonic() + timeout
        cursor = start
        with self._condition:
            while True:
                while cursor < len(self.events):
                    _, parsed = self.events[cursor]
                    index = cursor
                    cursor += 1
                    if parsed is not None and predicate(parsed):
                        return index, parsed
                if self.process.poll() is not None and self._stdout_done.is_set():
                    raise RuntimeError(
                        f"process exited {self.process.returncode} before expected event; "
                        f"stderr={self.stderr_text()!r}"
                    )
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"timed out waiting for event; stderr={self.stderr_text()!r}")
                self._condition.wait(min(remaining, 0.25))

    def wait_for_result(self, *, start: int = 0, timeout: float = 180.0) -> JsonObject:
        _, result = self.wait_for(
            lambda value: value.get("type") == "result",
            start=start,
            timeout=timeout,
        )
        return result

    def close(self, timeout: float = 20.0) -> int:
        if self.process.stdin is not None and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            return self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                return self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                return self.process.wait(timeout=5)

    def stderr_text(self) -> str:
        return "\n".join(self.stderr_lines)

    def reset_capture(self) -> None:
        """Start a fresh capture window without restarting the real process."""
        with self._condition:
            self.transcript.clear()
            self.events.clear()

    def write(self, path: Path) -> None:
        path.write_text("\n".join(self.transcript) + "\n", encoding="utf-8")


def control_request(request_id: str, subtype: str, **payload: Any) -> JsonObject:
    request: JsonObject = {"subtype": subtype}
    request.update(payload)
    return {"type": "control_request", "request_id": request_id, "request": request}


def wait_for_control(session: StreamSession, request_id: str, *, start: int = 0) -> JsonObject:
    _, response = session.wait_for(
        lambda value: value.get("type") == "control_response"
        and value.get("response", {}).get("request_id") == request_id,
        start=start,
        timeout=45,
    )
    return response


def capture_turn(
    destination: Path,
    launcher: str,
    prompt: str,
    *,
    extra_args: list[str] | None = None,
    env: dict[str, str] | None = None,
) -> JsonObject:
    session = StreamSession(launcher, extra_args=extra_args, env=env)
    session.send_user(prompt)
    result = session.wait_for_result(timeout=240)
    session.close()
    # Print mode may exit 1 for protocol-level terminal outcomes (notably an
    # interrupt) after still emitting a complete result object. The fixture's
    # result line is authoritative; process-exit behavior is documented beside it.
    session.write(destination)
    return result


def capture_simple(claude: str) -> None:
    session = StreamSession(
        claude,
        extra_args=["--model", "haiku", "--effort", "low", "--permission-mode", "default"],
    )
    # Claude Code defaults to thinking even for Haiku. Configure a zero budget
    # before the turn, then begin the fixture capture window. The resulting file
    # is a complete, unedited text-only turn beginning at system.init.
    disable = control_request("fixture-disable-thinking", "set_max_thinking_tokens", max_thinking_tokens=0)
    session.send(disable, record=False)
    wait_for_control(session, disable["request_id"])
    session.reset_capture()
    session.send_user(
        "Reply with exactly this sentence and use no tools: Simple fixture captured successfully."
    )
    session.wait_for_result(timeout=180)
    session.close()
    session.write(FIXTURES / "simple-turn.jsonl")


def capture_thinking(claude: str) -> None:
    capture_turn(
        FIXTURES / "thinking-turn.jsonl",
        claude,
        "Think hard about 27*43, then answer with the product and one short verification sentence. Use no tools.",
        extra_args=["--model", "claude-fable-5[1m]", "--effort", "high", "--permission-mode", "default"],
    )


def capture_tool(claude: str) -> None:
    capture_turn(
        FIXTURES / "tool-turn.jsonl",
        claude,
        "Use the Bash tool to run exactly `echo ok` once. Then report the output in one sentence. Do not use any other tool.",
        extra_args=["--dangerously-skip-permissions", "--model", "haiku", "--effort", "low"],
    )


def response_payload(response: JsonObject) -> JsonObject:
    outer = response.get("response")
    if not isinstance(outer, dict):
        return {}
    inner = outer.get("response")
    return inner if isinstance(inner, dict) else {}


def capture_controls(claude: str) -> None:
    session = StreamSession(
        claude,
        extra_args=["--permission-mode", "default"],
        record_stdin=True,
    )

    request_id = "fixture-list-models"
    session.send(control_request(request_id, "list_models"))
    models_response = wait_for_control(session, request_id)
    models = response_payload(models_response).get("models", [])
    if not isinstance(models, list) or not models:
        raise RuntimeError(f"list_models returned no models: {models_response}")
    selected = next(
        (
            item
            for item in models
            if isinstance(item, dict)
            and item.get("supportsFastMode") is True
            and isinstance(item.get("value"), str)
        ),
        models[0],
    )
    selected_value = selected.get("value") if isinstance(selected, dict) else None
    if not isinstance(selected_value, str):
        raise RuntimeError(f"model entry has no value: {selected!r}")

    requests = [
        control_request("fixture-set-model", "set_model", model=selected_value),
        control_request("fixture-set-permission-plan", "set_permission_mode", mode="plan"),
        control_request(
            "fixture-set-thinking",
            "set_max_thinking_tokens",
            max_thinking_tokens=4096,
        ),
        control_request(
            "fixture-set-effort",
            "apply_flag_settings",
            settings={"effortLevel": "high"},
        ),
        control_request(
            "fixture-set-fast-mode",
            "apply_flag_settings",
            settings={"fastMode": True},
        ),
    ]
    for request in requests:
        session.send(request)
        wait_for_control(session, request["request_id"])

    session.send_user(
        "Write a very long explanation of every integer from 1 through 10000. "
        "Begin immediately and continue until interrupted. Use no tools."
    )
    stream_index, _ = session.wait_for(
        lambda value: value.get("type") == "stream_event"
        and value.get("event", {}).get("type")
        in {"message_start", "content_block_start", "content_block_delta"},
        timeout=120,
    )
    interrupt = control_request("fixture-interrupt", "interrupt")
    session.send(interrupt)
    wait_for_control(session, interrupt["request_id"], start=stream_index)
    session.wait_for_result(start=stream_index, timeout=180)

    # Claude Code 2.1.227 exits 1 after an interrupted print-mode turn even
    # though it emits a complete result object. Preserve that observed exit
    # behavior in README/WIRE-NOTES rather than rejecting the capture.
    session.close()
    session.write(FIXTURES / "controls.jsonl")


def capture_resume(claude: str) -> None:
    fresh_id = str(uuid.uuid4())
    first = StreamSession(
        claude,
        extra_args=["--session-id", fresh_id, "--model", "haiku", "--effort", "low"],
    )
    first.send_user("Reply exactly: FIRST RUN COMPLETE")
    first_result = first.wait_for_result(timeout=180)
    provider_id = first_result.get("session_id")
    if not isinstance(provider_id, str):
        raise RuntimeError(f"first resume run has no session_id: {first_result}")
    first_exit = first.close()
    if first_exit != 0:
        raise RuntimeError(f"first resume run exited {first_exit}: {first.stderr_text()}")
    first.write(FIXTURES / "resume-first.jsonl")

    second = StreamSession(
        claude,
        extra_args=["--resume", provider_id, "--model", "haiku", "--effort", "low"],
    )
    second.send_user("Reply exactly: SECOND RUN RESUMED")
    second_result = second.wait_for_result(timeout=180)
    if second_result.get("session_id") != provider_id:
        raise RuntimeError(
            f"resume changed session id: expected {provider_id}, got {second_result.get('session_id')}"
        )
    second_exit = second.close()
    if second_exit != 0:
        raise RuntimeError(f"second resume run exited {second_exit}: {second.stderr_text()}")
    second.write(FIXTURES / "resume-second.jsonl")


def capture_permission(launcher: str, decision: str, destination: Path) -> None:
    session = StreamSession(
        launcher,
        extra_args=["--permission-mode", "default"],
    )
    session.send_user(
        "Use the Write tool to create /tmp/supermux-claude-harness-fixtures/permission.txt "
        "with content approved. Do nothing else."
    )
    _, request = session.wait_for(
        lambda value: value.get("type") == "control_request"
        and value.get("request", {}).get("subtype") == "can_use_tool",
        timeout=180,
    )
    request_id = request["request_id"]
    tool_input = request.get("request", {}).get("input")
    if decision == "allow":
        answer: JsonObject = {"behavior": "allow", "updatedInput": tool_input}
    else:
        answer = {"behavior": "deny", "message": "User denied this operation."}
    session.send(
        {
            "type": "control_response",
            "response": {
                "subtype": "success",
                "request_id": request_id,
                "response": answer,
            },
        },
        record=False,
    )
    session.wait_for_result(timeout=240)
    exit_code = session.close()
    if exit_code != 0:
        raise RuntimeError(f"permission session exited {exit_code}: {session.stderr_text()}")
    session.write(destination)


def capture_all(claude: str) -> None:
    capture_simple(claude)
    capture_thinking(claude)
    capture_tool(claude)
    capture_controls(claude)
    capture_resume(claude)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "capture",
        choices=["all", "simple", "thinking", "tool", "controls", "resume", "permission"],
    )
    parser.add_argument("--claude", default=DEFAULT_CLAUDE)
    parser.add_argument("--launcher", default=DEFAULT_CLAUDE)
    parser.add_argument("--decision", choices=["allow", "deny"], default="allow")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    if args.capture == "all":
        capture_all(args.claude)
    elif args.capture == "simple":
        capture_simple(args.claude)
    elif args.capture == "thinking":
        capture_thinking(args.claude)
    elif args.capture == "tool":
        capture_tool(args.claude)
    elif args.capture == "controls":
        capture_controls(args.claude)
    elif args.capture == "resume":
        capture_resume(args.claude)
    else:
        output = args.output or FIXTURES / f"permission-{args.decision}.jsonl"
        capture_permission(args.launcher, args.decision, output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
