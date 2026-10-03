#!/usr/bin/env python3
"""End-to-end test of the Settings "Remote Macs" card and the flat-row Mac
icon, against one tagged DEBUG build running the loopback device.

The card's socket twins (`supermux.devices.remote_macs_settings*`) read the
card's exact snapshot and call the card's own actions, so these checks drive
the same write path as the toggles and buttons:

  1. setup                        the loopback linked and fetched; settings recorded for restore
  2. card_lists_loopback_mac      the card lists the Loopback Mac, connected, with its workspace count
  3. auto_mirror_toggle_is_live   off: a new workspace gets no mirror; on again: it gets one, no relaunch
  4. hidden_count_and_show        Hide Here raises the card's hidden count; Show Hidden Workspaces
                                  brings the mirror back and clears it
  5. sync_and_share_round_trip    the two other toggles write and read back
  6. flat_chip_names_mac          a mirror's flat row marks the Loopback Mac with the small Mac + cloud
                                  icon (tooltip "On <Mac>", not dimmed, no name capsule) on its
                                  branch/directory line (before the title when the row has none)
  7. settings_card_screenshot     (with --screenshot) opens Settings on Automation and captures the window

Writes a JSON report (default tests/supermux/artifacts/loopback_remote_macs_settings_e2e-<tag>.json)
and exits non-zero on any failure. Stdlib only; shares the socket client with
loopback_tab_sync_e2e.py.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_remote_macs_settings_e2e.py [--screenshot] [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
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


def hold(description: str, probe: Callable[[], Any], seconds: float, interval_s: float = 0.4) -> None:
    """Asserts `probe` stays truthy for `seconds` (negative checks)."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not probe():
            raise Failure(f"{description} stopped holding")
        time.sleep(interval_s)


