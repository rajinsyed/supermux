#!/usr/bin/env python3
"""Battery/CPU stress test of Supermux's own features with many worktrees,
local and mirrored, against one agent-only tagged DEBUG build running the
in-process loopback device (one app is both the headless host and the viewer).

It launches the tagged app itself (so it controls the environment), builds a
scratch project with N worktrees opened as workspaces, and measures the app
process through a fixed sequence of scenarios:

  idle_empty       one workspace, nothing running (the floor)
  idle_local       N worktree workspaces, nothing running
  busy_local       every worktree runs an agent stand-in (TUI spinner redraws
                   at 8 Hz, a log line a second, a file edit every 3 s) and
                   reports `running` agent lifecycle, so rows and tabs spin
  idle_mirrored    auto-mirror on: each worktree workspace also has a mirror
                   (its terminal streams through the loopback link)
  busy_mirrored    agents running, mirrored
  busy_hidden      Remote Host Mode on (no window on screen), agents running
  idle_hidden      Remote Host Mode on, nothing running

Per scenario it records, from the kernel's own per-process accounting
(proc_pid_rusage, no sudo): CPU seconds (user+system) and average CPU %,
package idle and interrupt wakeups per second, the CPU time of reaped child
processes (git, gh, lsof, ...), disk bytes written, plus every direct child
process spawned (sampled at ~100 Hz with proc_listchildpids, so a child that
lives under ~10 ms can be missed) and `top`'s POWER (Activity Monitor's
Energy Impact) averaged over 5 s samples.

Only an agent-only build: never --supermux-profile or --prod-auth
(require_isolated_app.py refuses those before anything launches). Never the
user's running app: the tag has its own bundle id and socket.

Usage:
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag <tag>
  python3 tests/supermux/stress_worktrees_energy.py --tag <tag> --app-path "<App path>" \
      [--worktrees 24] [--seconds 60] [--label baseline] [--report PATH]
  python3 tests/supermux/stress_worktrees_energy.py --compare BEFORE.json AFTER.json

Writes tests/supermux/artifacts/stress_worktrees_energy-<tag>-<label>.json
and exits non-zero when a step fails. Stdlib only.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import json
import os
import platform
import shutil
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_auto_mirror_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    LOOPBACK_DEVICE_ID,
    REPO_ROOT,
    Failure,
    Socket,
    socket_path_for_tag,
    up,
    wait_for,
)

AGENT_KEY = "claude_code"
LOOPBACK_MACHINE_PREFIX = f"device:{LOOPBACK_DEVICE_ID}@"
SETTLE_S = 10.0
SAMPLE_S = 8

# The agent stand-in each worktree terminal runs: a Claude Code-like TUI
# (spinner line redrawn at 8 Hz, a log line every second) that also edits a
# file in its worktree every 3 s, as an agent writing code does.
AGENT_SCRIPT = r'''
import sys, time
seconds = float(sys.argv[1])
spin = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
start = time.monotonic()
i = 0
while time.monotonic() - start < seconds:
    i += 1
    sys.stdout.write("\r\x1b[2K\x1b[33m%s\x1b[0m Working... step %d" % (spin[i % 10], i))
    if i % 8 == 0:
        sys.stdout.write("\n[agent] edited src/file_%d.ts (+%d -%d)\n" % (i % 50, i % 40, i % 7))
    sys.stdout.flush()
    if i % 24 == 0:
        with open("agent-notes-%d.txt" % (i % 5), "a") as f:
            f.write("change %d\n" % i)
    time.sleep(0.125)
sys.stdout.write("\n[agent] done\n")
sys.stdout.flush()
'''


# -- kernel accounting ---------------------------------------------------------

_RUSAGE_FIELDS = [
    "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins",
    "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime",
    "ri_proc_exit_abstime", "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups",
    "ri_child_interrupt_wkups", "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread",
    "ri_diskio_byteswritten", "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance",
    "ri_cpu_time_qos_background", "ri_cpu_time_qos_utility", "ri_cpu_time_qos_legacy",
    "ri_cpu_time_qos_user_initiated", "ri_cpu_time_qos_user_interactive", "ri_billed_system_time",
    "ri_serviced_system_time", "ri_logical_writes", "ri_lifetime_max_phys_footprint", "ri_instructions",
    "ri_cycles", "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint",
    "ri_runnable_time",
]


class _RusageInfoV4(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in _RUSAGE_FIELDS]


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
_libc = ctypes.CDLL(ctypes.util.find_library("c"))
_timebase = _Timebase()
_libc.mach_timebase_info(ctypes.byref(_timebase))


def _ticks_to_seconds(ticks: int) -> float:
    """proc_pid_rusage times are mach absolute ticks on Apple Silicon."""
    return ticks * _timebase.numer / _timebase.denom / 1e9


def rusage(pid: int) -> Dict[str, int]:
    info = _RusageInfoV4()
    if _libproc.proc_pid_rusage(pid, 4, ctypes.byref(info)) != 0:
        raise Failure(f"proc_pid_rusage({pid}) failed: is the app still running?")
    return {name: getattr(info, name) for name in _RUSAGE_FIELDS}


def child_pids(pid: int) -> List[int]:
    buffer = (ctypes.c_int * 4096)()
    count = _libproc.proc_listchildpids(pid, buffer, ctypes.sizeof(buffer))
    return [buffer[i] for i in range(max(0, count))]


def process_name(pid: int) -> str:
    buffer = ctypes.create_string_buffer(256)
    _libproc.proc_name(pid, buffer, ctypes.sizeof(buffer))
    return buffer.value.decode("utf-8", errors="replace") or "?"


class SpawnWatcher:
    """Counts the app's direct child processes that appear while it runs."""

    def __init__(self, pid: int, interval_s: float = 0.01) -> None:
        self.pid = pid
        self.interval_s = interval_s
        self.spawned: Dict[str, int] = {}
        self._known = set(child_pids(pid))
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self._stop.is_set():
            current = set(child_pids(self.pid))
            for child in current - self._known:
                name = process_name(child)
                self.spawned[name] = self.spawned.get(name, 0) + 1
            self._known = current
            time.sleep(self.interval_s)

    def __enter__(self) -> "SpawnWatcher":
        self._thread.start()
        return self

    def __exit__(self, *_: Any) -> None:
        self._stop.set()
        self._thread.join(timeout=2)


