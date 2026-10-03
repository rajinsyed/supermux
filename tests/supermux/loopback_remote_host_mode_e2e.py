#!/usr/bin/env python3
"""End-to-end test of Remote Host Mode: a Mac used only as a remote host runs
with no window and no Dock icon, and everything still works from another
device. Runs against one tagged DEBUG build with the loopback device
(SUPERMUX_DEBUG_LOOPBACK_DEVICE=1), so "another device" is the in-process
Loopback Mac talking to this app's own mobile host.

The mode's socket twins (`supermux.devices.remote_host.*`, DEBUG builds only)
read the same state the menu bar item shows and call the same actions as the
setting, the menu bar item and a window's close, so these checks drive the
user's write paths:

  1. setup                              the loopback linked; the mode off, a main window on screen
  2. mode_on_hides_every_window         the setting on: every main window hidden (none closed),
                                        accessory activation policy (no Dock icon), the menu bar
                                        item installed with Show Supermux and Turn Off Remote Host Mode
  3. device_workspace_works_headless    New Workspace on <Mac> (the device path) creates a workspace
                                        here, a device-created terminal runs a command typed from the
                                        device and its output is readable; no window showed, the app
                                        did not activate
  4. close_button_hides_window          Show Supermux, then the window's close button: the window
                                        hides, stays registered, keeps its workspaces
  5. close_window_command_hides_window  Show Supermux, then Close Window (Shift-Cmd-W): the same,
                                        with no "Close window?" dialog
  6. global_hotkey_shows_windows        while headless, the global show/hide hotkey shows the main
                                        windows (as Show Supermux does) and the mode stays on
                                        (red before: only the menu bar item and reopening showed them)
  7. notification_click_shows_windows   while headless, a click on a terminal notification's banner
                                        shows the windows with its workspace selected; the mode stays on
  8. relaunch_stays_headless            quit and relaunch with the mode on: the session is restored
                                        (the device workspace is back), no window shows, the app does
                                        not activate, a device-created terminal works
  9. mode_off_shows_windows             the setting off: main windows show again, regular policy

Writes a JSON report (default tests/supermux/artifacts/loopback_remote_host_mode_e2e-<tag>.json)
and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_remote_host_mode_e2e.py --app-path <app> [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_tab_sync_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    LOOPBACK_DEVICE_ID,
    Failure,
    Socket,
    socket_path_for_tag,
    up,
    wait_for,
)

STATE = "supermux.devices.remote_host.state"
SET = "supermux.devices.remote_host.set"
MENU = "supermux.devices.remote_host.menu"
CLOSE = "supermux.devices.remote_host.close_window"
HOTKEY = "supermux.devices.remote_host.global_hotkey"
NOTIFICATION_CLICK = "supermux.devices.remote_host.notification_click"


def hold(description: str, probe: Callable[[], Any], seconds: float, interval_s: float = 0.4) -> None:
    """Asserts `probe` stays truthy for `seconds` (negative checks)."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not probe():
            raise Failure(f"{description} stopped holding")
        time.sleep(interval_s)


