#!/usr/bin/env python3
"""Live smoke for the Phase 1 harness contract (not shipped, not a unit test).

Exercises the EXACT spawn arguments ClaudeSpawnArguments builds for a plain
claude launcher — including --dangerously-skip-permissions and NO permission
prompt flag — against the real CLI:

  1. one turn that forces a Write tool call, asserting the Write EXECUTES with
     no can_use_tool control_request (permissions skipped);
  2. an interrupt via control_request during a long generation, asserting the
     ack and the observed error_during_execution/aborted_streaming result;
  3. a resume of the first session, asserting provider session identity.

Run:  python3 live_smoke.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

BASE_ARGS = [
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
    "--replay-user-messages",
    "--dangerously-skip-permissions",
]


def claude_path():
    for candidate in [os.path.expanduser("~/.local/bin/claude"), shutil.which("claude")]:
        if candidate and os.path.exists(candidate):
            with open(candidate, "rb") as fh:
                head = fh.read(512)
            if b"cmux claude wrapper" in head:
                continue
            return candidate
    sys.exit("no non-wrapper claude found")


def user_line(text):
    return json.dumps({
        "type": "user",
        "message": {"role": "user", "content": [{"type": "text", "text": text}]},
    }) + "\n"


def run_session(args, stdin_lines, timeout=180, interrupt_after_first_delta=False):
    proc = subprocess.Popen(
        [claude_path()] + BASE_ARGS + args,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, cwd=WORKDIR,
    )
    lines, events = [], []
    interrupted = threading.Event()

    def reader():
        for raw in proc.stdout:
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                events.append(("NONJSON", raw[:80]))
                continue
            lines.append(obj)
            events.append((obj.get("type"), obj.get("subtype") or (obj.get("event") or {}).get("type")))
            if interrupt_after_first_delta and not interrupted.is_set():
                if obj.get("type") == "stream_event":
                    interrupted.set()
                    proc.stdin.write(json.dumps({
                        "type": "control_request",
                        "request_id": "smoke-interrupt",
                        "request": {"subtype": "interrupt"},
                    }) + "\n")
                    proc.stdin.flush()
            if obj.get("type") == "result":
                break

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    for line in stdin_lines:
        proc.stdin.write(line)
        proc.stdin.flush()
    thread.join(timeout)
    try:
        proc.stdin.close()
    except Exception:
        pass
    proc.wait(timeout=30)
    return proc.returncode, lines, events


WORKDIR = tempfile.mkdtemp(prefix="harness-smoke-")

print(f"claude: {claude_path()}  cwd: {WORKDIR}")

# ---- 1. Write tool executes without any permission prompt --------------------
target = os.path.join(WORKDIR, "smoke-write.txt")
session_id = str(uuid.uuid4())
rc, lines, events = run_session(
    ["--session-id", session_id, "--model", "haiku", "--effort", "low"],
    [user_line(
        f"Use the Write tool to create the file {target} with exactly the "
        "content 'harness-smoke-ok'. Do nothing else, then answer 'done'."
    )],
)
control_requests = [l for l in lines if l.get("type") == "control_request"]
results = [l for l in lines if l.get("type") == "result"]
init = next(l for l in lines if l.get("type") == "system" and l.get("subtype") == "init")
assert init["session_id"] == session_id, "session-id mismatch"
assert not control_requests, f"unexpected inbound control_request: {control_requests}"
assert os.path.exists(target), "Write did not execute"
content = open(target).read()
assert "harness-smoke-ok" in content, f"unexpected file content: {content!r}"
assert results and results[0]["subtype"] == "success"
print(f"1. WRITE OK  rc={rc}  no can_use_tool, file written, result success, "
      f"cost=${results[0].get('total_cost_usd')}")

# ---- 2. Interrupt ------------------------------------------------------------
rc2, lines2, events2 = run_session(
    ["--session-id", str(uuid.uuid4()), "--model", "haiku", "--effort", "low"],
    [user_line("Count from 1 to 5000, one number per line. Do not stop early.")],
    interrupt_after_first_delta=True,
)
acks = [l for l in lines2 if l.get("type") == "control_response"
        and l.get("response", {}).get("request_id") == "smoke-interrupt"]
results2 = [l for l in lines2 if l.get("type") == "result"]
assert acks, "no interrupt control_response"
assert results2, "no terminal result after interrupt"
r2 = results2[0]
print(f"2. INTERRUPT OK  rc={rc2}  ack still_queued="
      f"{acks[0]['response'].get('response', {}).get('still_queued')}  "
      f"result subtype={r2['subtype']} terminal_reason={r2.get('terminal_reason')}")

# ---- 3. Resume ---------------------------------------------------------------
rc3, lines3, _ = run_session(
    ["--resume", session_id, "--model", "haiku", "--effort", "low"],
    [user_line("What file did you just create? Answer with only its basename.")],
)
init3 = next(l for l in lines3 if l.get("type") == "system" and l.get("subtype") == "init")
results3 = [l for l in lines3 if l.get("type") == "result"]
assert init3["session_id"] == session_id, "resume changed the provider session id"
assert results3 and results3[0]["subtype"] == "success"
answer = results3[0].get("result", "")
print(f"3. RESUME OK  rc={rc3}  same session_id, answer={answer!r}")

assert "smoke-write" in answer, f"resumed session lost context: {answer!r}"
print("ALL SMOKE CHECKS PASSED")