class RemoteMacsSettingsE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.machine = ""
        self.initial: Dict[str, Any] = {}
        self.created: List[str] = []

    # -- reads and actions ----------------------------------------------------

    def settings(self) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.remote_macs_settings", {}) or {}

    def set_setting(self, setting: str, enabled: bool) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.remote_macs_settings_set", {"setting": setting, "enabled": enabled}) or {}

    def loopback_device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def mirrors_of(self, source_id: str) -> List[Dict[str, Any]]:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        return [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(source_id)]

    def create_source(self, label: str) -> str:
        title = f"remote-macs-{label}-{self.nonce}"
        result = self.sock.call("workspace.create", {"title": title, "focus": False}) or {}
        workspace_id = up(result.get("workspace_id") or result.get("created_workspace_id"))
        if not workspace_id:
            raise Failure(f"workspace.create returned no id: {result}")
        self.sock.call("workspace.rename", {"workspace_id": workspace_id, "title": title})
        self.created.append(workspace_id)
        return workspace_id

    def one_mirror(self, source_id: str) -> Optional[Dict[str, Any]]:
        mirrors = self.mirrors_of(source_id)
        if len(mirrors) > 1:
            raise Failure(f"{len(mirrors)} mirrors of {source_id}")
        return mirrors[0] if mirrors else None

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

        self.machine = wait_for("the loopback device to connect", ready, self.timeout)["machine"]
        self.initial = self.settings()
        if not self.initial.get("auto_mirror"):
            self.set_setting("auto_mirror", True)
        self.facts.update(machine=self.machine, initial_settings={k: self.initial.get(k) for k in ("auto_mirror", "sync_projects", "share_push")})
        return {"machine": self.machine}

    def card_lists_loopback_mac(self) -> Dict[str, Any]:
        def listed() -> Optional[Dict[str, Any]]:
            device = self.loopback_device()
            macs = {m.get("machine"): m for m in self.settings().get("macs") or []}
            mac = macs.get(self.machine)
            if mac is None:
                raise Failure(f"the card does not list {self.machine}: {sorted(macs)}")
            if mac.get("link") != "connected":
                raise Failure(f"the card shows link {mac.get('link')}")
            if mac.get("workspace_count") != device.get("record_count"):
                raise Failure(f"card count {mac.get('workspace_count')} != device records {device.get('record_count')}")
            return mac

        mac = wait_for("the card to list the Loopback Mac", listed, self.timeout)
        return {"mac": mac}

    def auto_mirror_toggle(self) -> Dict[str, Any]:
        state = self.set_setting("auto_mirror", False)
        if state.get("auto_mirror") is not False:
            raise Failure(f"the card's action did not turn auto-mirror off: {state}")
        source = self.create_source("toggle")
        wait_for("the new workspace on the device", lambda: any(
            up(r.get("id")) == source and (r.get("terminal_count") or 0) > 0 for r in self.loopback_device().get("records") or []
        ), self.timeout)
        hold("no mirror while auto-mirror is off", lambda: not self.mirrors_of(source), 4)
        started = time.monotonic()
        self.set_setting("auto_mirror", True)
        mirror = wait_for("a mirror once auto-mirror is back on", lambda: self.one_mirror(source), self.timeout)
        self.facts["toggle_source"] = source
        return {"source": source, "mirror": mirror.get("workspace_id"), "mirror_after_seconds": round(time.monotonic() - started, 2)}

    def hidden_count_and_show(self) -> Dict[str, Any]:
        source = self.facts["toggle_source"]
        mirror = self.one_mirror(source) or {}
        before = self.settings().get("hidden_workspace_count", 0)
        self.sock.call("supermux.devices.close_mirror", {"workspace_id": mirror.get("workspace_id"), "action": "hide"})
        wait_for("the card's hidden count to grow", lambda: self.settings().get("hidden_workspace_count", 0) == before + 1, self.timeout)
        hold("the hidden workspace stays unmirrored", lambda: not self.mirrors_of(source), 3)
        state = self.sock.call("supermux.devices.remote_macs_settings_set", {"action": "show_hidden"}) or {}
        again = wait_for("Show Hidden Workspaces to bring the mirror back", lambda: self.one_mirror(source), self.timeout)
        if state.get("hidden_workspace_count") != 0:
            raise Failure(f"hidden count after Show Hidden Workspaces: {state.get('hidden_workspace_count')}")
        return {"hidden_before": before, "reopened_mirror": again.get("workspace_id")}

    def sync_and_share_round_trip(self) -> Dict[str, Any]:
        seen: Dict[str, List[bool]] = {}
        for setting in ("sync_projects", "share_push"):
            for value in (False, True):
                state = self.set_setting(setting, value)
                if state.get(setting) is not value:
                    raise Failure(f"{setting}={value} did not stick: {state.get(setting)}")
                seen.setdefault(setting, []).append(state.get(setting))
        return {"read_back": seen}

    def flat_chip_names_mac(self) -> Dict[str, Any]:
        mirror = self.one_mirror(self.facts["toggle_source"]) or {}
        mac_name = next((m.get("name") for m in self.settings().get("macs") or [] if m.get("machine") == self.machine), None)

        def chip() -> Optional[Dict[str, Any]]:
            chips = (self.sock.call("supermux.devices.flat_chips", {}) or {}).get("chips") or []
            return next((c for c in chips if up(c.get("workspace_id")) == up(mirror.get("workspace_id"))), None)

        found = wait_for("the mirror's flat-row chip", chip, self.timeout)
        if found.get("mac_name") != mac_name:
            raise Failure(f"the chip names {found.get('mac_name')!r}, not {mac_name!r}")
        if found.get("chip_state") != "online" or found.get("dimmed"):
            raise Failure(f"a connected Mac's chip renders {found.get('chip_state')} dimmed={found.get('dimmed')}")
        # Drawn as the small Mac + cloud icon (no name capsule), its tooltip
        # naming the Mac, on the row's branch/directory line when the row shows
        # one (else before the title).
        flat = next((r for r in (self.sock.call("supermux.devices.sidebar_rows", {}) or {}).get("flat") or []
                     if up(r.get("workspace_id")) == up(mirror.get("workspace_id"))), {})
        has_line = bool(flat.get("subtitle_candidates") or flat.get("branch_directory_lines"))
        expected = {
            "style": "icon",
            "symbol": "laptopcomputer",
            "help": f"On {mac_name}",
            "placement": "branch_line" if has_line else "title_line",
        }
        wrong = {key: found.get(key) for key, value in expected.items() if found.get(key) != value}
        if wrong:
            raise Failure(f"the flat-row Mac marker has {wrong}, expected {expected}")
        return {"chip": found, "row_has_branch_line": has_line}

    def settings_card_screenshot(self) -> Dict[str, Any]:
        self.sock.call("settings.open", {"target": "automation", "activate": False})
        time.sleep(2.0)
        path = ARTIFACTS_DIR / f"remote_macs_settings-{self.args.tag or 'socket'}.png"
        ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)
        pid = subprocess.run(["pgrep", "-f", f"cmux DEV {self.args.tag}.app/Contents/MacOS/"], capture_output=True, text=True).stdout.split()
        if not pid:
            raise Failure("the tagged app's process was not found")
        script = (
            "ObjC.import('CoreGraphics');"
            "var list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));"
            f"var mine = list.filter(function(w){{return w.kCGWindowOwnerPID == {pid[0]} && w.kCGWindowLayer == 0"
            " && String(w.kCGWindowName || '').indexOf('Settings') >= 0;});"
            "mine.length ? String(mine[0].kCGWindowNumber) : '';"
        )
        window = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True).stdout.strip()
        if not window:
            raise Failure("no on-screen Settings window to capture (Screen Recording permission?)")
        subprocess.run(["screencapture", "-x", "-o", "-l", window, str(path)], capture_output=True, text=True)
        if not path.exists() or path.stat().st_size == 0:
            raise Failure("screencapture wrote nothing")
        return {"screenshot": str(path)}

    # -- run ------------------------------------------------------------------

    def cleanup(self) -> None:
        try:
            for setting in ("auto_mirror", "sync_projects", "share_push"):
                if setting in self.initial:
                    self.set_setting(setting, bool(self.initial[setting]))
            for workspace_id in self.created:
                for mirror in self.mirrors_of(workspace_id):
                    self.sock.call("workspace.close", {"workspace_id": mirror.get("workspace_id"), "force": True})
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            self.sock.call("supermux.devices.unhide", {})
        except (Failure, OSError) as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        ok = self.step("setup", self.setup)
        if ok:
            checks = [
                ("card_lists_loopback_mac", self.card_lists_loopback_mac),
                ("auto_mirror_toggle_is_live", self.auto_mirror_toggle),
                ("hidden_count_and_show", self.hidden_count_and_show),
                ("sync_and_share_round_trip", self.sync_and_share_round_trip),
                ("flat_chip_names_mac", self.flat_chip_names_mac),
            ]
            if self.args.screenshot:
                checks.append(("settings_card_screenshot", self.settings_card_screenshot))
            for name, check in checks:
                ok = self.step(name, check) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per wait")
    parser.add_argument("--screenshot", action="store_true", help="also open Settings and capture it")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = RemoteMacsSettingsE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-remote-macs-settings-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_remote_macs_settings_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