class RemoteHostModeE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.machine = ""
        self.device_workspace = ""
        self.device_title = f"remote-host-{self.nonce}"

    # -- reads and actions ----------------------------------------------------

    def state(self) -> Dict[str, Any]:
        return self.sock.call(STATE, {}) or {}

    def visible_windows(self, state: Optional[Dict[str, Any]] = None) -> List[Dict[str, Any]]:
        return [w for w in (state or self.state()).get("main_windows") or [] if w.get("visible")]

    def window_workspaces(self, window_id: str) -> List[str]:
        result = self.sock.call("workspace.list", {"window_id": window_id}) or {}
        return sorted(up(w.get("id")) for w in result.get("workspaces") or [])

    def all_workspaces(self) -> Dict[str, str]:
        rows: Dict[str, str] = {}
        for window in (self.sock.call("window.list", {}) or {}).get("windows") or []:
            for w in (self.sock.call("workspace.list", {"window_id": window.get("id")}) or {}).get("workspaces") or []:
                rows[up(w.get("id"))] = w.get("title") or ""
        return rows

    def loopback_machine(self) -> str:
        def ready() -> Optional[str]:
            for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
                if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                    if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                        raise Failure(f"link_state={device.get('link_state')}")
                    return device.get("machine")
            raise Failure("no loopback device (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

        return wait_for("the loopback device to connect", ready, self.timeout)

    def device_request(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        reply = self.sock.call(
            "supermux.devices.request",
            {"machine": self.machine, "method": method, "params": params, "timeout_seconds": 30},
            timeout_s=40,
        ) or {}
        return reply.get("result") or {}

    def device_terminal_runs(self, workspace_id: str, label: str) -> Dict[str, Any]:
        """A terminal created from the device runs a command typed from the
        device; its output is read back through this Mac's socket."""
        created = self.device_request("mobile.terminal.create", {"workspace_id": workspace_id})
        surface = created.get("created_terminal_id")
        if not surface:
            raise Failure(f"mobile.terminal.create returned no terminal: {created}")
        a, b = 1700 + len(label), 23
        marker = f"rhm-{label}-{self.nonce}"
        expected = f"{marker}={a * b}"

        def typed() -> bool:
            self.device_request("mobile.terminal.input", {
                "workspace_id": workspace_id, "surface_id": surface,
                "text": f"echo {marker}=$(({a}*{b}))\r",
            })
            return True

        def output() -> bool:
            text = (self.sock.call("surface.read_text", {
                "workspace_id": workspace_id, "surface_id": surface, "scrollback": True,
            }) or {}).get("text") or ""
            return expected in text

        # The shell may still be starting when the first line arrives; type again until it answers.
        deadline = time.monotonic() + self.timeout * 2
        while True:
            typed()
            try:
                wait_for(f"{expected} in the terminal", output, 6)
                break
            except Failure:
                if time.monotonic() > deadline:
                    raise
        return {"surface": surface, "output": expected}

    def assert_headless(self, what: str, state: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        state = state or self.state()
        visible = self.visible_windows(state)
        if visible:
            raise Failure(f"{what}: a main window is visible: {visible}")
        if state.get("activation_policy") != "accessory":
            raise Failure(f"{what}: activation policy {state.get('activation_policy')}, expected accessory (no Dock icon)")
        # Independent of the mode's own view: no terminal sits in a window on screen.
        terminals = (self.sock.call("debug.terminals", {}) or {}).get("terminals") or []
        shown = [t.get("surface_id") or t.get("id") for t in terminals if t.get("window_visible")]
        if shown:
            raise Failure(f"{what}: terminals in a visible window: {shown}")
        return state

    def show(self) -> Dict[str, Any]:
        self.sock.call(MENU, {"action": "show", "activate": False})
        return wait_for("Show Supermux to show a main window", lambda: self.visible_windows(), self.timeout)[0]

    def relaunch(self) -> None:
        app = self.args.app_path
        bundle_id = plistlib.loads((Path(app) / "Contents" / "Info.plist").read_bytes())["CFBundleIdentifier"]
        self.sock.close()
        subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to quit'], check=False, capture_output=True)
        wait_for("the app to quit", lambda: not self.app_running(bundle_id), 60, interval_s=0.5)
        wait_for("the old socket to go", lambda: not Path(self.sock.path).exists(), 30, interval_s=0.5)
        env_args = ["--env", "SUPERMUX_DEBUG_LOOPBACK_DEVICE=1"]
        if self.args.projects_file:
            env_args += ["--env", f"SUPERMUX_PROJECTS_FILE={self.args.projects_file}"]
        if self.args.push_state_dir:
            env_args += ["--env", f"SUPERMUX_PHONE_PUSH_STATE_DIR={self.args.push_state_dir}"]
        subprocess.run(["open", "-g", *env_args, app], check=True)
        wait_for("the relaunched app's socket", self.socket_alive, 60)
        self.sock.connect()

    def app_running(self, bundle_id: str) -> bool:
        result = subprocess.run(["osascript", "-e", f'application id "{bundle_id}" is running'],
                                check=False, capture_output=True, text=True)
        return result.stdout.strip() == "true"

    def socket_alive(self) -> bool:
        probe = Socket(self.sock.path, timeout_s=3)
        try:
            probe.connect()
            probe.call(STATE, {})
            return True
        except (OSError, Failure):
            return False
        finally:
            probe.close()

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
        self.machine = self.loopback_machine()
        state = self.state()
        if state.get("enabled"):
            state = self.sock.call(SET, {"enabled": False}) or {}
        visible = wait_for("a main window on screen with the mode off", lambda: self.visible_windows(), self.timeout)
        self.facts.update(machine=self.machine, initial_policy=state.get("activation_policy"))
        return {"machine": self.machine, "visible_windows": len(visible), "activation_policy": state.get("activation_policy")}

    def mode_on_hides_every_window(self) -> Dict[str, Any]:
        before = {w.get("window_id") for w in self.state().get("main_windows") or []}
        self.sock.call(SET, {"enabled": True})
        state = wait_for("every main window to hide", lambda: (lambda s: s if not self.visible_windows(s) else None)(self.state()), self.timeout)
        self.assert_headless("mode on", state)
        after = {w.get("window_id") for w in state.get("main_windows") or []}
        if not before <= after:
            raise Failure(f"turning the mode on closed windows {sorted(before - after)}")
        if not state.get("menu_bar_item_installed"):
            raise Failure("no menu bar item while the app has no window and no Dock icon")
        items = state.get("menu_items") or []
        for wanted in ("show", "turn_off"):
            if wanted not in [i.get("action") for i in items]:
                raise Failure(f"the menu bar item lacks {wanted}: {items}")
        hold("the windows stay hidden", lambda: not self.visible_windows(), 2)
        return {"windows": sorted(after), "menu_items": items, "app_active": state.get("app_active")}

    def device_workspace_works_headless(self) -> Dict[str, Any]:
        before = self.state()
        opened = self.sock.call(
            "supermux.devices.create_workspace",
            {"machine": self.machine, "title": self.device_title, "focus": False},
            timeout_s=60,
        ) or {}
        remote_id = up(opened.get("remote_workspace_id"))
        if not remote_id:
            raise Failure(f"create_workspace returned no remote_workspace_id: {opened}")
        self.device_workspace = remote_id
        wait_for("the device-created workspace here", lambda: remote_id in self.all_workspaces(), self.timeout)
        ran = self.device_terminal_runs(remote_id, "create")
        hold("no window shows and the app stays inactive", lambda: (
            not self.visible_windows() and (before.get("app_active") or not self.state().get("app_active"))
        ), 3)
        after = self.assert_headless("after the device created a workspace and a terminal")
        return {
            "remote_workspace": remote_id, "mirror": opened.get("workspace_id"), **ran,
            "windows_before": len(before.get("main_windows") or []), "windows_after": len(after.get("main_windows") or []),
            "app_active_before": before.get("app_active"), "app_active_after": after.get("app_active"),
        }

    def close_hides(self, via: str) -> Dict[str, Any]:
        window = self.show()
        window_id = window.get("window_id")
        workspaces = self.window_workspaces(window_id)
        reply = self.sock.call(CLOSE, {"window_id": window_id, "via": via}) or {}
        if reply.get("dialog_shown"):
            raise Failure(f"{via} asked before hiding: {reply}")

        def hidden() -> Optional[Dict[str, Any]]:
            state = self.state()
            row = next((w for w in state.get("main_windows") or [] if w.get("window_id") == window_id), None)
            if row is None:
                raise Failure(f"{via} closed window {window_id} instead of hiding it")
            return state if not row.get("visible") else None

        state = wait_for(f"{via} to hide the window", hidden, self.timeout)
        if not state.get("enabled"):
            raise Failure("the mode turned off")
        hold("the window stays registered with its workspaces", lambda: self.window_workspaces(window_id) == workspaces, 2)
        if self.visible_windows(state):
            # Another window shown by Show Supermux: hide it again for the next step.
            self.sock.call(MENU, {"action": "hide"})
            wait_for("Hide Supermux to hide every window", lambda: not self.visible_windows(), self.timeout)
        return {"window": window_id, "workspaces_kept": len(workspaces)}

    def hide_again(self) -> None:
        """Hide Supermux, so the next step starts headless."""
        self.sock.call(MENU, {"action": "hide"})
        wait_for("Hide Supermux to hide every window", lambda: not self.visible_windows(), self.timeout)

    def shown_by_user_request(self, what: str) -> Dict[str, Any]:
        visible = wait_for(f"{what} to show a main window", lambda: self.visible_windows(), self.timeout)
        state = self.state()
        if not state.get("enabled"):
            raise Failure(f"{what} turned the mode off")
        if state.get("activation_policy") != "accessory":
            raise Failure(f"{what}: activation policy {state.get('activation_policy')}, expected accessory")
        return {"visible_windows": len(visible), "headless": state.get("headless")}

    def global_hotkey_shows_windows(self) -> Dict[str, Any]:
        self.assert_headless("before the hotkey")
        self.sock.call(HOTKEY, {})
        shown = self.shown_by_user_request("the global hotkey")
        self.hide_again()
        return shown

    def notification_click_shows_windows(self) -> Dict[str, Any]:
        if not self.device_workspace:
            raise Failure("no device workspace (device_workspace_works_headless failed)")
        self.assert_headless("before the notification click")
        surfaces = (self.sock.call("surface.list", {"workspace_id": self.device_workspace}) or {}).get("surfaces") or []
        terminals = [up(s.get("id")) for s in surfaces if s.get("type") == "terminal"]
        surface = terminals[0] if terminals else None
        reply = self.sock.call(NOTIFICATION_CLICK, {"workspace_id": self.device_workspace, "surface_id": surface}) or {}
        shown = self.shown_by_user_request("the notification click")
        selected = wait_for("the notification's workspace selected", lambda: self.workspace_selected(self.device_workspace), self.timeout)
        self.hide_again()
        return {**shown, "opened": reply.get("opened"), "surface": surface, "selected": selected}

    def workspace_selected(self, workspace_id: str) -> bool:
        for window in (self.sock.call("window.list", {}) or {}).get("windows") or []:
            for row in (self.sock.call("workspace.list", {"window_id": window.get("id")}) or {}).get("workspaces") or []:
                if up(row.get("id")) == workspace_id:
                    return bool(row.get("is_selected") or row.get("selected"))
        return False

    def relaunch_stays_headless(self) -> Dict[str, Any]:
        self.relaunch()
        self.machine = self.loopback_machine()
        state = wait_for("the restored session", lambda: (lambda s: s if s.get("main_windows") else None)(self.state()), self.timeout)
        hold("no window shows after launch", lambda: not self.visible_windows(), 4)
        state = self.assert_headless("after relaunch")
        if state.get("app_active"):
            raise Failure("the app activated at launch")
        # The workspace keeps its id across a restore (its auto-mirror here has the same title, so match the id).
        restored = wait_for("the device workspace restored",
                            lambda: self.device_workspace if self.device_workspace in self.all_workspaces() else None,
                            self.timeout)
        ran = self.device_terminal_runs(restored, "relaunch")
        self.assert_headless("after the relaunched device terminal ran")
        return {"restored_workspace": restored, "windows": len(state.get("main_windows") or []), **ran}

    def mode_off_shows_windows(self) -> Dict[str, Any]:
        self.sock.call(SET, {"enabled": False})
        visible = wait_for("main windows to show again", lambda: self.visible_windows(), self.timeout)
        state = wait_for("the regular activation policy", lambda: (lambda s: s if s.get("activation_policy") == "regular" else None)(self.state()), self.timeout)
        if any(i.get("action") in ("show", "hide", "turn_off") for i in state.get("menu_items") or []):
            raise Failure(f"the menu bar item still offers Remote Host Mode items: {state.get('menu_items')}")
        return {"visible_windows": len(visible)}

    # -- run ------------------------------------------------------------------

    def cleanup(self) -> None:
        try:
            if self.state().get("enabled"):
                self.sock.call(SET, {"enabled": False})
            for workspace_id, title in self.all_workspaces().items():
                if title == self.device_title:
                    self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
        except (Failure, OSError) as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        ok = self.step("setup", self.setup)
        if ok:
            ok = self.step("mode_on_hides_every_window", self.mode_on_hides_every_window)
        if ok:
            ok = self.step("device_workspace_works_headless", self.device_workspace_works_headless) and ok
            ok = self.step("close_button_hides_window", lambda: self.close_hides("close_button")) and ok
            ok = self.step("close_window_command_hides_window", lambda: self.close_hides("close_window_command")) and ok
            ok = self.step("global_hotkey_shows_windows", self.global_hotkey_shows_windows) and ok
            ok = self.step("notification_click_shows_windows", self.notification_click_shows_windows) and ok
            if self.args.app_path:
                ok = self.step("relaunch_stays_headless", self.relaunch_stays_headless) and ok
            ok = self.step("mode_off_shows_windows", self.mode_off_shows_windows) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--app-path", help="the tagged app, for the relaunch step")
    parser.add_argument("--projects-file", help="SUPERMUX_PROJECTS_FILE for the relaunch")
    parser.add_argument("--push-state-dir", help="SUPERMUX_PHONE_PUSH_STATE_DIR for the relaunch")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per wait")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = RemoteHostModeE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-remote-host-mode-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_remote_host_mode_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
