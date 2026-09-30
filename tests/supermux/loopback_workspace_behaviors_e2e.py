#!/usr/bin/env python3
"""End-to-end check of the fork's device-mirror workspace behaviors (workstream W).

Runs against ONE tagged DEBUG build launched with the loopback device and a
scratch projects file (never the user's real list):

  mkdir -p /tmp/<tag>
  open -g --env SUPERMUX_DEBUG_LOOPBACK_DEVICE=1 \
          --env SUPERMUX_PROJECTS_FILE=/tmp/<tag>/projects.json "<App path>"
  CMUX_TAG=<tag> python3 tests/supermux/loopback_workspace_behaviors_e2e.py

The loopback device is this same app acting as "the other Mac", so the
source side of every check is this app too: a run that starts "on the other
Mac" starts in the SOURCE workspace here (its port listens), and a stage
"on the other Mac" changes the scratch repository's real index.

Checks (each drives the same code path as its UI entry point through the
DEBUG `supermux.devices.mirror.*` socket drivers):

  1. device_connected — the loopback Mac is connected.
  2. scratch_repo — a git repository under /tmp/<tag> with an uncommitted
     change (README.md) and an untracked file (NOTES.txt).
  3. remote_project — the "other Mac" registers the repo as a project with a
     run command (`python3 -m http.server <port>`) and a marker preset.
  4. open_project_mirror — the other Mac opens the project workspace and a
     local mirror opens titled like it (never "Cloud VM").
  5. mirror_target — the mirror resolves to the remote workspace and project.
  6. local_path_actions_off_in_mirror — Show in Finder and Open in Editor are
     disabled and the Files panel is unavailable naming the Mac, while the
     SOURCE (a local workspace) keeps them.
  7. run_start_from_mirror_shortcut — ⌘G in the mirror starts the run on the
     source side (the port listens; run.state names the source workspace;
     the mirror still holds only panes projected from the other Mac).
  8. run_stop_from_mirror_presets_bar — Run/Stop in the mirror stops it (the
     port closes).
  8b. run_second_workspace_from_its_mirror — with the first workspace
     running, a second workspace of the same project on the other Mac runs
     from its own mirror; that mirror keeps showing its run (the older run
     does not hide it), and its Run / Stop stops only that run.
  9. changes_lists_remote_change — the mirror's Changes model is remote and
     lists README.md (modified) and NOTES.txt (untracked).
 10. changes_stage_unstage_round_trip — stage then unstage README.md from the
     mirror's model; the scratch repo's real index follows each step.
 11. changes_file_diff_is_remote — the file-row diff of README.md comes back
     from the other Mac and is marked remote.
 11b. changes_slow_fetch_keeps_link — with a remote whose `git fetch` takes
     longer than the link's 20 s default reply deadline: a count read
     (`changes.history {fetch: false}`) answers without waiting on it, a
     fetching history page and the panel's Fetch both succeed, and the link
     to the other Mac never drops (a second socket watches it throughout).
 12. changes_panel_mounted — with the mirror selected and the right sidebar
     on Changes, the mounted panel's own model is the remote one (a
     screenshot of the window is saved when screen capture is allowed).
 13. preset_matches_remote_preset — a presets-bar chip launches the other
     Mac's matching preset (its marker file appears; the terminal is in the
     source workspace, the mirror gains no local pane).
 14. preset_without_remote_match_types_command — a chip the other Mac lacks
     types its command into a new remote terminal (same checks).
 15. new_workspace_menu_lists_mac — the + menu has "New Workspace on ▸" with
     the loopback Mac enabled.
 16. new_workspace_on_mac_from_menu — clicking it creates a workspace on the
     Mac and opens its mirror (no "Cloud VM" title ever observed).
 17. new_workspace_shortcut_on_mirror — ⌘N with a mirror selected does the
     same.
 18. files_panel_names_mac — the Files panel on the mirror is unavailable and
     says the files are on the loopback Mac (screenshot).
 19. file_diff_viewer_opens_for_remote_diff — clicking a file row's diff
     (the panel's path) opens the diff viewer tab in the mirror from the
     other Mac's patch (screenshot). Last, because the viewer is a local
     pane in the mirror.

Writes tests/supermux/artifacts/loopback_workspace_behaviors_e2e-<tag>.json
and exits non-zero on any failed check. Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

LOOPBACK_DEVICE_ID = "5e1f10b0-0000-4000-8000-000000000001"
REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = REPO_ROOT / "tests" / "supermux" / "artifacts"
PROVISIONAL_TITLE = "Cloud VM"
# Longer than the device link's 20 s default reply deadline, shorter than the
# host's own 30 s `git fetch` timeout.
SLOW_FETCH_SECONDS = 23


class CheckFailure(Exception):
    """A check failed; the message says which and why."""


class SocketClient:
    """Minimal newline-delimited JSON client for the cmux v2 control socket."""

    def __init__(self, path: str, timeout_s: float = 60.0) -> None:
        self.path = path
        self.timeout_s = timeout_s
        self._sock: Optional[socket.socket] = None
        self._buffer = b""
        self._next_id = 1

    def __enter__(self) -> "SocketClient":
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout_s)
        sock.connect(self.path)
        self._sock = sock
        return self

    def __exit__(self, *_: Any) -> None:
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    def call(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Any:
        assert self._sock is not None, "not connected"
        request_id = self._next_id
        self._next_id += 1
        line = json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n"
        self._sock.sendall(line.encode("utf-8"))
        response = json.loads(self._read_line(timeout_s or self.timeout_s))
        if response.get("id") != request_id:
            raise CheckFailure(f"{method}: mismatched response id {response.get('id')} != {request_id}")
        if response.get("ok") is True:
            return response.get("result")
        error = response.get("error") or {}
        raise CheckFailure(f"{method}: {error.get('code', 'error')}: {error.get('message', 'unknown error')}")

    def _read_line(self, timeout_s: float) -> str:
        assert self._sock is not None
        deadline = time.monotonic() + timeout_s
        while b"\n" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CheckFailure("socket response timed out")
            self._sock.settimeout(remaining)
            chunk = self._sock.recv(65536)
            if not chunk:
                raise CheckFailure("socket closed by the app")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        return line.decode("utf-8", errors="replace")


def tag_slug(tag: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", tag.strip().lower())).strip("-")


def wait_for(description: str, probe: Callable[[], Any], timeout_s: float, interval_s: float = 0.4) -> Any:
    """Polls `probe` until it returns a truthy value; raises with the last error."""
    deadline = time.monotonic() + timeout_s
    last_error: Optional[str] = None
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value:
                return value
        except CheckFailure as error:
            last_error = str(error)
        time.sleep(interval_s)
    suffix = f" (last: {last_error})" if last_error else ""
    raise CheckFailure(f"timed out after {timeout_s:.0f}s waiting for {description}{suffix}")


def norm(identifier: Any) -> str:
    return str(identifier or "").strip().upper()


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def port_listening(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.5)
        return probe.connect_ex(("127.0.0.1", port)) == 0


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True)
    return result.stdout


class LinkWatcher:
    """Polls one device's link state on its own socket connection while a slow
    call runs on the main one, and records every poll that was not connected."""

    def __init__(self, socket_path: str, device_id: str, interval_s: float = 0.25) -> None:
        self.socket_path = socket_path
        self.device_id = device_id
        self.interval_s = interval_s
        self.polls = 0
        self.drops: List[str] = []
        self.poll_errors: List[str] = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def __enter__(self) -> "LinkWatcher":
        self._thread.start()
        return self

    def __exit__(self, *_: Any) -> None:
        self._stop.set()
        self._thread.join(timeout=10)

    def _run(self) -> None:
        started = time.monotonic()
        with SocketClient(self.socket_path, timeout_s=10) as client:
            while not self._stop.is_set():
                try:
                    devices = (client.call("supermux.devices.list", {}) or {}).get("devices") or []
                    state = next((d.get("link_state") for d in devices if d.get("device_id") == self.device_id), "missing")
                    self.polls += 1
                    if state != "connected":
                        self.drops.append(f"+{time.monotonic() - started:.1f}s {state}")
                except (CheckFailure, OSError, ValueError) as error:
                    self.poll_errors.append(str(error))
                self._stop.wait(self.interval_s)


class WorkspaceBehaviorsE2E:
    def __init__(self, client: SocketClient, tag: str, timeout_s: float, keep: bool) -> None:
        self.client = client
        self.tag = tag
        self.timeout_s = timeout_s
        self.keep = keep
        self.nonce = uuid.uuid4().hex[:8]
        self.workdir = Path("/tmp") / tag_slug(tag)
        self.repo = self.workdir / f"repo-{self.nonce}"
        self.port = free_port()
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "repo": str(self.repo), "port": self.port}
        self.machine = ""
        self.project_id = ""
        self.preset_id = ""
        self.source_id = ""
        self.mirror_id = ""
        self.created_local: List[str] = []

    # -- socket helpers ------------------------------------------------------

    def rpc(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Any:
        return self.client.call(method, params or {}, timeout_s=timeout_s)

    def remote(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """One RPC to the loopback Mac's host, over the device link."""
        result = self.rpc("supermux.devices.request", {
            "machine": self.machine, "method": method, "params": params or {}, "timeout_seconds": 60,
        }, timeout_s=70)
        return (result or {}).get("result") or {}

    def mirror(self, method: str, params: Dict[str, Any], timeout_s: float = 60) -> Dict[str, Any]:
        return self.rpc(f"supermux.devices.mirror.{method}", params, timeout_s=timeout_s) or {}

    def inspect(self, workspace_id: str) -> Dict[str, Any]:
        return self.mirror("inspect", {"workspace_id": workspace_id})

    def bindings(self) -> Dict[str, Any]:
        return self.rpc("supermux.devices.bindings", {}) or {}

    def cli(self, *args: str) -> str:
        env = dict(os.environ, CMUX_TAG=self.tag)
        result = subprocess.run(
            [str(REPO_ROOT / "scripts" / "cmux-debug-cli.sh"), *args],
            capture_output=True, text=True, env=env, timeout=30,
        )
        if result.returncode != 0:
            raise CheckFailure(f"cmux {' '.join(args)}: {result.stderr.strip() or result.stdout.strip()}")
        return result.stdout

    # -- step runner ---------------------------------------------------------

    def step(self, name: str, action: Callable[[], Dict[str, Any]]) -> None:
        started = time.monotonic()
        record: Dict[str, Any] = {"name": name}
        try:
            record.update(action() or {})
            record["ok"] = True
        except CheckFailure as error:
            record["ok"] = False
            record["error"] = str(error)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            record["ok"] = False
            record["error"] = f"subprocess: {error}"
        record["seconds"] = round(time.monotonic() - started, 2)
        self.steps.append(record)
        if not record["ok"]:
            raise CheckFailure(f"{name}: {record['error']}")

    # -- 1-4: setup ----------------------------------------------------------

    def device_connected(self) -> Dict[str, Any]:
        def probe() -> Optional[Dict[str, Any]]:
            for device in (self.rpc("supermux.devices.list", {}) or {}).get("devices") or []:
                if device.get("device_id") == LOOPBACK_DEVICE_ID:
                    if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                        raise CheckFailure(f"loopback link_state={device.get('link_state')}")
                    return device
            raise CheckFailure("no loopback device (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

        device = wait_for("the loopback Mac to connect", probe, self.timeout_s)
        self.machine = device["machine"]
        self.facts["machine"] = self.machine
        self.facts["device_name"] = device.get("name")
        return {"machine": self.machine, "device_name": device.get("name")}

    def scratch_repo(self) -> Dict[str, Any]:
        self.repo.mkdir(parents=True, exist_ok=False)
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.email", "e2e@supermux.invalid")
        git(self.repo, "config", "user.name", "Supermux E2E")
        (self.repo / "README.md").write_text("# scratch\n\nline one\n", encoding="utf-8")
        git(self.repo, "add", "README.md")
        git(self.repo, "commit", "-q", "-m", "initial")
        (self.repo / "README.md").write_text(f"# scratch\n\nline one\nchanged-{self.nonce}\n", encoding="utf-8")
        (self.repo / "NOTES.txt").write_text("untracked\n", encoding="utf-8")
        return {"status": git(self.repo, "status", "--porcelain").splitlines()}

    def remote_project(self) -> Dict[str, Any]:
        created = self.remote("mobile.supermux.project.create", {"root_path": str(self.repo)})
        project = created.get("project") or {}
        self.project_id = str(project.get("id") or "")
        if not self.project_id:
            raise CheckFailure(f"project.create returned {created}")
        run_command = f"python3 -m http.server {self.port} --bind 127.0.0.1"
        self.remote("mobile.supermux.project.update", {
            "project_id": self.project_id, "patch": {"run_commands": [run_command]},
        })
        marker = self.workdir / f"preset-{self.nonce}"
        preset = self.remote("mobile.supermux.preset.create", {
            "name": f"rws marker {self.nonce}", "command": f"touch {marker}",
        }).get("preset") or {}
        self.preset_id = str(preset.get("id") or "")
        if not self.preset_id:
            raise CheckFailure("preset.create returned no preset")
        self.facts.update(project_id=self.project_id, preset_id=self.preset_id, run_command=run_command)
        return {"project_id": self.project_id, "run_command": run_command, "preset_id": self.preset_id}

    def open_project_mirror(self) -> Dict[str, Any]:
        opened = self.remote("mobile.supermux.project.open", {"project_id": self.project_id})
        self.source_id = norm(opened.get("workspace_id"))
        if not self.source_id:
            raise CheckFailure(f"project.open returned {opened}")
        self.created_local.append(self.source_id)
        mirror = self.rpc("supermux.devices.await_open", {
            "machine": self.machine, "remote_workspace_id": self.source_id, "timeout_seconds": 60, "focus": False,
        }, timeout_s=70) or {}
        self.mirror_id = norm(mirror.get("workspace_id"))
        if not self.mirror_id or self.mirror_id == self.source_id:
            raise CheckFailure(f"await_open returned {mirror}")
        self.created_local.insert(0, self.mirror_id)

        def titled() -> Optional[Dict[str, Any]]:
            rows = {norm(w["workspace_id"]): w for w in self.bindings().get("local_workspaces") or []}
            mirror_row, source_row = rows.get(self.mirror_id), rows.get(self.source_id)
            if not mirror_row or not source_row:
                raise CheckFailure("mirror or source not listed")
            if PROVISIONAL_TITLE in (mirror_row.get("title") or ""):
                raise CheckFailure("mirror shows the provisional Cloud VM title")
            if mirror_row.get("title") != source_row.get("title") or not mirror_row.get("is_device_mirror"):
                raise CheckFailure(f"mirror title {mirror_row.get('title')!r} != source {source_row.get('title')!r}")
            return {"mirror_title": mirror_row["title"], "source_title": source_row["title"]}

        result = wait_for("the mirror to take the source title", titled, self.timeout_s)
        self.facts.update(source_workspace_id=self.source_id, mirror_workspace_id=self.mirror_id)
        return {"source_workspace_id": self.source_id, "mirror_workspace_id": self.mirror_id, **result}

    # -- 5-6: identity and local-path actions --------------------------------

    def mirror_target(self) -> Dict[str, Any]:
        def resolved() -> Optional[Dict[str, Any]]:
            info = self.inspect(self.mirror_id)
            target = info.get("target") or {}
            if not info.get("is_mirror"):
                raise CheckFailure("mirror does not resolve as a device mirror")
            if norm(target.get("remote_workspace_id")) != self.source_id:
                raise CheckFailure(f"remote id {target.get('remote_workspace_id')} != source {self.source_id}")
            if norm(target.get("remote_project_id")) != norm(self.project_id):
                raise CheckFailure(f"remote project {target.get('remote_project_id')} != {self.project_id}")
            return info

        info = wait_for("the mirror's remote project", resolved, self.timeout_s)
        source = self.inspect(self.source_id)
        if source.get("is_mirror"):
            raise CheckFailure("the source workspace resolves as a mirror")
        return {"target": info["target"], "presets_bar_host_label": info.get("presets_bar_host_label")}

    def local_path_actions(self) -> Dict[str, Any]:
        mirror = self.inspect(self.mirror_id)["local_path_actions"]
        source = self.inspect(self.source_id)["local_path_actions"]
        files = mirror.get("file_explorer") or {}
        problems = []
        if mirror.get("show_in_finder_enabled"):
            problems.append(f"mirror Show in Finder enabled ({mirror.get('show_in_finder_path')})")
        if mirror.get("open_in_editor_enabled"):
            problems.append("mirror Open in Editor enabled")
        if files.get("is_available") or files.get("kind") != "remote":
            problems.append(f"mirror Files panel {files}")
        if "Loopback Mac" not in str(files.get("display_target")) or "Loopback Mac" not in str(files.get("detail")):
            problems.append(f"mirror Files panel does not name the Mac: {files}")
        if not source.get("show_in_finder_enabled") or (source.get("file_explorer") or {}).get("kind") != "local":
            problems.append(f"source (local) lost its local-path actions: {source}")
        if problems:
            raise CheckFailure("; ".join(problems))
        return {"mirror": mirror, "source": source}

    # -- 7-8: run --------------------------------------------------------------

    def remote_run(self) -> Dict[str, Any]:
        runs = self.remote("mobile.supermux.run.state").get("runs") or []
        return next((r for r in runs if norm(r.get("project_id")) == norm(self.project_id)), {})

    def run_start(self) -> Dict[str, Any]:
        if port_listening(self.port):
            raise CheckFailure(f"port {self.port} is already in use")
        toggled = self.mirror("run_toggle", {"workspace_id": self.mirror_id, "via": "shortcut"})
        if not toggled.get("consumed"):
            raise CheckFailure(f"⌘G not consumed in the mirror: {toggled}")
        wait_for(f"port {self.port} to listen", lambda: port_listening(self.port), 45)
        run = wait_for("run.state to report the run", lambda: self.remote_run() if self.remote_run().get("is_running") else None, self.timeout_s)
        if norm(run.get("workspace_id")) != self.source_id:
            raise CheckFailure(f"the run started in {run.get('workspace_id')}, not the source {self.source_id}")
        wait_for("the mirror to show the run", lambda: self.inspect(self.mirror_id)["run"]["is_running"], self.timeout_s)
        # The run tab is the source pane's first tab (the ⌘G placement).
        projection = self.assert_terminal_on_source(self.surface_ids(self.source_id)[0])
        return {"run": run, "port_listening": True, **projection}

    def run_stop(self) -> Dict[str, Any]:
        toggled = self.mirror("run_toggle", {"workspace_id": self.mirror_id, "via": "presets_bar"})
        if not toggled.get("consumed"):
            raise CheckFailure(f"Run/Stop not consumed: {toggled}")
        wait_for(f"port {self.port} to close", lambda: not port_listening(self.port), 30)
        wait_for("the mirror to show the run stopped", lambda: not self.inspect(self.mirror_id)["run"]["is_running"], self.timeout_s)
        return {"port_listening": False, "run": self.remote_run()}

    def holds(self, description: str, probe: Callable[[], bool], seconds: float = 2.0) -> None:
        """`probe` stays true for `seconds` (a state a later refresh must not undo)."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not probe():
                raise CheckFailure(f"{description} did not hold")
            time.sleep(0.25)

    def run_second_workspace_from_its_mirror(self) -> Dict[str, Any]:
        """Two workspaces of one project run at once on the other Mac (runs
        are per workspace there). The mirror of the one that started second
        shows its own run, and its Run / Stop stops that run only."""
        self.remote("mobile.supermux.project.update", {
            "project_id": self.project_id, "patch": {"run_commands": ["sleep 3600"]},
        })
        self.mirror("run_toggle", {"workspace_id": self.mirror_id, "via": "presets_bar"})
        wait_for("the first workspace's run over there", lambda: self.inspect(self.source_id)["run"]["is_running"], self.timeout_s)

        created = self.rpc("workspace.create", {"title": f"rws second {self.nonce}", "cwd": str(self.repo), "focus": False}) or {}
        second = norm(created.get("workspace_id"))
        if not second:
            raise CheckFailure(f"workspace.create returned {created}")
        self.created_local.append(second)
        opened = self.rpc("supermux.devices.await_open", {
            "machine": self.machine, "remote_workspace_id": second, "timeout_seconds": 60, "focus": False,
        }, timeout_s=70) or {}
        second_mirror = norm(opened.get("workspace_id"))
        if not second_mirror or second_mirror == second:
            raise CheckFailure(f"await_open returned {opened}")
        self.created_local.insert(0, second_mirror)
        wait_for(
            "the second mirror's remote project",
            lambda: norm((self.inspect(second_mirror).get("target") or {}).get("remote_project_id")) == norm(self.project_id),
            self.timeout_s,
        )

        self.mirror("run_toggle", {"workspace_id": second_mirror, "via": "presets_bar"})
        wait_for("the second workspace's run over there", lambda: self.inspect(second)["run"]["is_running"], self.timeout_s)
        wait_for("the second mirror to show its run", lambda: self.inspect(second_mirror)["run"]["is_running"], self.timeout_s)
        time.sleep(1.5)  # let the follow-up run.state refresh land
        self.holds("the second mirror showing its run", lambda: self.inspect(second_mirror)["run"]["is_running"])
        self.holds("the first mirror showing its run", lambda: self.inspect(self.mirror_id)["run"]["is_running"], 0.5)

        self.mirror("run_toggle", {"workspace_id": second_mirror, "via": "presets_bar"})
        wait_for("the second workspace's run to stop over there", lambda: not self.inspect(second)["run"]["is_running"], self.timeout_s)
        if not self.inspect(self.source_id)["run"]["is_running"]:
            raise CheckFailure("stopping the second workspace's run stopped the first workspace's run")
        wait_for("the second mirror to show its run stopped", lambda: not self.inspect(second_mirror)["run"]["is_running"], self.timeout_s)
        time.sleep(1.5)
        self.holds("the first mirror still showing its run", lambda: self.inspect(self.mirror_id)["run"]["is_running"])

        self.mirror("run_toggle", {"workspace_id": self.mirror_id, "via": "presets_bar"})
        wait_for("the first workspace's run to stop over there", lambda: not self.inspect(self.source_id)["run"]["is_running"], self.timeout_s)
        return {"second_workspace_id": second, "second_mirror_id": second_mirror}

    # -- 9-12: changes ---------------------------------------------------------

    def changes(self, action: str, **params: Any) -> Dict[str, Any]:
        return self.mirror("changes", {"workspace_id": self.mirror_id, "action": action, **params})

    def changes_lists_remote_change(self) -> Dict[str, Any]:
        def listed() -> Optional[Dict[str, Any]]:
            model = self.changes("status")["model"]
            unstaged = {f["path"] for f in model.get("unstaged") or []}
            untracked = {f["path"] for f in model.get("untracked") or []}
            if not model.get("is_remote"):
                raise CheckFailure("the mirror's Changes model is local")
            if "README.md" not in unstaged or "NOTES.txt" not in untracked:
                raise CheckFailure(f"unstaged={sorted(unstaged)} untracked={sorted(untracked)}")
            return model

        model = wait_for("the remote change in the mirror's Changes model", listed, self.timeout_s)
        if model.get("directory") != str(self.repo):
            raise CheckFailure(f"model directory {model.get('directory')} != {self.repo}")
        return {"model": model}

    def changes_stage_round_trip(self) -> Dict[str, Any]:
        staged = self.changes("stage", path="README.md")["model"]
        if "README.md" not in {f["path"] for f in staged.get("staged") or []}:
            raise CheckFailure(f"after stage: {staged}")
        index_after_stage = git(self.repo, "diff", "--cached", "--name-only").split()
        if index_after_stage != ["README.md"]:
            raise CheckFailure(f"repo index after stage: {index_after_stage}")
        unstaged = self.changes("unstage", path="README.md")["model"]
        if "README.md" not in {f["path"] for f in unstaged.get("unstaged") or []} or unstaged.get("staged"):
            raise CheckFailure(f"after unstage: {unstaged}")
        index_after_unstage = git(self.repo, "diff", "--cached", "--name-only").split()
        if index_after_unstage:
            raise CheckFailure(f"repo index after unstage: {index_after_unstage}")
        return {
            "after_stage": staged.get("staged"), "index_after_stage": index_after_stage,
            "after_unstage": unstaged.get("unstaged"), "index_after_unstage": index_after_unstage,
            "last_error": unstaged.get("last_error"),
        }

    def changes_file_diff(self) -> Dict[str, Any]:
        diff = self.changes("diff", path="README.md", staged=False)["diff"]
        if not diff.get("is_remote") or f"+changed-{self.nonce}" not in str(diff.get("patch")):
            raise CheckFailure(f"diff: {diff}")
        return {"diff_title": diff.get("title"), "is_remote": True, "patch_excerpt": str(diff.get("patch"))[:300]}

    def timed_history(self, fetch: Optional[bool]) -> float:
        """One `changes.history` page for the source workspace, sent with NO
        explicit deadline (the device facade's own deadline for the method
        applies), and how long it took."""
        params: Dict[str, Any] = {"workspace_id": self.source_id, "limit": 5}
        if fetch is not None:
            params["fetch"] = fetch
        started = time.monotonic()
        self.rpc("supermux.devices.request", {
            "machine": self.machine, "method": "mobile.supermux.changes.history", "params": params,
        }, timeout_s=90)
        return round(time.monotonic() - started, 1)

    def changes_slow_fetch_keeps_link(self) -> Dict[str, Any]:
        git(self.repo, "remote", "add", "origin", "ssh://supermux-e2e.invalid/scratch.git")
        git(self.repo, "config", "ssh.variant", "simple")
        git(self.repo, "config", "core.sshCommand", f"sleep {SLOW_FETCH_SECONDS} #")
        timings: Dict[str, float] = {}
        fetched: Dict[str, Any] = {}
        try:
            with LinkWatcher(self.client.path, LOOPBACK_DEVICE_ID) as watcher:
                timings["count_read"] = self.timed_history(fetch=False)
                timings["fetching_read"] = self.timed_history(fetch=None)
                started = time.monotonic()
                fetched = self.changes("fetch")["model"]
                timings["panel_fetch"] = round(time.monotonic() - started, 1)
        finally:
            git(self.repo, "remote", "remove", "origin")
            git(self.repo, "config", "--unset", "core.sshCommand")
            git(self.repo, "config", "--unset", "ssh.variant")
        if watcher.drops:
            raise CheckFailure(f"the link to the other Mac dropped during slow fetches: {watcher.drops[:5]} (timings {timings})")
        if watcher.polls == 0:
            raise CheckFailure(f"the link watcher never polled: {watcher.poll_errors[:3]}")
        if timings["count_read"] > 10:
            raise CheckFailure(f"a count read waited {timings['count_read']}s for the other Mac's git fetch")
        if timings["fetching_read"] < 20:
            raise CheckFailure(f"the fetch took only {timings['fetching_read']}s; this check needs one slower than 20 s")
        if fetched.get("last_error"):
            raise CheckFailure(f"the panel's Fetch failed: {fetched.get('last_error')}")
        return {"timings": timings, "link_polls": watcher.polls, "poll_errors": watcher.poll_errors[:3]}

    def changes_panel_mounted(self) -> Dict[str, Any]:
        self.rpc("workspace.select", {"workspace_id": self.mirror_id})
        self.cli("right-sidebar", "set", "changes")

        def mounted() -> Optional[Dict[str, Any]]:
            result = self.changes("status")
            if result.get("source") != "mounted_panel":
                raise CheckFailure(f"panel source is {result.get('source')}")
            return result

        result = wait_for("the Changes panel to mount the mirror's remote model", mounted, self.timeout_s)
        time.sleep(1.5)
        return {"source": result["source"], "screenshot": self.screenshot("changes-panel-mirror")}

    def screenshot(self, name: str) -> Optional[str]:
        """Best effort: captures this tagged app's window (needs Screen Recording)."""
        pid = subprocess.run(["pgrep", "-f", f"cmux DEV {self.tag}.app/Contents/MacOS/"], capture_output=True, text=True).stdout.split()
        if not pid:
            return None
        script = (
            "ObjC.import('CoreGraphics');"
            "var list = ObjC.deepUnwrap(ObjC.castRefToObject("
            "$.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));"
            f"var mine = list.filter(function(w){{return w.kCGWindowOwnerPID == {pid[0]} && w.kCGWindowLayer == 0;}});"
            "mine.sort(function(a, b){return b.kCGWindowBounds.Width * b.kCGWindowBounds.Height"
            " - a.kCGWindowBounds.Width * a.kCGWindowBounds.Height;});"
            "mine.length ? String(mine[0].kCGWindowNumber) : '';"
        )
        window = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True).stdout.strip()
        if not window:
            return None
        ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)
        path = ARTIFACTS_DIR / f"{name}-{tag_slug(self.tag)}.png"
        capture = subprocess.run(["screencapture", "-x", "-o", "-l", window, str(path)], capture_output=True, text=True)
        return str(path) if capture.returncode == 0 and path.exists() and path.stat().st_size > 0 else None

    # -- 13-14: presets --------------------------------------------------------

    def surface_ids(self, workspace_id: str) -> List[str]:
        panes = (self.rpc("pane.list", {"workspace_id": workspace_id}) or {}).get("panes") or []
        return [norm(surface) for pane in panes for surface in pane.get("surface_ids") or []]

    def mirror_projections(self) -> Dict[str, str]:
        """Mirror panel id -> the source terminal id it projects."""
        return {
            norm(p.get("panel_id")): norm(str(p.get("resource", "")).rsplit("/", 1)[-1])
            for p in (self.rpc("surface.catalog", {}) or {}).get("projections") or []
            if norm(p.get("workspace_id")) == self.mirror_id and str(p.get("resource", "")).startswith(self.machine)
        }

    def assert_terminal_on_source(self, terminal_id: Any) -> Dict[str, Any]:
        """The launched terminal lives in the SOURCE workspace (the other Mac),
        the mirror shows it, and the mirror holds only projected panes."""
        if norm(terminal_id) not in self.surface_ids(self.source_id):
            raise CheckFailure(f"terminal {terminal_id} is not in the source workspace")

        def projected() -> bool:
            projections = self.mirror_projections()
            local = [s for s in self.surface_ids(self.mirror_id) if s not in projections]
            if local:
                raise CheckFailure(f"the mirror has non-projected (local) panes: {local}")
            if norm(terminal_id) not in projections.values():
                raise CheckFailure(f"the mirror does not show terminal {terminal_id} yet")
            return True

        wait_for("the mirror to show the new terminal, projected", projected, self.timeout_s)
        return {"mirror_panes": len(self.surface_ids(self.mirror_id))}

    def preset_matches_remote(self) -> Dict[str, Any]:
        marker = self.workdir / f"preset-{self.nonce}"
        result = self.mirror("preset_launch", {
            "workspace_id": self.mirror_id, "name": f"rws marker {self.nonce}", "command": f"touch {marker}",
        })
        if result.get("outcome") != "remote_preset" or norm(result.get("preset_id")) != norm(self.preset_id):
            raise CheckFailure(f"preset launch: {result}")
        wait_for(f"{marker} to appear", marker.exists, 30)
        projection = self.assert_terminal_on_source(result.get("terminal_id"))
        return {"launch": result, "marker": str(marker), **projection}

    def preset_types_command(self) -> Dict[str, Any]:
        marker = self.workdir / f"typed-{self.nonce}"
        result = self.mirror("preset_launch", {
            "workspace_id": self.mirror_id, "name": f"not on that mac {self.nonce}", "command": f"touch {marker}",
        })
        if result.get("outcome") != "typed_command":
            raise CheckFailure(f"preset launch: {result}")
        wait_for(f"{marker} to appear", marker.exists, 30)
        projection = self.assert_terminal_on_source(result.get("terminal_id"))
        return {"launch": result, "marker": str(marker), **projection}

    # -- 15-17: New Workspace on ▸ <Mac> ---------------------------------------

    def new_workspace_menu(self) -> Dict[str, Any]:
        rows = self.mirror("new_workspace_menu", {}).get("rows") or []
        row = next((r for r in rows if r.get("machine") == self.machine), None)
        if not row or not row.get("is_enabled") or row.get("badge"):
            raise CheckFailure(f"menu rows: {rows}")
        return {"rows": rows}

    def check_created_mirror(self, created: Dict[str, Any]) -> Dict[str, Any]:
        if created.get("timed_out") or not created.get("workspace_id"):
            raise CheckFailure(f"no mirror appeared: {created}")
        mirror_id = norm(created["workspace_id"])
        remote_id = norm(created.get("remote_workspace_id"))
        self.created_local[:0] = [mirror_id]
        if remote_id:
            self.created_local.append(remote_id)
        observed = created.get("observed_titles") or []
        if any(PROVISIONAL_TITLE in title for title in observed):
            raise CheckFailure(f"provisional title observed: {observed}")

        def titled() -> Optional[Dict[str, Any]]:
            mirrors = {norm(m["workspace_id"]): m for m in self.bindings().get("mirrors") or []}
            row = mirrors.get(mirror_id)
            if not row or row.get("title") != row.get("remote_title"):
                raise CheckFailure(f"mirror row {row}")
            return row

        row = wait_for("the new mirror to carry the remote title", titled, self.timeout_s)
        return {"mirror_workspace_id": mirror_id, "remote_workspace_id": remote_id,
                "title": row.get("title"), "observed_titles": observed}

    def new_workspace_from_menu(self) -> Dict[str, Any]:
        created = self.mirror("new_workspace_menu_invoke", {"machine": self.machine, "timeout_seconds": 40}, timeout_s=50)
        return self.check_created_mirror(created)

    def new_workspace_shortcut(self) -> Dict[str, Any]:
        self.rpc("workspace.select", {"workspace_id": self.mirror_id})
        created = self.mirror("new_workspace_shortcut", {"timeout_seconds": 40}, timeout_s=50)
        return self.check_created_mirror(created)

    # -- 18-19: viewers (last: they add a local pane to the mirror) ------------

    def file_diff_viewer_opens(self) -> Dict[str, Any]:
        before = set(self.surface_ids(self.mirror_id))
        diff = self.changes("diff", path="README.md", staged=False, open_viewer=True)["diff"]
        if not diff.get("viewer_opened"):
            raise CheckFailure(f"the diff viewer did not open: {diff}")

        def viewer() -> Optional[Dict[str, Any]]:
            surfaces = (self.rpc("surface.list", {"workspace_id": self.mirror_id}) or {}).get("surfaces") or []
            added = [s for s in surfaces if norm(s.get("id")) not in before and s.get("type") == "browser"]
            if not added:
                raise CheckFailure("no diff viewer tab in the mirror yet")
            return added[0]

        tab = wait_for("the diff viewer tab in the mirror", viewer, self.timeout_s)
        time.sleep(1.5)
        return {"viewer_title": tab.get("title"), "screenshot": self.screenshot("remote-file-diff-viewer")}

    def files_panel_names_mac(self) -> Dict[str, Any]:
        self.rpc("workspace.select", {"workspace_id": self.mirror_id})
        self.cli("right-sidebar", "set", "files")
        time.sleep(1.5)
        files = self.inspect(self.mirror_id)["local_path_actions"]["file_explorer"]
        if files.get("is_available") or "Loopback Mac" not in str(files.get("detail")):
            raise CheckFailure(f"Files panel: {files}")
        shot = self.screenshot("files-panel-mirror")
        self.cli("right-sidebar", "set", "changes")
        return {"file_explorer": files, "screenshot": shot}

    # -- run -------------------------------------------------------------------

    def cleanup(self) -> None:
        if self.keep:
            return
        if port_listening(self.port):
            try:
                self.mirror("run_toggle", {"workspace_id": self.mirror_id, "via": "presets_bar"})
            except CheckFailure:
                pass
        for workspace_id in self.created_local:
            try:
                self.rpc("workspace.close", {"workspace_id": workspace_id})
            except CheckFailure as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))
        for method, params in (
            ("mobile.supermux.preset.delete", {"preset_id": self.preset_id}),
            ("mobile.supermux.project.delete", {"project_id": self.project_id}),
        ):
            if next(iter(params.values())):
                try:
                    self.remote(method, params)
                except CheckFailure as error:
                    self.facts.setdefault("cleanup_errors", []).append(str(error))
        shutil.rmtree(self.repo, ignore_errors=True)
        for marker in (self.workdir / f"preset-{self.nonce}", self.workdir / f"typed-{self.nonce}"):
            marker.unlink(missing_ok=True)

    def run(self) -> bool:
        try:
            self.step("device_connected", self.device_connected)
            self.step("scratch_repo", self.scratch_repo)
            self.step("remote_project", self.remote_project)
            self.step("open_project_mirror", self.open_project_mirror)
            self.step("mirror_target", self.mirror_target)
            self.step("local_path_actions_off_in_mirror", self.local_path_actions)
            self.step("run_start_from_mirror_shortcut", self.run_start)
            self.step("run_stop_from_mirror_presets_bar", self.run_stop)
            self.step("run_second_workspace_from_its_mirror", self.run_second_workspace_from_its_mirror)
            self.step("changes_lists_remote_change", self.changes_lists_remote_change)
            self.step("changes_stage_unstage_round_trip", self.changes_stage_round_trip)
            self.step("changes_file_diff_is_remote", self.changes_file_diff)
            self.step("changes_slow_fetch_keeps_link", self.changes_slow_fetch_keeps_link)
            self.step("changes_panel_mounted", self.changes_panel_mounted)
            self.step("preset_matches_remote_preset", self.preset_matches_remote)
            self.step("preset_without_remote_match_types_command", self.preset_types_command)
            self.step("new_workspace_menu_lists_mac", self.new_workspace_menu)
            self.step("new_workspace_on_mac_from_menu", self.new_workspace_from_menu)
            self.step("new_workspace_shortcut_on_mirror", self.new_workspace_shortcut)
            self.step("files_panel_names_mac", self.files_panel_names_mac)
            self.step("file_diff_viewer_opens_for_remote_diff", self.file_diff_viewer_opens)
            return True
        except CheckFailure:
            return False
        except (OSError, ValueError) as error:
            self.steps.append({"name": "transport", "ok": False, "error": str(error)})
            return False
        finally:
            self.cleanup()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"), help="tagged build (default: $CMUX_TAG)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for each check")
    parser.add_argument("--keep", action="store_true", help="leave the workspaces, project and repo in place")
    parser.add_argument("--report", help="report path (default: tests/supermux/artifacts/loopback_workspace_behaviors_e2e-<tag>.json)")
    args = parser.parse_args()
    if not args.tag:
        parser.error("set CMUX_TAG (or pass --tag)")
    socket_path = f"/tmp/cmux-debug-{tag_slug(args.tag)}.sock"

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with SocketClient(socket_path) as client:
            e2e = WorkspaceBehaviorsE2E(client, tag=args.tag, timeout_s=args.timeout, keep=args.keep)
            passed = e2e.run()
            steps, facts = e2e.steps, e2e.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-workspace-behaviors-e2e",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_workspace_behaviors_e2e-{args.tag}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