class TopSampler:
    """`top`'s POWER (Energy Impact) and idle wakeups for one pid, every 5 s."""

    def __init__(self, pid: int, seconds: float) -> None:
        samples = max(2, int(seconds // 5) + 1)
        self.process = subprocess.Popen(
            ["top", "-l", str(samples), "-s", "5", "-pid", str(pid), "-stats", "pid,cpu,idlew,power"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        self.pid = pid

    def result(self) -> Dict[str, Any]:
        try:
            output, _ = self.process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            self.process.kill()
            output, _ = self.process.communicate()
        rows = []
        for line in output.splitlines():
            parts = line.split()
            if len(parts) == 4 and parts[0] == str(self.pid):
                try:
                    # top marks a growing counter with a trailing "+" (`15+`).
                    rows.append(tuple(float(part.rstrip("+-*")) for part in parts[1:4]))
                except ValueError:
                    continue
        rows = rows[1:]  # top's first sample has no interval behind it
        if not rows:
            return {"samples": 0}
        return {
            "samples": len(rows),
            "cpu_percent_avg": round(sum(r[0] for r in rows) / len(rows), 2),
            "idle_wakeups_avg": round(sum(r[1] for r in rows) / len(rows), 1),
            "power_avg": round(sum(r[2] for r in rows) / len(rows), 2),
            "power_max": round(max(r[2] for r in rows), 2),
        }


def measure(pid: int, seconds: float) -> Dict[str, Any]:
    top = TopSampler(pid, seconds)
    before = rusage(pid)
    started = time.monotonic()
    with SpawnWatcher(pid) as watcher:
        time.sleep(seconds)
    after = rusage(pid)
    elapsed = time.monotonic() - started
    delta = {name: after[name] - before[name] for name in _RUSAGE_FIELDS}
    cpu_s = _ticks_to_seconds(delta["ri_user_time"] + delta["ri_system_time"])
    child_cpu_s = _ticks_to_seconds(delta["ri_child_user_time"] + delta["ri_child_system_time"])
    spawned = dict(sorted(watcher.spawned.items(), key=lambda item: -item[1]))
    return {
        "seconds": round(elapsed, 2),
        "cpu_seconds": round(cpu_s, 3),
        "cpu_percent": round(100 * cpu_s / elapsed, 2),
        "child_cpu_seconds": round(child_cpu_s, 3),
        "pkg_idle_wakeups_per_s": round(delta["ri_pkg_idle_wkups"] / elapsed, 2),
        "interrupt_wakeups_per_s": round(delta["ri_interrupt_wkups"] / elapsed, 1),
        "disk_written_kb": round(delta["ri_diskio_byteswritten"] / 1024, 1),
        "billed_energy_delta": delta["ri_billed_energy"],
        "instructions_g": round(delta["ri_instructions"] / 1e9, 3),
        "spawned_total": sum(spawned.values()),
        "spawned_per_min": round(60 * sum(spawned.values()) / elapsed, 1),
        "spawned": spawned,
        "phys_footprint_mb": round(after["ri_phys_footprint"] / 1048576, 1),
        "threads": thread_count(pid),
        "top": top.result(),
    }


def thread_count(pid: int) -> Optional[int]:
    result = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True)
    lines = [line for line in result.stdout.splitlines()[1:] if line.strip()]
    return len(lines) or None


class ReconnectingSocket(Socket):
    """The app closes a control connection that sat idle (a measured window is
    a minute of silence), so a call on a dropped connection reconnects once."""

    def call(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Any:
        return self._retrying(lambda: Socket.call(self, method, params, timeout_s))

    def v1(self, line: str) -> str:
        return self._retrying(lambda: Socket.v1(self, line))

    def _retrying(self, send: Any) -> Any:
        try:
            return send()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Failure as error:
            if "socket closed by the app" not in str(error):
                raise
        self.close()
        self.connect()
        return send()


# -- the app -------------------------------------------------------------------

class TaggedApp:
    def __init__(self, app_path: Path, tag: str, scratch: Path) -> None:
        self.app_path = app_path
        self.tag = tag
        self.scratch = scratch
        self.socket_path = socket_path_for_tag(tag)
        plist = app_path / "Contents" / "Info.plist"
        self.bundle_id = subprocess.run(
            ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", str(plist)],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        # The checkout the build came from (a tagged build carries no SHA of its own).
        self.git_sha = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "describe", "--always", "--dirty"], capture_output=True, text=True,
        ).stdout.strip() or None
        self.executable_dir = str(app_path / "Contents" / "MacOS") + "/"

    def pid(self) -> Optional[int]:
        result = subprocess.run(["pgrep", "-f", self.executable_dir], capture_output=True, text=True)
        pids = [int(p) for p in result.stdout.split() if p.isdigit()]
        return min(pids) if pids else None

    def require_isolated(self) -> None:
        guard = REPO_ROOT / "tests" / "supermux" / "require_isolated_app.py"
        if subprocess.run([sys.executable, str(guard), "--app", str(self.app_path), "--tag", self.tag]).returncode != 0:
            raise Failure("require_isolated_app.py refused this app")

    def launch(self) -> int:
        if self.pid():
            self.quit()
        subprocess.run([
            "open", "-g",
            "--env", "SUPERMUX_DEBUG_LOOPBACK_DEVICE=1",
            "--env", f"SUPERMUX_PROJECTS_FILE={self.scratch / 'projects.json'}",
            "--env", f"SUPERMUX_PHONE_PUSH_STATE_DIR={self.scratch / 'push-state'}",
            str(self.app_path),
        ], check=True)
        wait_for("the app's socket", lambda: os.path.exists(self.socket_path), 60)
        pid = wait_for("the app's process", self.pid, 30)
        return pid

    def quit(self) -> None:
        subprocess.run(
            ["osascript", "-e", "ignoring application responses", "-e",
             f'tell application id "{self.bundle_id}" to quit', "-e", "end ignoring"],
            capture_output=True,
        )
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline and self.pid():
            time.sleep(0.25)
        if self.pid():
            subprocess.run(["pkill", "-TERM", "-f", self.executable_dir])
            time.sleep(2)
            if self.pid():
                subprocess.run(["pkill", "-KILL", "-f", self.executable_dir])


# -- scratch project -----------------------------------------------------------

def make_scratch_project(scratch: Path, project_id: str) -> Path:
    """A 400-file repo registered as the app's only project (the projects file
    the app is launched with), plus the agent stand-in script."""
    repo = scratch / "repo"
    if repo.exists():
        shutil.rmtree(repo)
    (repo / "src").mkdir(parents=True)
    for index in range(400):
        (repo / "src" / f"file_{index}.ts").write_text(
            "".join(f"export const value{index}_{line} = {line};\n" for line in range(40)))
    (repo / "README.md").write_text("stress repo\n")
    git = ["git", "-C", str(repo)]
    subprocess.run(git + ["init", "-q", "-b", "main"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["-c", "user.name=stress", "-c", "user.email=stress@example.invalid",
                          "commit", "-q", "-m", "initial"], check=True)
    (scratch / "agent.py").write_text(AGENT_SCRIPT)
    (scratch / "push-state").mkdir(exist_ok=True)
    record = {"id": project_id, "name": "stress-repo", "rootPath": str(repo)}
    (scratch / "projects.json").write_text(json.dumps({"projects": [record]}, indent=2))
    return repo


# -- the stress run ------------------------------------------------------------

class StressRun:
    def __init__(self, sock: Socket, pid: int, project_id: str, scratch: Path, args: argparse.Namespace) -> None:
        self.sock = sock
        self.pid = pid
        self.args = args
        self.agent_script = scratch / "agent.py"
        self.project_id = project_id
        self.nonce = uuid.uuid4().hex[:6]
        self.machine: Optional[str] = None
        self.worktrees: List[Dict[str, str]] = []  # {workspace_id, surface_id, path}
        self.scenarios: Dict[str, Any] = {}
        self.facts: Dict[str, Any] = {}

    # socket helpers

    def request(self, method: str, params: Dict[str, Any], timeout_s: float = 120) -> Dict[str, Any]:
        result = self.sock.call(
            "supermux.devices.request",
            {"machine": self.machine, "method": method, "params": params, "timeout_seconds": timeout_s},
            timeout_s=timeout_s + 5,
        ) or {}
        return result.get("result") or {}

    def workspaces(self) -> List[Dict[str, Any]]:
        rows: List[Dict[str, Any]] = []
        for window in (self.sock.call("window.list", {}) or {}).get("windows") or []:
            listed = self.sock.call("workspace.list", {"window_id": window.get("id")}) or {}
            rows.extend(listed.get("workspaces") or [])
        return rows

    def mirrors(self) -> List[Dict[str, Any]]:
        return (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []

    def mirrored_sources(self) -> set:
        return {up(m.get("remote_workspace_id")) for m in self.mirrors() if m.get("machine") == self.machine}

    def first_terminal(self, workspace_id: str) -> str:
        surfaces = (self.sock.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        terminals = [s for s in surfaces if (s.get("type") or s.get("kind") or "terminal") == "terminal"]
        if not terminals:
            raise Failure(f"workspace {workspace_id} has no terminal: {surfaces}")
        return terminals[0].get("id")

    # setup

    def connect_loopback(self) -> None:
        def connected() -> Optional[str]:
            for machine in (self.sock.call("surface.catalog", {}) or {}).get("machines") or []:
                if str(machine.get("id", "")).startswith(LOOPBACK_MACHINE_PREFIX) and machine.get("link_state") == "connected":
                    return machine["id"]
            return None

        self.machine = wait_for("the loopback device to connect", connected, 60)

    def reset_app_state(self) -> None:
        """Back to one plain workspace, auto-mirror and Remote Host Mode off.
        A socket close of a mirror is Hide Here, so the hidden set is cleared
        afterwards (or the kept workspace would never be mirrored)."""
        self.sock.call("supermux.devices.remote_host.set", {"enabled": False})
        self.sock.call("supermux.devices.set_auto_mirror", {"enabled": False})
        time.sleep(1)
        mirrors = {up(m.get("workspace_id")) for m in self.mirrors()}
        rows = self.workspaces()
        keep = next((r for r in rows if up(r.get("id")) not in mirrors), rows[0])
        for row in rows:
            if row["id"] != keep["id"]:
                self.sock.call("workspace.close", {"workspace_id": row["id"], "force": True})
        wait_for("one workspace left", lambda: len(self.workspaces()) == 1, 30)
        self.sock.call("supermux.devices.unhide", {})
        self.sock.call("workspace.select", {"workspace_id": keep["id"]})

    def wait_for_project(self) -> None:
        def listed() -> bool:
            projects = self.request("mobile.supermux.projects.list", {}).get("projects") or []
            return any(up(p.get("id")) == up(self.project_id) for p in projects)

        wait_for("the stress project to be listed", listed, 60, interval_s=1.0)

    def create_worktrees(self, count: int) -> None:
        for index in range(count):
            created = self.request("mobile.supermux.worktree.create", {
                "project_id": self.project_id,
                "branch_name": f"stress-{self.nonce}-{index:02d}",
                "workspace_name": f"stress {index:02d}",
                "open": True,
                "select": False,
            }, timeout_s=120)
            workspace_id = created.get("workspace_id")
            path = (created.get("worktree") or {}).get("path")
            if not workspace_id or not path:
                raise Failure(f"worktree.create returned no workspace/path: {created}")
            self.worktrees.append({"workspace_id": workspace_id, "path": path})
        for worktree in self.worktrees:
            worktree["surface_id"] = wait_for(
                f"a terminal in {worktree['workspace_id']}", lambda w=worktree: self.first_terminal(w["workspace_id"]), 30)

    # load

    def start_agents(self, seconds: float) -> None:
        for worktree in self.worktrees:
            line = f"cd '{worktree['path']}' && '{sys.executable}' '{self.agent_script}' {int(seconds)}\n"
            self.sock.call("surface.send_text", {"workspace_id": worktree["workspace_id"],
                                                 "surface_id": worktree["surface_id"], "text": line})
            self.lifecycle(worktree, "running")

    def stop_agents(self) -> None:
        for worktree in self.worktrees:
            self.lifecycle(worktree, "idle")

    def lifecycle(self, worktree: Dict[str, str], value: str) -> None:
        self.sock.v1(f"set_agent_lifecycle {AGENT_KEY} {value} "
                     f"--tab={worktree['workspace_id']} --panel={worktree['surface_id']}")

    def scenario(self, name: str, busy: bool) -> None:
        seconds = self.args.seconds
        print(f"[stress] {name}: settle {SETTLE_S:.0f}s, measure {seconds:.0f}s", flush=True)
        sample_s = SAMPLE_S if self.args.sample_dir else 0
        if busy:
            self.start_agents(SETTLE_S + seconds + sample_s + 5)
        time.sleep(SETTLE_S)
        result = measure(self.pid, seconds)
        if self.args.sample_dir:
            result["sample_file"] = self.sample(name, sample_s)
        result["busy"] = busy
        result["workspaces"] = len(self.workspaces())
        result["mirrors"] = len(self.mirrors())
        self.scenarios[name] = result
        print(f"[stress] {name}: cpu {result['cpu_percent']}%  interrupt wakeups/s "
              f"{result['interrupt_wakeups_per_s']}  spawned/min {result['spawned_per_min']}  "
              f"power {result['top'].get('power_avg')}", flush=True)
        if busy:
            self.stop_agents()
            time.sleep(6)  # the stand-ins end on their own

    def sample(self, name: str, seconds: float) -> str:
        """A `sample` call-stack profile of the app in this scenario's state,
        taken after the measured window so it never skews the numbers."""
        directory = Path(self.args.sample_dir)
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"{name}.txt"
        subprocess.run(["sample", str(self.pid), str(int(seconds)), "-mayDie", "-file", str(path)],
                       capture_output=True, timeout=seconds + 120)
        return str(path)

    def enable_mirrors(self) -> None:
        self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True})
        wanted = {up(w["workspace_id"]) for w in self.worktrees}
        wait_for(f"a mirror of each of the {len(wanted)} worktree workspaces",
                 lambda: wanted <= self.mirrored_sources(), 180, interval_s=1.0)
        self.facts["mirrors_after_enable"] = len(self.mirrors())

    def run(self) -> None:
        self.connect_loopback()
        self.reset_app_state()
        self.scenario("idle_empty", busy=False)
        self.wait_for_project()
        self.create_worktrees(self.args.worktrees)
        self.scenario("idle_local", busy=False)
        self.scenario("busy_local", busy=True)
        self.enable_mirrors()
        self.scenario("idle_mirrored", busy=False)
        self.scenario("busy_mirrored", busy=True)
        self.sock.call("supermux.devices.remote_host.set", {"enabled": True})
        self.scenario("busy_hidden", busy=True)
        self.scenario("idle_hidden", busy=False)
        try:
            self.facts["terminal_stream_stats"] = self.sock.call("supermux.devices.terminal_stream.stats", {"machine": self.machine})
        except Failure as error:
            self.facts["terminal_stream_stats"] = str(error)

    def cleanup(self) -> None:
        try:
            self.sock.call("supermux.devices.remote_host.set", {"enabled": False})
            self.sock.call("supermux.devices.set_auto_mirror", {"enabled": False})
            time.sleep(1)
            self.reset_app_state()
        except Failure as error:
            print(f"[stress] cleanup: {error}", file=sys.stderr)


# -- compare -------------------------------------------------------------------

COMPARE_METRICS = [
    ("cpu_percent", "CPU %"),
    ("interrupt_wakeups_per_s", "wakeups/s"),
    ("spawned_per_min", "spawns/min"),
    ("child_cpu_seconds", "child CPU s"),
    ("disk_written_kb", "disk KB"),
]


def compare(before_path: Path, after_path: Path) -> str:
    before = json.loads(before_path.read_text())
    after = json.loads(after_path.read_text())
    lines = [f"before: {before.get('label')} ({before.get('git_sha')})  after: {after.get('label')} ({after.get('git_sha')})", ""]
    header = "| scenario | " + " | ".join(f"{title} before → after" for _, title in COMPARE_METRICS) + " | power before → after |"
    lines += [header, "|" + "---|" * (len(COMPARE_METRICS) + 2)]
    for name, b in before.get("scenarios", {}).items():
        a = after.get("scenarios", {}).get(name)
        if not a:
            continue
        cells = []
        for key, _ in COMPARE_METRICS:
            cells.append(f"{b.get(key)} → {a.get(key)}{_pct(b.get(key), a.get(key))}")
        bp, ap = b.get("top", {}).get("power_avg"), a.get("top", {}).get("power_avg")
        lines.append(f"| {name} | " + " | ".join(cells) + f" | {bp} → {ap}{_pct(bp, ap)} |")
    return "\n".join(lines)


def _pct(before: Any, after: Any) -> str:
    if not isinstance(before, (int, float)) or not isinstance(after, (int, float)) or before == 0:
        return ""
    return f" ({100 * (after - before) / before:+.0f}%)"


# -- main ----------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--app-path")
    parser.add_argument("--worktrees", type=int, default=24)
    parser.add_argument("--seconds", type=float, default=60.0)
    parser.add_argument("--label", default="run")
    parser.add_argument("--scratch")
    parser.add_argument("--report")
    parser.add_argument("--keep-running", action="store_true", help="leave the app running afterwards")
    parser.add_argument("--sample-dir", help="also take a `sample` profile of each scenario into this folder")
    parser.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"))
    args = parser.parse_args()

    if args.compare:
        print(compare(Path(args.compare[0]), Path(args.compare[1])))
        return 0
    if not args.tag:
        parser.error("--tag (or CMUX_TAG) is required")
    app_path = Path(args.app_path or Path.home() / "Library/Developer/Xcode/DerivedData" / f"cmux-{args.tag}"
                    / "Build/Products/Debug" / f"cmux DEV {args.tag}.app")
    scratch = Path(args.scratch or f"/tmp/{args.tag}-stress")
    scratch.mkdir(parents=True, exist_ok=True)
    app = TaggedApp(app_path, args.tag, scratch)
    app.require_isolated()

    report: Dict[str, Any] = {
        "suite": "stress_worktrees_energy",
        "label": args.label,
        "tag": args.tag,
        "git_sha": app.git_sha,
        "worktrees": args.worktrees,
        "seconds_per_scenario": args.seconds,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "machine": {"model": platform.machine(), "macos": platform.mac_ver()[0], "cpus": os.cpu_count(),
                    "power": subprocess.run(["pmset", "-g", "ps"], capture_output=True, text=True).stdout.splitlines()[:1]},
        "ok": False,
    }
    run: Optional[StressRun] = None
    exit_code = 1
    try:
        project_id = str(uuid.uuid4()).upper()
        make_scratch_project(scratch, project_id)
        pid = app.launch()
        sock = ReconnectingSocket(app.socket_path, timeout_s=60).connect()
        run = StressRun(sock, pid, project_id, scratch, args)
        report["pid"] = pid
        run.run()
        report["ok"] = True
        exit_code = 0
    except Failure as error:
        report["error"] = str(error)
        print(f"[stress] FAILED: {error}", file=sys.stderr)
    finally:
        if run is not None:
            report["scenarios"] = run.scenarios
            report["facts"] = run.facts
            run.cleanup()
        if not args.keep_running:
            app.quit()
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"stress_worktrees_energy-{args.tag}-{args.label}.json"
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2))
        print(f"[stress] report: {report_path}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
