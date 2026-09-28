#!/usr/bin/env python3
"""End-to-end smoke test for the Supermux DEBUG loopback device harness.

Talks to a tagged DEBUG build launched with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1
(see plans/supermux-remote-workspaces/LOOPBACK-HARNESS.md) over its control
socket and checks the whole remote-workspace pipeline inside one app:

  1. The "Loopback Mac" device machine is in the surface catalog, connected.
  2. Its remote workspaces equal this app's own workspaces (id and title).
  3. A fresh source workspace created here shows up on the device (live sync).
  4. Opening that remote workspace (vm.workspace_open) creates a local mirror
     that takes the remote workspace's title.
  5. The device's workspaces still equal this app's once the mirror exists.
     The report says whether the host re-exports the mirror (the loop hazard
     the host export filter removes); both shapes pass.
  6. Output: text typed into the SOURCE terminal runs there and its output
     appears in the MIRROR (mobile.terminal.replay + terminal.bytes).
  7. Input: text typed into the MIRROR runs in the SOURCE (mobile.terminal.input).
  8. Notifications: a notification on the SOURCE terminal lands on the MIRROR
     terminal (notification.feed.list) and is not relayed back again.
  9. Layout, host -> viewer: a split in the SOURCE appears in the MIRROR.
 10. Layout, viewer -> host: a split in the MIRROR creates a real SOURCE
     terminal (device.workspace.terminal.create) that is projected back.

Prints a JSON report, writes it to tests/supermux/artifacts/, and exits
non-zero on any failed check. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_device_smoke.py [--keep] [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

LOOPBACK_DEVICE_ID = "5e1f10b0-0000-4000-8000-000000000001"
LOOPBACK_MACHINE_PREFIX = f"device:{LOOPBACK_DEVICE_ID}@"
REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = REPO_ROOT / "tests" / "supermux" / "artifacts"


class SmokeFailure(Exception):
    """A check failed; the message says which and why."""


class SocketClient:
    """Minimal newline-delimited JSON client for the cmux v2 control socket."""

    def __init__(self, path: str, timeout_s: float = 30.0) -> None:
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
            raise SmokeFailure(f"{method}: mismatched response id {response.get('id')} != {request_id}")
        if response.get("ok") is True:
            return response.get("result")
        error = response.get("error") or {}
        raise SmokeFailure(f"{method}: {error.get('code', 'error')}: {error.get('message', 'unknown error')}")

    def _read_line(self, timeout_s: float) -> str:
        assert self._sock is not None
        deadline = time.monotonic() + timeout_s
        while b"\n" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SmokeFailure("socket response timed out")
            self._sock.settimeout(remaining)
            chunk = self._sock.recv(65536)
            if not chunk:
                raise SmokeFailure("socket closed by the app")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        return line.decode("utf-8", errors="replace")


def socket_path_for_tag(tag: str) -> str:
    slug = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", tag.strip().lower())).strip("-")
    return f"/tmp/cmux-debug-{slug}.sock"


def wait_for(description: str, probe: Callable[[], Any], timeout_s: float, interval_s: float = 0.5) -> Any:
    """Polls `probe` until it returns a truthy value; raises with the last error."""
    deadline = time.monotonic() + timeout_s
    last_error: Optional[str] = None
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value:
                return value
        except SmokeFailure as error:
            last_error = str(error)
        time.sleep(interval_s)
    suffix = f" (last error: {last_error})" if last_error else ""
    raise SmokeFailure(f"timed out after {timeout_s:.0f}s waiting for {description}{suffix}")


def norm(identifier: Any) -> str:
    return str(identifier or "").strip().lower()


class LoopbackSmoke:
    def __init__(self, client: SocketClient, timeout_s: float, keep: bool) -> None:
        self.client = client
        self.timeout_s = timeout_s
        self.keep = keep
        self.nonce = uuid.uuid4().hex[:8]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.source_workspace_id: Optional[str] = None
        self.mirror_workspace_id: Optional[str] = None

    # -- socket reads -------------------------------------------------------

    def catalog(self) -> Dict[str, Any]:
        return self.client.call("surface.catalog", {}) or {}

    def loopback_machine(self, catalog: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        for machine in catalog.get("machines") or []:
            if str(machine.get("id", "")).startswith(LOOPBACK_MACHINE_PREFIX):
                return machine
        return None

    def local_workspaces(self) -> List[Dict[str, Any]]:
        windows = (self.client.call("window.list", {}) or {}).get("windows") or []
        rows: List[Dict[str, Any]] = []
        for window in windows:
            result = self.client.call("workspace.list", {"window_id": window.get("id")}) or {}
            rows.extend(result.get("workspaces") or [])
        return rows

    def read_text(self, workspace_id: str, surface_id: str) -> str:
        result = self.client.call(
            "surface.read_text",
            {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True},
        ) or {}
        return str(result.get("text") or "")

    def send_text(self, workspace_id: str, surface_id: str, text: str) -> None:
        self.client.call("surface.send_text", {"workspace_id": workspace_id, "surface_id": surface_id, "text": text})

    # -- steps --------------------------------------------------------------

    def step(self, name: str, action: Callable[[], Dict[str, Any]]) -> Dict[str, Any]:
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
        return record

    def check_device_connected(self) -> Dict[str, Any]:
        def probe() -> Optional[Dict[str, Any]]:
            machine = self.loopback_machine(self.catalog())
            if machine is None:
                raise SmokeFailure("no loopback device machine in surface.catalog (is SUPERMUX_DEBUG_LOOPBACK_DEVICE=1 set?)")
            if machine.get("link_state") != "connected":
                raise SmokeFailure(f"link_state={machine.get('link_state')} link_error={machine.get('link_error')}")
            if machine.get("remote_workspaces") is None:
                raise SmokeFailure("connected but no synced workspaces yet")
            return machine

        machine = wait_for("the loopback device to connect", probe, self.timeout_s)
        self.facts["machine"] = machine["id"]
        return {"machine": machine["id"], "machine_name": machine.get("name"), "link_state": machine.get("link_state")}

    def check_workspaces_match(self) -> Dict[str, Any]:
        """The device's workspaces are this app's workspaces. A mirror of the
        loopback may be absent remotely once the host stops re-exporting
        mirrors (F1's export filter); both shapes pass and are reported."""

        def compare() -> Optional[Dict[str, Any]]:
            catalog = self.catalog()
            machine = self.loopback_machine(catalog) or {}
            remote = {norm(w["id"]): w.get("name") for w in machine.get("remote_workspaces") or []}
            local = {norm(w["id"]): w.get("title") for w in self.local_workspaces()}
            mirrors = self.loopback_mirror_workspace_ids(catalog)
            exported_mirrors = set(remote) & mirrors
            expected = local if exported_mirrors or not mirrors else {k: v for k, v in local.items() if k not in mirrors}
            if set(remote) != set(expected):
                raise SmokeFailure(
                    f"remote ids {sorted(remote)} != local ids {sorted(expected)}"
                    f" (mirrors of the loopback: {sorted(mirrors)})"
                )
            titles = {k: (remote[k], expected[k]) for k in expected if (remote[k] or "") != (expected[k] or "")}
            if titles:
                raise SmokeFailure(f"title mismatches (remote, local): {titles}")
            return {
                "workspace_count": len(expected),
                "workspaces": [{"id": k, "title": expected[k]} for k in sorted(expected)],
                "loopback_mirrors_reexported": bool(exported_mirrors),
            }

        return wait_for("remote workspaces to equal local workspaces", compare, self.timeout_s)

    def loopback_mirror_workspace_ids(self, catalog: Dict[str, Any]) -> set:
        return {
            norm(p.get("workspace_id"))
            for p in catalog.get("projections") or []
            if str(p.get("resource", "")).startswith(LOOPBACK_MACHINE_PREFIX)
        }

    def create_source_workspace(self) -> Dict[str, Any]:
        result = self.client.call("workspace.create", {"title": f"loopback-smoke-{self.nonce}", "focus": False}) or {}
        workspace_id = result.get("workspace_id")
        if not workspace_id:
            raise SmokeFailure(f"workspace.create returned no workspace_id: {result}")
        self.source_workspace_id = str(workspace_id)
        title = f"loopback-smoke-{self.nonce}"
        self.client.call("workspace.rename", {"workspace_id": self.source_workspace_id, "title": title})

        def remote_terminal() -> Optional[Dict[str, Any]]:
            for resource in self.catalog().get("resources") or []:
                if not str(resource.get("machine", "")).startswith(LOOPBACK_MACHINE_PREFIX):
                    continue
                workspace = resource.get("remote_workspace") or {}
                if resource.get("kind") == "terminal" and norm(workspace.get("id")) == norm(self.source_workspace_id):
                    return resource
            return None

        resource = wait_for("the new source workspace's terminal on the device", remote_terminal, self.timeout_s)
        self.facts["source_workspace_id"] = self.source_workspace_id
        self.facts["source_surface_id"] = resource["key"]
        self.facts["remote_workspace_id"] = resource["remote_workspace"]["id"]
        return {
            "source_workspace_id": self.source_workspace_id,
            "source_surface_id": resource["key"],
            "remote_workspace_name": resource["remote_workspace"].get("name"),
        }

    def open_mirror(self) -> Dict[str, Any]:
        result = self.client.call(
            "vm.workspace_open",
            {"id": self.facts["machine"], "workspace_id": self.facts["remote_workspace_id"], "focus": False},
            timeout_s=120,
        ) or {}
        mirror_id = result.get("workspace_id")
        surfaces = result.get("surface_ids") or []
        if not mirror_id or not surfaces:
            raise SmokeFailure(f"vm.workspace_open did not open a mirror: {result}")
        if norm(mirror_id) == norm(self.source_workspace_id):
            raise SmokeFailure("the mirror is the source workspace itself")
        self.mirror_workspace_id = str(mirror_id)
        self.facts["mirror_workspace_id"] = self.mirror_workspace_id
        self.facts["mirror_surface_id"] = surfaces[0]

        def projected() -> bool:
            return norm(mirror_id) in self.loopback_mirror_workspace_ids(self.catalog())

        wait_for("the mirror's catalog projection", projected, self.timeout_s)

        def titles_match() -> Optional[str]:
            titles = {norm(w["id"]): w.get("title") for w in self.local_workspaces()}
            source_title = titles.get(norm(self.source_workspace_id))
            mirror_title = titles.get(norm(mirror_id))
            if not source_title or mirror_title != source_title:
                raise SmokeFailure(f"mirror title {mirror_title!r} != source title {source_title!r}")
            return mirror_title

        title = wait_for("the mirror to take the remote workspace's title", titles_match, self.timeout_s)
        return {
            "mirror_workspace_id": self.mirror_workspace_id,
            "mirror_surface_ids": surfaces,
            "opened": result.get("opened"),
            "mirror_title": title,
        }

    def mirror_projections(self) -> List[Dict[str, Any]]:
        return [
            p for p in self.catalog().get("projections") or []
            if norm(p.get("workspace_id")) == norm(self.mirror_workspace_id)
        ]

    def mirror_projection_for(self, remote_surface_id: str) -> Optional[Dict[str, Any]]:
        suffix = "/terminal/" + norm(remote_surface_id)
        return next((p for p in self.mirror_projections() if norm(p.get("resource")).endswith(suffix)), None)

    def source_terminal_ids(self) -> List[str]:
        result = self.client.call("surface.list", {"workspace_id": self.source_workspace_id}) or {}
        return [s["id"] for s in result.get("surfaces") or [] if s.get("type") == "terminal"]

    def check_notification_reaches_mirror(self) -> Dict[str, Any]:
        """Notification feed sync: a notification on the source terminal is
        delivered onto the mirror (notification.feed.list over the link), and
        the host never re-exports that mirrored copy (no relay loop)."""
        title = f"loopback-notify-{self.nonce}"
        self.client.call(
            "notification.create_for_surface",
            {"workspace_id": self.source_workspace_id, "surface_id": self.facts["source_surface_id"], "title": title, "body": "loopback smoke"},
        )

        def copies() -> List[Dict[str, Any]]:
            rows = (self.client.call("notification.list", {}) or {}).get("notifications") or []
            return [n for n in rows if n.get("title") == title]

        def mirrored() -> Optional[Dict[str, Any]]:
            return next((n for n in copies() if norm(n.get("workspace_id")) == norm(self.mirror_workspace_id)), None)

        copy = wait_for("the source notification on the mirror", mirrored, self.timeout_s)
        if norm(copy.get("surface_id")) != norm(self.facts["mirror_surface_id"]):
            raise SmokeFailure(f"mirrored notification landed on surface {copy.get('surface_id')}, not the mirror terminal")
        # Negative check: give a relay loop time to show up, then count copies.
        time.sleep(2.0)
        count = len(copies())
        if count != 2:
            raise SmokeFailure(f"expected the source notification plus one mirrored copy, found {count}")
        return {"mirror_notification_subtitle": copy.get("subtitle"), "copies": count}

    def check_source_split_reaches_mirror(self) -> Dict[str, Any]:
        """Host -> viewer layout sync: a split on the source Mac appears in
        the mirror (device.workspace.layout.changed + reconcile)."""
        result = self.client.call(
            "surface.split",
            {"workspace_id": self.source_workspace_id, "surface_id": self.facts["source_surface_id"], "direction": "right"},
        ) or {}
        new_surface = result.get("surface_id")
        if not new_surface:
            raise SmokeFailure(f"surface.split on the source returned no surface_id: {result}")
        projection = wait_for("the mirror to project the new source terminal", lambda: self.mirror_projection_for(new_surface), self.timeout_s)
        return {"source_surface_id": new_surface, "mirror_surface_id": projection.get("surface_id")}

    def check_mirror_split_creates_source_terminal(self) -> Dict[str, Any]:
        """Viewer -> host: a split in the mirror creates a real terminal on the
        source Mac (device.workspace.terminal.create) and projects it back."""
        before = set(map(norm, self.source_terminal_ids()))
        self.client.call(
            "surface.split",
            {"workspace_id": self.mirror_workspace_id, "surface_id": self.facts["mirror_surface_id"], "direction": "down"},
        )

        def created() -> Optional[str]:
            fresh = [s for s in self.source_terminal_ids() if norm(s) not in before]
            if not fresh:
                return None
            if self.mirror_projection_for(fresh[0]) is None:
                raise SmokeFailure(f"source terminal {fresh[0]} exists but is not projected into the mirror")
            return fresh[0]

        new_source = wait_for("the mirror split to create a source terminal", created, self.timeout_s)
        return {"source_surface_id": new_source, "mirror_projection_count": len(self.mirror_projections())}

    def check_output_mirrors(self) -> Dict[str, Any]:
        # The shell evaluates $((6*7)), so only real output (not the echoed
        # command line) contains the expected marker.
        marker = f"LOOPBACK_OUT_42_{self.nonce}"
        self.send_text(self.source_workspace_id, self.facts["source_surface_id"], f"echo LOOPBACK_OUT_$((6*7))_{self.nonce}\n")
        wait_for("source output in the SOURCE terminal", lambda: marker in self.read_text(self.source_workspace_id, self.facts["source_surface_id"]), self.timeout_s)
        wait_for("source output in the MIRROR terminal", lambda: marker in self.read_text(self.mirror_workspace_id, self.facts["mirror_surface_id"]), self.timeout_s)
        return {"marker": marker}

    def check_input_reaches_source(self) -> Dict[str, Any]:
        marker = f"LOOPBACK_IN_25_{self.nonce}"
        self.send_text(self.mirror_workspace_id, self.facts["mirror_surface_id"], f"echo LOOPBACK_IN_$((5*5))_{self.nonce}\n")
        wait_for("mirror input executed in the SOURCE terminal", lambda: marker in self.read_text(self.source_workspace_id, self.facts["source_surface_id"]), self.timeout_s)
        wait_for("its output back in the MIRROR terminal", lambda: marker in self.read_text(self.mirror_workspace_id, self.facts["mirror_surface_id"]), self.timeout_s)
        return {"marker": marker}

    def cleanup(self) -> None:
        if self.keep:
            return
        for workspace_id in (self.mirror_workspace_id, self.source_workspace_id):
            if not workspace_id:
                continue
            try:
                self.client.call("workspace.close", {"workspace_id": workspace_id})
            except SmokeFailure as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        try:
            self.step("device_connected", self.check_device_connected)
            self.step("remote_workspaces_equal_local", self.check_workspaces_match)
            self.step("new_workspace_syncs_to_device", self.create_source_workspace)
            self.step("open_remote_workspace_creates_mirror", self.open_mirror)
            self.step("remote_workspaces_equal_local_with_mirror", self.check_workspaces_match)
            self.step("source_output_appears_in_mirror", self.check_output_mirrors)
            self.step("mirror_input_reaches_source", self.check_input_reaches_source)
            self.step("source_notification_reaches_mirror", self.check_notification_reaches_mirror)
            self.step("source_split_reaches_mirror", self.check_source_split_reaches_mirror)
            self.step("mirror_split_creates_source_terminal", self.check_mirror_split_creates_source_terminal)
            return True
        except SmokeFailure:
            return False
        except (OSError, ValueError) as error:
            self.steps.append({"name": "transport", "ok": False, "error": str(error)})
            return False
        finally:
            self.cleanup()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"), help="tagged build (default: $CMUX_TAG)")
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"), help="override the control socket path")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for each check")
    parser.add_argument("--keep", action="store_true", help="leave the source and mirror workspaces open")
    parser.add_argument("--report", help="report path (default: tests/supermux/artifacts/loopback_device_smoke-<tag>.json)")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    socket_path = args.socket or socket_path_for_tag(args.tag)

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with SocketClient(socket_path) as client:
            smoke = LoopbackSmoke(client, timeout_s=args.timeout, keep=args.keep)
            passed = smoke.run()
            steps, facts = smoke.steps, smoke.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-device-smoke",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_device_smoke-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
