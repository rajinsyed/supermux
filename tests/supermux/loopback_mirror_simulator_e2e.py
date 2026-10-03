#!/usr/bin/env python3
"""End-to-end test: a device mirror's Simulator runs on the Mac that owns the workspace.

"New Simulator" in a mirror of another Mac's workspace booted a simulator on THIS Mac
(the viewing one): a local `SimulatorPanel`, its worker, CoreSimulator and the disk
it costs. Now it opens (or reuses) a real `SimulatorPanel` in the source workspace on
the owning Mac, and the mirror shows a viewer tab that plays that panel's simulator
stream (v2, HEVC/H.264). Nothing simulator-related runs here.

One tagged DEBUG build runs the loopback device ("Loopback Mac" = this same app's own
mobile host), so the source workspace S is "the other Mac" and its auto mirror M is
the viewer. The stream crosses the DEBUG loopback lane, which runs the host's real v2
session, pump, encoder and worker ring; only QUIC is replaced.

  1. setup                                  auto-mirror on, the loopback linked and fetched
  2. source_and_mirror                      a background source workspace S and its mirror M
  3. simulator_device                       a simulator of the suite's own (`simctl create`),
                                            or --udid; no iOS runtime skips every later step
  4. boot_from_mirror_terminal              `xcrun simctl boot <udid>` typed into M's terminal
                                            runs on the owning Mac (a build or `flutter run`
                                            there boots devices the same way)
  5. socket_create_in_mirror_never_local    surface.create {type: simulator} on M fails; M holds
                                            no SimulatorPanel
  6. new_simulator_runs_on_owner            New Simulator (the configured action) in M: S holds
                                            one SimulatorPanel, M one viewer and no SimulatorPanel,
                                            the app one SimulatorPanel more than before; the
                                            viewer is bound to (loopback, S, S's panel)
  7. build_booted_simulator_shows_up        the viewer shows the device step 4 booted
  8. streams_video                          streaming, presented frames +10, hevc/h264, long side
                                            <= 2000, one simulator worker more (window screenshot
                                            kept next to the report)
  9. device_picker_lists_owner_devices      the picker lists the owner's iPhone/iPad simulators;
                                            choosing another boots it there and the stream follows
                                            (the owner's tab shows it, then the viewer plays new
                                            frames; a device of the same size sends no new config)
 10. home_button_reaches_owner              Settings in front, the viewer's Home -> SpringBoard
 11. rotate_via_control                     Rotate Left/Right reach the owner's simulator
 12. quality_cap                            Data Saver -> the next config's long side <= 800
 13. layout_follows_with_simulator          with the viewer open, a split in S is projected into M
                                            and M takes S's new name
 14. close_mirror_terminal_with_viewer_open closing a mirror terminal tab closes its source terminal
 15. link_drop_reconnects                   link down -> not streaming; back up -> streaming again
 16. superseded_no_ping_pong                another viewer takes the stream: this one waits
                                            ("superseded") without taking it back; Show Here does
 17. owner_close_closes_viewer              closing S's Simulator tab closes the viewer tab
 18. viewer_close_closes_owner_panel        closing the viewer tab closes S's Simulator tab; its
                                            worker exits; the device stays booted (the suite's
                                            device: a new tab showing another booted simulator, the
                                            owner's first pick, is switched to it first)
 19. new_simulator_tab_bar_runs_on_owner    the pane tab bar's New Simulator button: as step 6
 20. slow_simctl_lists_and_streams          with every `simctl` spawn of the app slowed past the link's
                                            20 s reply deadline (the DEBUG `simctl_delay` hook, as on a Mac
                                            whose new processes stall in dyld), a new Simulator tab's
                                            picker still lists the owner's devices and the tab streams
 21. slow_simctl_device_menu_says_so        the same with CoreSimulator off on the owner (the `simctl` fallback):
                                            the device menu's reply still comes well inside the deadline, marked
                                            slow ("Simulators on <Mac> are slow to respond…" instead of an empty
                                            menu), and the viewer asks again until the list is current
 22. restore_rebinds                        (--app-path) quit (`tell application id … to quit`, as
                                            scripts and launchers do, with a simulator worker
                                            running) within 60s, the script seeing no error, and
                                            relaunch: the viewer comes back in M, streams S's
                                            restored panel, no second SimulatorPanel

Writes a JSON report (default tests/supermux/artifacts/loopback_mirror_simulator_e2e-<tag>.json)
and a window screenshot next to it (`…-viewer.png`), and exits non-zero on any failure. The
suite's simulators are shut down and deleted at the end (--keep-device keeps them; --udid
reuses an existing one and never deletes it). Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_simulator_e2e.py [--app-path APP] [--udid UDID]
      [--keep-device] [--timeout 30] [--keep] [--report PATH] [--slow-simctl SECONDS]

--slow-simctl arms the slow-`simctl` hook for the whole run (and the relaunch), not only steps 20-21.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

LOOPBACK_DEVICE_ID = "5e1f10b0-0000-4000-8000-000000000001"
REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = REPO_ROOT / "tests" / "supermux" / "artifacts"
WORKER_ARGUMENT = "--cmux-simulator-worker"
SIM = "supermux.devices.mirror.simulator."
# Step 20's delay per `simctl` spawn of the app: more than the device link's 20 s reply deadline, as on
# the Mac where every `simctl` launch stalled 20-22 s in dyld before `main` (2026-10-03).
SLOW_SIMCTL_SECONDS = 25.0
SIMCTL_DELAY_ENV = "SUPERMUX_DEBUG_SIMCTL_DELAY_SECONDS"


class Failure(Exception):
    """A check failed; the message says which and why."""


class Skipped(Exception):
    """A step that cannot run in this invocation (it says why)."""


class RateLimited(Exception):
    """The socket's polling limiter refused a read; retry after the hint."""

    def __init__(self, retry_after_s: float) -> None:
        super().__init__(f"rate limited for {retry_after_s}s")
        self.retry_after_s = max(0.05, retry_after_s)


class Socket:
    """Newline-delimited JSON client for the cmux v2 control socket."""

    # The app drops a client that sent nothing for 30 s (`clientReadTimeout`);
    # a step that waits on simctl (a slow boot) would find the pipe broken.
    IDLE_RECONNECT_S = 20.0

    def __init__(self, path: str, timeout_s: float = 30.0) -> None:
        self.path = path
        self.timeout_s = timeout_s
        self._sock: Optional[socket.socket] = None
        self._buffer = b""
        self._next_id = 1
        self._last_used = 0.0

    def connect(self) -> "Socket":
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout_s)
        sock.connect(self.path)
        self._sock = sock
        self._buffer = b""
        self._last_used = time.monotonic()
        return self

    def close(self) -> None:
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    @property
    def connected(self) -> bool:
        return self._sock is not None

    def call(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Any:
        """One request; waits out the socket's per-connection polling limit."""
        for _ in range(20):
            try:
                return self._call_once(method, params, timeout_s)
            except RateLimited as limited:
                time.sleep(limited.retry_after_s)
        return self._call_once(method, params, timeout_s)

    def _call_once(self, method: str, params: Optional[Dict[str, Any]], timeout_s: Optional[float]) -> Any:
        assert self._sock is not None, "not connected"
        if time.monotonic() - self._last_used > self.IDLE_RECONNECT_S:
            self.close()  # before sending, so no request is lost or sent twice
            self.connect()
        self._last_used = time.monotonic()
        request_id = self._next_id
        self._next_id += 1
        line = json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n"
        self._sock.sendall(line.encode("utf-8"))
        response = json.loads(self._read_line(timeout_s or self.timeout_s))
        if response.get("id") != request_id:
            raise Failure(f"{method}: mismatched response id")
        if response.get("ok") is True:
            return response.get("result")
        error = response.get("error") or {}
        if error.get("code") == "rate_limited":
            raise RateLimited(((error.get("data") or {}).get("retry_after_ms") or 100) / 1000.0)
        raise Failure(f"{method}: {error.get('code', 'error')}: {error.get('message', 'unknown error')}")

    def _read_line(self, timeout_s: float) -> str:
        assert self._sock is not None
        deadline = time.monotonic() + timeout_s
        while b"\n" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Failure("socket response timed out")
            self._sock.settimeout(remaining)
            chunk = self._sock.recv(65536)
            if not chunk:
                raise Failure("socket closed by the app")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        return line.decode("utf-8", errors="replace")


def socket_path_for_tag(tag: str) -> str:
    slug = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", tag.strip().lower())).strip("-")
    return f"/tmp/cmux-debug-{slug}.sock"


def up(identifier: Any) -> str:
    return str(identifier or "").strip().upper()


def wait_for(description: str, probe: Callable[[], Any], timeout_s: float, interval_s: float = 0.25) -> Any:
    deadline = time.monotonic() + timeout_s
    last: Optional[str] = None
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value:
                return value
        except Failure as error:
            last = str(error)
        time.sleep(interval_s)
    raise Failure(f"timed out after {timeout_s:.0f}s waiting for {description}" + (f" (last: {last})" if last else ""))


def simctl(*args: str, timeout_s: float = 60, check: bool = True) -> subprocess.CompletedProcess:
    """`xcrun simctl …`; raises Failure when it fails and `check` is set."""
    try:
        result = subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True, timeout=timeout_s)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failure(f"simctl {' '.join(args)}: {error}")
    if check and result.returncode != 0:
        raise Failure(f"simctl {' '.join(args)} exited {result.returncode}: {result.stderr.strip()[:300]}")
    return result


def simctl_json(*args: str) -> Dict[str, Any]:
    return json.loads(simctl(*args, "--json").stdout or "{}")


def device_state(udid: str) -> Optional[str]:
    for devices in (simctl_json("list", "devices").get("devices") or {}).values():
        for device in devices:
            if up(device.get("udid")) == up(udid):
                return device.get("state")
    return None


def newest_booted_phone_or_tablet() -> Optional[str]:
    """The device a new Simulator panel picks first: booted, iPhone before iPad,
    most recently booted (`simulatorDeviceOrdering` in CmuxSimulatorUI)."""
    booted = []
    for devices in (simctl_json("list", "devices", "available").get("devices") or {}).values():
        for device in devices:
            kind = str(device.get("deviceTypeIdentifier") or "")
            if device.get("state") == "Booted" and ("iPhone" in kind or "iPad" in kind):
                booted.append(("iPhone" in kind, str(device.get("lastBootedAt") or ""), up(device.get("udid"))))
    return max(booted)[2] if booted else None


def available_phone_and_tablet_udids() -> List[str]:
    """What the owner's picker may list: available iPhone and iPad simulators."""
    udids: List[str] = []
    for devices in (simctl_json("list", "devices", "available").get("devices") or {}).values():
        for device in devices:
            kind = str(device.get("deviceTypeIdentifier") or "")
            if device.get("isAvailable", True) and ("iPhone" in kind or "iPad" in kind):
                udids.append(up(device.get("udid")))
    return sorted(udids)


def screenshot_hash(udid: str) -> Optional[str]:
    path = Path(f"/tmp/supermux-sim-{uuid.uuid4().hex[:8]}.png")
    try:
        simctl("io", udid, "screenshot", str(path), timeout_s=30)
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except Failure:
        return None
    finally:
        path.unlink(missing_ok=True)


class MirrorSimulatorE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace, report_path: Path) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.report_path = report_path
        self.nonce = uuid.uuid4().hex[:6]
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce}
        self.machine = ""
        self.source = ""
        self.mirror = ""
        self.udid: Optional[str] = None
        self.created_udids: List[str] = []
        self.no_runtime: Optional[str] = None
        self.baseline_panels = 0
        self.baseline_workers = 0
        self.split_terminal: Optional[str] = None
        self.last_stir = 0.0

    # -- reads ----------------------------------------------------------------

    def device(self) -> Dict[str, Any]:
        for device in (self.sock.call("supermux.devices.list", {}) or {}).get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device in supermux.devices.list (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def mirrors_of(self, owner_id: str) -> List[Dict[str, Any]]:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        return [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(owner_id)]

    def local_workspaces(self) -> Dict[str, Dict[str, Any]]:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("local_workspaces") or []
        return {up(row.get("workspace_id")): row for row in rows}

    def terminals(self, workspace_id: str) -> List[str]:
        surfaces = (self.sock.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        return [up(s.get("id")) for s in surfaces if s.get("type") == "terminal"]

    def projected_sources(self) -> Dict[str, str]:
        """Mirror panel id -> the source terminal it projects."""
        return {
            up(p.get("panel_id")): up(str(p.get("resource", "")).rsplit("/", 1)[-1])
            for p in (self.sock.call("surface.catalog", {}) or {}).get("projections") or []
            if up(p.get("workspace_id")) == up(self.mirror) and str(p.get("resource", "")).startswith(self.machine)
        }

    def sim_state(self, include_devices: bool = False) -> Dict[str, Any]:
        return self.sock.call(SIM + "state", {"include_devices": include_devices}, timeout_s=60) or {}

    def panels(self, workspace_id: str, kind: str, state: Optional[Dict[str, Any]] = None) -> List[Dict[str, Any]]:
        state = state if state is not None else self.sim_state()
        return [p for p in state.get("panels") or []
                if up(p.get("workspace_id")) == up(workspace_id) and p.get("class") == kind]

    def viewer(self, include_devices: bool = False) -> Optional[Dict[str, Any]]:
        viewers = self.panels(self.mirror, "viewer", self.sim_state(include_devices))
        return viewers[0] if viewers else None

    def need_viewer(self, include_devices: bool = False) -> Dict[str, Any]:
        viewer = self.viewer(include_devices)
        if viewer is None:
            raise Failure("precondition: the mirror holds no simulator viewer tab")
        return viewer

    def host_panel(self) -> str:
        panels = self.panels(self.source, "local")
        if len(panels) != 1:
            raise Failure(f"the source holds {len(panels)} SimulatorPanels, expected 1")
        return up(panels[0]["panel_id"])

    def workers(self) -> int:
        """Simulator worker processes this app started (its direct children)."""
        return len(self.worker_pids(int(self.sim_state().get("app_pid") or 0)))

    def host_context(self, panel_id: str) -> Dict[str, Any]:
        return self.sock.call("simulator.context", {"workspace_id": self.source, "surface_id": panel_id}, timeout_s=60) or {}

    def foreground(self, panel_id: str) -> Optional[str]:
        result = self.sock.call("simulator.foreground", {"workspace_id": self.source, "surface_id": panel_id},
                                timeout_s=60) or {}
        application = result.get("application") or {}
        return application.get("bundle_id")

    # -- actions --------------------------------------------------------------

    def new_simulator(self, path: str) -> Dict[str, Any]:
        self.sock.call("workspace.select", {"workspace_id": self.mirror})
        return self.sock.call(SIM + "new_action", {"workspace_id": self.mirror, "path": path}) or {}

    def viewer_call(self, action: str, params: Dict[str, Any]) -> Dict[str, Any]:
        viewer = self.need_viewer()
        result = self.sock.call(SIM + action, {"panel_id": viewer["panel_id"], **params}, timeout_s=60) or {}
        if result.get("accepted") is False:
            raise Failure(f"{action} was not accepted: {result}")
        return result

    def set_simctl_delay(self, seconds: float, coresimulator: bool = True) -> float:
        """Arms the app's slow-`simctl` hook (DEBUG); `coresimulator=False` also makes the owner list its
        devices with `simctl` (the fallback when CoreSimulator cannot be used). Returns the previous delay."""
        result = self.sock.call(SIM + "simctl_delay", {"seconds": seconds, "coresimulator": coresimulator}) or {}
        if float(result.get("seconds", -1)) != float(seconds):
            raise Failure(f"simctl_delay did not take {seconds}: {result}")
        return float(result.get("previous") or 0)

    def stir(self) -> None:
        """Makes the simulator draw (an idle home screen sends no frames); at most every 3 s."""
        if not self.udid or time.monotonic() - self.last_stir < 3:
            return
        self.last_stir = time.monotonic()
        simctl("launch", self.udid, "com.apple.Preferences", check=False)
        simctl("ui", self.udid, "appearance", "dark", check=False)
        simctl("ui", self.udid, "appearance", "light", check=False)

    def close_local_simulators_in_mirror(self) -> List[str]:
        """Closes what an old build wrongly made: local SimulatorPanels in M."""
        closed = []
        for panel in self.panels(self.mirror, "local"):
            self.sock.call("surface.close", {"workspace_id": self.mirror, "surface_id": panel["panel_id"], "force": True})
            closed.append(panel["panel_id"])
        return closed

    def wait_streaming(self, after_frames: int, at_least: int, timeout_s: float) -> Dict[str, Any]:
        def streaming() -> Optional[Dict[str, Any]]:
            viewer = self.need_viewer()
            frames = int(viewer.get("presented_frames") or 0)
            if viewer.get("phase") != "streaming" or frames < after_frames + at_least:
                self.stir()
                raise Failure(f"phase={viewer.get('phase')} {viewer.get('phase_detail') or ''} frames={frames} "
                              f"owner's Simulator={viewer.get('host_status')} attachment={viewer.get('attachment')}")
            return viewer

        return wait_for(f"the viewer to stream {at_least} new frames", streaming, timeout_s, interval_s=1.0)

    def one_viewer_on_owner(self) -> Dict[str, Any]:
        """S holds one SimulatorPanel, M one viewer bound to it and no SimulatorPanel."""
        def settled() -> Optional[Dict[str, Any]]:
            state = self.sim_state()
            source_panels = self.panels(self.source, "local", state)
            mirror_local = self.panels(self.mirror, "local", state)
            viewers = self.panels(self.mirror, "viewer", state)
            total = int(state.get("simulator_panel_count") or 0)
            summary = (f"source SimulatorPanels={len(source_panels)} mirror SimulatorPanels={len(mirror_local)} "
                       f"mirror viewers={len(viewers)} app SimulatorPanels={total} (baseline {self.baseline_panels})")
            if mirror_local:
                raise Failure("a local simulator in the mirror: " + summary)
            if len(source_panels) != 1 or len(viewers) != 1 or total != self.baseline_panels + 1:
                raise Failure(summary)
            binding = viewers[0].get("binding") or {}
            want = {"machine": self.machine, "remote_workspace_id": self.source,
                    "host_panel_id": up(source_panels[0]["panel_id"])}
            got = {"machine": binding.get("machine"), "remote_workspace_id": up(binding.get("remote_workspace_id")),
                   "host_panel_id": up(binding.get("host_panel_id"))}
            if got != want:
                raise Failure(f"viewer binding {got} != {want}")
            return {"viewer": viewers[0], "host_panel_id": want["host_panel_id"], "summary": summary}

        return wait_for("New Simulator to land on the owning Mac", settled, self.timeout, interval_s=0.5)

    # -- steps ----------------------------------------------------------------

    def step(self, name: str, action: Callable[[], Optional[Dict[str, Any]]], needs_simulator: bool = True) -> bool:
        started = time.monotonic()
        record: Dict[str, Any] = {"name": name}
        try:
            if needs_simulator and self.no_runtime:
                raise Skipped(self.no_runtime)
            record.update(action() or {})
            record["ok"] = True
        except Skipped as skipped:
            record["ok"] = None
            record["skipped"] = str(skipped)
        except (Failure, OSError) as error:
            record["ok"] = False
            record["error"] = str(error)
        record["seconds"] = round(time.monotonic() - started, 2)
        self.steps.append(record)
        label = {True: "PASS", False: "FAIL", None: "SKIP"}[record["ok"]]
        detail = record.get("error") or record.get("skipped")
        print(f"{label} {name} ({record['seconds']}s){': ' + detail if detail else ''}", file=sys.stderr)
        return record["ok"] is not False

    def setup(self) -> Dict[str, Any]:
        state = self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True}) or {}

        def ready() -> Optional[Dict[str, Any]]:
            device = self.device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        self.machine = wait_for("the loopback device to connect", ready, self.timeout)["machine"]
        if self.args.slow_simctl:
            self.facts["slow_simctl_whole_run"] = self.args.slow_simctl
            self.set_simctl_delay(self.args.slow_simctl)
        sim = self.sim_state()
        self.baseline_panels = int(sim.get("simulator_panel_count") or 0)
        self.baseline_workers = self.workers()
        self.facts.update(machine=self.machine, baseline_panels=self.baseline_panels,
                          baseline_workers=self.baseline_workers, app_pid=sim.get("app_pid"))
        return {"machine": self.machine, "auto_mirror": state.get("auto_mirror"),
                "baseline_panels": self.baseline_panels, "baseline_workers": self.baseline_workers}

    def source_and_mirror(self) -> Dict[str, Any]:
        title = f"mirror-simulator-{self.nonce}"
        created = self.sock.call("workspace.create", {"title": title, "focus": False}) or {}
        self.source = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not self.source:
            raise Failure(f"workspace.create returned no id: {created}")
        self.sock.call("workspace.rename", {"workspace_id": self.source, "title": title})

        def one_mirror() -> Optional[Dict[str, Any]]:
            mirrors = self.mirrors_of(self.source)
            if len(mirrors) > 1:
                raise Failure(f"{len(mirrors)} mirrors of {self.source}")
            return mirrors[0] if mirrors else None

        self.mirror = up(wait_for("the source's auto mirror", one_mirror, self.timeout)["workspace_id"])
        wait_for("the mirror to project the source's terminal", lambda: self.projected_sources(), self.timeout)
        self.facts.update(source=self.source, mirror=self.mirror)
        return {"source": self.source, "mirror": self.mirror, "source_terminals": self.terminals(self.source)}

    def simulator_device(self) -> Dict[str, Any]:
        if shutil.which("xcrun") is None:
            self.no_runtime = "no_simulator_runtime: xcrun is missing"
            raise Skipped(self.no_runtime)
        if self.args.udid:
            if device_state(self.args.udid) is None:
                raise Failure(f"--udid {self.args.udid} is not a simulator on this Mac")
            self.udid = up(self.args.udid)
            return {"udid": self.udid, "reused": True}
        try:
            self.udid = self.create_device(f"supermux-e2e-{self.args.tag or 'socket'}-{self.nonce}")
        except Skipped as skipped:
            self.no_runtime = str(skipped)
            raise
        self.facts["udid"] = self.udid
        return {"udid": self.udid, "reused": False}

    def create_device(self, name: str) -> str:
        """A new iPhone simulator on the newest available iOS runtime."""
        try:
            runtimes = simctl_json("list", "runtimes").get("runtimes") or []
        except Failure as error:
            raise Skipped(f"no_simulator_runtime: {error}")
        ios = [r for r in runtimes if r.get("isAvailable") and ".iOS-" in str(r.get("identifier"))]
        if not ios:
            raise Skipped("no_simulator_runtime: no available iOS runtime")
        runtime = sorted(ios, key=lambda r: [int(x) for x in re.findall(r"\d+", str(r.get("version") or "0"))])[-1]
        phones = [t for t in runtime.get("supportedDeviceTypes") or [] if t.get("productFamily") == "iPhone"]
        if not phones:
            raise Skipped(f"no_simulator_runtime: {runtime.get('identifier')} supports no iPhone")
        udid = up(simctl("create", name, phones[0]["identifier"], runtime["identifier"]).stdout.strip())
        self.created_udids.append(udid)
        return udid

    def boot_from_mirror_terminal(self) -> Dict[str, Any]:
        udid = self.need_udid()
        mirror_terminals = list(self.projected_sources().keys())
        if not mirror_terminals:
            raise Failure("the mirror shows no terminal to type into")
        self.sock.call("surface.send_text", {"workspace_id": self.mirror, "surface_id": mirror_terminals[0],
                                             "text": f"xcrun simctl boot {udid}\n"})
        try:
            wait_for("the mirror terminal's simctl boot to boot the device", lambda: device_state(udid) in ("Booting", "Booted"),
                     60, interval_s=1.0)
            booted_by_terminal = True
        except Failure:
            booted_by_terminal = False
            simctl("boot", udid, check=False)
        simctl("bootstatus", udid, "-b", timeout_s=300)
        if not booted_by_terminal:
            raise Failure("typing `xcrun simctl boot` into the mirror terminal did not boot the device "
                          "(booted it directly so later steps can run)")
        return {"udid": udid, "state": device_state(udid)}

    def socket_create_in_mirror_never_local(self) -> Dict[str, Any]:
        self.need_udid()
        error: Optional[str] = None
        try:
            created = self.sock.call("surface.create", {"workspace_id": self.mirror, "type": "simulator", "focus": False})
        except Failure as failure:
            created, error = None, str(failure)
        time.sleep(1.0)
        closed = self.close_local_simulators_in_mirror()
        if closed or error is None:
            raise Failure(f"surface.create made a local simulator in the mirror: {created} (closed {closed})")
        return {"error": error}

    def new_simulator_runs_on_owner(self) -> Dict[str, Any]:
        self.need_udid()
        try:
            executed = self.new_simulator("configured")
            return {"executed": executed, **self.one_viewer_on_owner()}
        finally:
            closed = self.close_local_simulators_in_mirror()
            if closed:
                self.facts.setdefault("closed_local_mirror_simulators", []).extend(closed)

    def build_booted_simulator_shows_up(self) -> Dict[str, Any]:
        udid = self.need_udid()

        def shows_udid() -> Optional[Dict[str, Any]]:
            viewer = self.need_viewer(include_devices=True)
            selected = up((viewer.get("binding") or {}).get("udid"))
            if selected != udid:
                raise Failure(f"viewer udid {selected or None} != {udid}")
            return viewer

        try:
            viewer = wait_for("the viewer to show the device the mirror terminal booted", shows_udid, 60, interval_s=2.0)
        except Failure:
            first_pick = newest_booted_phone_or_tablet()
            if first_pick and first_pick != udid:
                # Another simulator outranks ours; show ours so later steps act on it.
                self.select_and_follow(udid, 120)
                raise Skipped(f"another booted simulator ({first_pick}) is the owning Mac's first pick, not {udid}")
            raise
        return {"binding": viewer.get("binding")}

    def streams_video(self) -> Dict[str, Any]:
        start = int(self.need_viewer().get("presented_frames") or 0)
        viewer = self.wait_streaming(start, 10, 45)
        config = viewer.get("config") or {}
        problems = []
        if config.get("codec") not in ("hevc", "h264"):
            problems.append(f"codec {config.get('codec')}")
        if max(int(config.get("width") or 0), int(config.get("height") or 0)) > 2000 or not config.get("width"):
            problems.append(f"size {config.get('width')}x{config.get('height')}")
        workers = wait_for("one simulator worker more than before",
                           lambda: self.workers() == self.baseline_workers + 1 and self.workers(), 15)
        shot = self.screenshot("viewer")
        if problems:
            raise Failure("; ".join(problems) + f"; viewer={json.dumps(viewer)}")
        return {"frames": viewer.get("presented_frames"), "config": config, "workers": workers,
                "quality": viewer.get("quality"), "screenshot": shot}

    def device_picker_lists_owner_devices(self) -> Dict[str, Any]:
        udid = self.need_udid()
        listed = sorted(up(d.get("udid")) for d in self.need_viewer(include_devices=True).get("devices") or [])
        expected = available_phone_and_tablet_udids()
        if listed != expected:
            raise Failure(f"picker {listed} != the owner's available iPhone/iPad simulators {expected}")
        other = self.create_device(f"supermux-e2e-{self.args.tag or 'socket'}-{self.nonce}-b")
        self.need_viewer(include_devices=True)  # the picker reloads the owner's list
        switched = self.select_and_follow(other, 240)
        back = self.select_and_follow(udid, 60)
        simctl("shutdown", other, check=False)
        return {"picker": listed, "other_device": other, "switched": switched, "back": back}

    def host_device(self, state: Optional[Dict[str, Any]] = None) -> Optional[str]:
        """The device the source's (one) Simulator tab shows on the owning Mac."""
        panels = self.panels(self.source, "local", state)
        if len(panels) != 1:
            return None
        return up(panels[0].get("selected_device_id")) or None

    def select_and_follow(self, udid: str, timeout_s: float) -> Dict[str, Any]:
        """Picks `udid` in the viewer: the owning Mac's Simulator tab switches to
        it, and the viewer then plays frames that device draws. (A device of the
        same size brings no new config, so frames are the evidence.)"""
        self.viewer_call("select_device", {"udid": udid})
        switched: Dict[str, int] = {}

        def followed() -> Optional[Dict[str, Any]]:
            state = self.sim_state()
            viewers = self.panels(self.mirror, "viewer", state)
            if not viewers:
                raise Failure("precondition: the mirror holds no simulator viewer tab")
            viewer = viewers[0]
            frames = int(viewer.get("presented_frames") or 0)
            selected = up((viewer.get("binding") or {}).get("udid"))
            host = self.host_device(state)
            if host == udid and selected == udid and "frames" not in switched:
                switched["frames"] = frames
            if "frames" not in switched or viewer.get("phase") != "streaming" or frames < switched["frames"] + 3:
                self.stir_device(udid)
                raise Failure(f"owner shows {host}, viewer udid={selected} phase={viewer.get('phase')} "
                              f"frames={frames} (at the switch: {switched.get('frames')})")
            return viewer

        viewer = wait_for(f"the stream to follow the picker to {udid}", followed, timeout_s, interval_s=2.0)
        return {"udid": udid, "config": viewer.get("config"), "configs_applied": viewer.get("configs_applied"),
                "frames_at_switch": switched.get("frames"), "frames": viewer.get("presented_frames")}

    def show_suite_device(self) -> Optional[str]:
        """A new Simulator tab shows the owning Mac's first pick. When that is
        another booted simulator (an idle one the suite never stirs, which may
        draw nothing), switch the viewer to the suite's own device so the checks
        that follow act on it. Returns the device it switched away from."""
        udid = self.need_udid()
        shown = wait_for("the owner's Simulator tab to pick a device", self.host_device, self.timeout)
        if shown == udid:
            return None
        self.need_viewer(include_devices=True)  # the picker loads the owner's list
        self.select_and_follow(udid, 120)
        return shown

    def stir_device(self, udid: str) -> None:
        if device_state(udid) == "Booted":
            simctl("ui", udid, "appearance", "dark", check=False)
            simctl("ui", udid, "appearance", "light", check=False)

    def home_button_reaches_owner(self) -> Dict[str, Any]:
        udid = self.need_udid()
        self.need_viewer()
        host = self.host_panel()
        simctl("launch", udid, "com.apple.Preferences")
        evidence: Dict[str, Any] = {}
        try:
            wait_for("Settings in front", lambda: self.foreground(host) == "com.apple.Preferences", 15, interval_s=1.0)
            evidence["before"] = "com.apple.Preferences"
            uses_foreground = True
        except Failure as error:
            evidence["foreground_error"] = str(error)
            uses_foreground = False
        before_hash = screenshot_hash(udid)
        wait_for("the viewer to take Home", lambda: self.sock.call(
            SIM + "input", {"panel_id": self.need_viewer()["panel_id"], "event": {"button": "home"}}
        ).get("accepted"), 15, interval_s=1.0)
        if uses_foreground:
            wait_for("SpringBoard in front after the viewer's Home",
                     lambda: self.foreground(host) == "com.apple.springboard", 10, interval_s=0.5)
            evidence["after"] = "com.apple.springboard"
        else:
            wait_for("the owner's screen to change after the viewer's Home",
                     lambda: screenshot_hash(udid) not in (None, before_hash), 10, interval_s=1.0)
            evidence["screen_changed"] = True
        return evidence

    def rotate_via_control(self) -> Dict[str, Any]:
        self.need_viewer()
        host = self.host_panel()
        start = str(self.host_context(host).get("orientation") or "portrait")
        self.viewer_call("control", {"action": "rotate_left"})
        turned = wait_for("the owner's simulator to turn to landscape",
                          lambda: str(self.host_context(host).get("orientation") or "").startswith("landscape")
                          and self.host_context(host).get("orientation"), 10, interval_s=0.5)
        self.stir()
        time.sleep(1.5)
        viewer_config = self.need_viewer().get("config") or {}
        self.viewer_call("control", {"action": "rotate_right"})
        back = wait_for("the owner's simulator to turn back",
                        lambda: self.host_context(host).get("orientation") == start, 10, interval_s=0.5)
        return {"start": start, "turned": turned, "back": back, "viewer_config_while_turned": viewer_config}

    def quality_cap(self) -> Dict[str, Any]:
        self.viewer_call("quality", {"preset": "dataSaver"})

        def capped() -> Optional[Dict[str, Any]]:
            viewer = self.need_viewer()
            config = viewer.get("config") or {}
            long_side = max(int(config.get("width") or 0), int(config.get("height") or 0))
            if not long_side or long_side > 800:
                self.stir()
                raise Failure(f"config {config} quality={viewer.get('quality')}")
            return {"config": config, "quality": viewer.get("quality")}

        try:
            return wait_for("a config with a long side <= 800", capped, 20, interval_s=1.0)
        finally:
            self.viewer_call("quality", {"preset": "auto"})

    def pane_count(self, workspace_id: str) -> int:
        """The workspace's own panes (pane.list also lists the window's Dock pane)."""
        panes = (self.sock.call("pane.list", {"workspace_id": workspace_id}) or {}).get("panes") or []
        return len([pane for pane in panes if not pane.get("dock_scope")])

    def layout_follows_with_simulator(self) -> Dict[str, Any]:
        self.need_viewer()
        source_panes = self.pane_count(self.source)
        terminal = self.terminals(self.source)[0]
        split = self.sock.call("surface.split", {"workspace_id": self.source, "surface_id": terminal,
                                                 "direction": "right"}) or {}
        self.split_terminal = up(split.get("surface_id"))
        if not self.split_terminal:
            raise Failure(f"surface.split returned no surface: {split}")
        problems = []
        try:
            wait_for("the source's new split in the mirror",
                     lambda: self.split_terminal in self.projected_sources().values(), 15)
            # The split itself, not only the new terminal (an apply the viewer
            # blocks would leave it as a tab of the old pane).
            wait_for("the mirror to split like the source",
                     lambda: self.pane_count(self.source) == source_panes + 1
                     and self.pane_count(self.mirror) == source_panes + 1, 15)
        except Failure as error:
            problems.append(f"{error} (panes before the split: {source_panes}; now source "
                            f"{self.pane_count(self.source)}, mirror {self.pane_count(self.mirror)})")
        title = f"mirror-simulator-renamed-{self.nonce}"
        self.sock.call("workspace.rename", {"workspace_id": self.source, "title": title})
        try:
            wait_for("the mirror to take the source's new name",
                     lambda: (self.local_workspaces().get(self.mirror) or {}).get("title") == title, 15)
        except Failure as error:
            problems.append(str(error))
        if problems:
            raise Failure("; ".join(problems))
        return {"split_terminal": self.split_terminal, "title": title, "panes_before": source_panes,
                "panes_after": self.pane_count(self.mirror)}

    def close_mirror_terminal_with_viewer_open(self) -> Dict[str, Any]:
        self.need_viewer()
        if not self.split_terminal:
            raise Failure("precondition: step 13 made no split terminal")
        mirror_panel = next((panel for panel, source in self.projected_sources().items()
                             if source == self.split_terminal), None)
        if not mirror_panel:
            raise Failure("the split terminal has no mirror tab")
        self.sock.call("surface.close", {"workspace_id": self.mirror, "surface_id": mirror_panel, "force": True})
        wait_for("the source terminal to close with its mirror tab",
                 lambda: self.split_terminal not in self.terminals(self.source), 15)
        return {"closed_mirror_panel": mirror_panel, "closed_source_terminal": self.split_terminal,
                "viewer_still_open": self.viewer() is not None}

    def link_drop_reconnects(self) -> Dict[str, Any]:
        self.need_viewer()
        self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        try:
            dropped = wait_for("the viewer to stop streaming with the link down",
                               lambda: self.need_viewer().get("phase") != "streaming" and self.need_viewer(), 15)
        finally:
            self.sock.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        frames = int(self.need_viewer().get("presented_frames") or 0)
        viewer = self.wait_streaming(frames, 3, 45)
        return {"while_down": {"phase": dropped.get("phase"), "frames": dropped.get("presented_frames")},
                "after": {"phase": viewer.get("phase"), "frames": viewer.get("presented_frames")}}

    def superseded_no_ping_pong(self) -> Dict[str, Any]:
        self.need_viewer()
        host = self.host_panel()
        self.sock.call(SIM + "steal", {"host_panel_id": host})

        def superseded() -> Optional[Dict[str, Any]]:
            viewer = self.need_viewer()
            if viewer.get("phase") != "unavailable" or viewer.get("phase_detail") != "superseded":
                raise Failure(f"phase={viewer.get('phase')} detail={viewer.get('phase_detail')}")
            return viewer

        first = wait_for("the viewer to step aside for the other viewer", superseded, 15)
        time.sleep(10)
        later = self.need_viewer()
        if later.get("phase") != "unavailable" or int(later.get("presented_frames") or 0) != int(first.get("presented_frames") or 0):
            raise Failure(f"the viewer took the stream back on its own: {later}")
        self.viewer_call("show_here", {})
        viewer = self.wait_streaming(int(later.get("presented_frames") or 0), 3, 30)
        return {"superseded_frames": first.get("presented_frames"), "after_show_here": viewer.get("presented_frames")}

    def owner_close_closes_viewer(self) -> Dict[str, Any]:
        self.need_viewer()
        host = self.host_panel()
        self.sock.call("surface.close", {"workspace_id": self.source, "surface_id": host, "force": True})
        wait_for("the viewer tab to close with the owner's Simulator tab", lambda: self.viewer() is None, 20)
        return {"closed_host_panel": host}

    def viewer_close_closes_owner_panel(self) -> Dict[str, Any]:
        udid = self.need_udid()
        try:
            self.new_simulator("configured")
            opened = self.one_viewer_on_owner()
        finally:
            self.close_local_simulators_in_mirror()
        first_pick = self.show_suite_device()
        self.wait_streaming(0, 1, 45)
        viewer = self.need_viewer()
        self.sock.call("surface.close", {"workspace_id": self.mirror, "surface_id": viewer["panel_id"], "force": True})
        wait_for("the owner's Simulator tab to close with the viewer tab",
                 lambda: not self.panels(self.source, "local"), 15)
        wait_for("its simulator worker to exit", lambda: self.workers() == self.baseline_workers, 20)
        state = device_state(udid)
        if state != "Booted":
            raise Failure(f"closing the viewer left the device {state}, expected Booted")
        return {"host_panel_id": opened["host_panel_id"], "device_state": state, "switched_from": first_pick}

    def new_simulator_tab_bar_runs_on_owner(self) -> Dict[str, Any]:
        self.need_udid()
        try:
            executed = self.new_simulator("tab_bar")
            return {"executed": executed, **self.one_viewer_on_owner()}
        finally:
            self.close_local_simulators_in_mirror()

    def slow_simctl_lists_and_streams(self) -> Dict[str, Any]:
        """A slow `simctl` on the owning Mac (every launch stalled 20-22 s in dyld, 2026-10-03) left the picker
        empty (`mobile.simulator.devices.list` ran a fresh `simctl list` and missed the link's 20 s reply
        deadline) and a new Simulator tab never picked a device. With the app's `simctl` spawns slowed past
        that deadline, a new tab's picker must still list the owner's devices and the tab must stream."""
        udid = self.need_udid()
        for viewer in self.panels(self.mirror, "viewer"):
            self.sock.call("surface.close", {"workspace_id": self.mirror, "surface_id": viewer["panel_id"], "force": True})
        wait_for("no Simulator tab on the owner before the step", lambda: not self.panels(self.source, "local"), 20)
        delay = max(SLOW_SIMCTL_SECONDS, self.args.slow_simctl or 0)
        previous = self.set_simctl_delay(delay)
        started = time.monotonic()
        try:
            try:
                self.new_simulator("configured")
                opened = self.one_viewer_on_owner()
            finally:
                self.close_local_simulators_in_mirror()
            expected = available_phone_and_tablet_udids()

            def listed() -> Optional[List[str]]:
                devices = self.need_viewer(include_devices=True).get("devices") or []
                got = sorted(up(d.get("udid")) for d in devices)
                if got != expected:
                    raise Failure(f"picker {got} != the owner's available iPhone/iPad simulators {expected}")
                return got

            picker = wait_for("the picker to list the owner's devices with simctl slow", listed, 30, interval_s=1.0)
            picker_seconds = round(time.monotonic() - started, 1)
            shown = wait_for("the owner's new Simulator tab to pick a device with simctl slow", self.host_device, 15)
            picked_seconds = round(time.monotonic() - started, 1)
            if shown != udid:
                self.select_and_follow(udid, 90)
            viewer = self.wait_streaming(0, 3, 45)
            return {"simctl_delay_s": delay, "host_panel_id": opened["host_panel_id"], "picker": picker,
                    "picker_s": picker_seconds, "device_picked_s": picked_seconds, "first_pick": shown,
                    "streaming_s": round(time.monotonic() - started, 1), "frames": viewer.get("presented_frames")}
        finally:
            self.set_simctl_delay(previous)

    def slow_simctl_device_menu_says_so(self) -> Dict[str, Any]:
        """Where the owner can only ask `simctl` (CoreSimulator unusable there) and `simctl` is slow, its answer
        to the device menu still comes well inside the link's 20 s reply deadline, says the list may be out of
        date (`slow`; the menu says "Simulators on <Mac> are slow to respond…" instead of coming up empty), and
        the viewer asks again until the owner's refresh lands."""
        self.need_viewer()
        delay = max(SLOW_SIMCTL_SECONDS, self.args.slow_simctl or 0)
        previous = self.set_simctl_delay(delay, coresimulator=False)
        started = time.monotonic()
        try:
            asked = time.monotonic()
            first = self.need_viewer(include_devices=True)
            answer_seconds = round(time.monotonic() - asked, 1)
            if answer_seconds > 15 or first.get("devices_slow") is not True:
                raise Failure(f"the device menu took {answer_seconds}s and devices_slow={first.get('devices_slow')} "
                              f"(want an answer well inside the 20 s deadline, marked slow): {first.get('devices')}")

            def current() -> Optional[Dict[str, Any]]:
                viewer = self.need_viewer()
                if viewer.get("devices_slow") is not False:
                    raise Failure(f"devices_slow={viewer.get('devices_slow')}")
                return viewer

            # Two `simctl list` launches at `delay` each, then the viewer's next retry.
            wait_for("the viewer's retry to get the owner's current list", current, 2 * delay + 40, interval_s=2.0)
            expected = available_phone_and_tablet_udids()
            listed = sorted(up(d.get("udid")) for d in self.need_viewer(include_devices=True).get("devices") or [])
            if listed != expected:
                raise Failure(f"picker {listed} != the owner's available iPhone/iPad simulators {expected}")
            return {"simctl_delay_s": delay, "first_answer_s": answer_seconds,
                    "first_devices": len(first.get("devices") or []),
                    "current_after_s": round(time.monotonic() - started, 1), "picker": listed}
        finally:
            self.set_simctl_delay(previous)

    def restore_rebinds(self) -> Dict[str, Any]:
        if not self.args.app_path:
            raise Skipped("pass --app-path to quit and relaunch")
        self.need_viewer()
        first_pick = self.show_suite_device()  # the restored stream shows a device the suite stirs
        self.sock.call("workspace.select", {"workspace_id": self.mirror})
        time.sleep(2.0)  # let the session autosave see the viewer
        self.relaunch()
        wait_for("the loopback device to reconnect after the relaunch",
                 lambda: self.device().get("link_state") == "connected" and self.device().get("has_fetched_records"),
                 60)
        self.mirror = up(wait_for("the restored mirror", lambda: (self.mirrors_of(self.source) or [None])[0],
                                  60)["workspace_id"])
        self.sock.call("workspace.select", {"workspace_id": self.mirror})
        wait_for("the restored viewer tab", lambda: self.viewer() is not None, 60)
        viewer = self.wait_streaming(0, 3, 90)
        settled = self.one_viewer_on_owner()
        quit_error = self.facts.get("quit_error")
        if quit_error:
            # The app quit, but a script quitting it would have stopped on this error.
            raise Failure(f"the app quit, but `tell application id … to quit` reported an error: {quit_error}")
        return {"mirror": self.mirror, "frames": viewer.get("presented_frames"),
                "host_panel_id": settled["host_panel_id"], "switched_from": first_pick,
                "quit_seconds": self.facts.get("quit_seconds")}

    @staticmethod
    def worker_pids(app_pid: int) -> List[int]:
        """The simulator worker processes `app_pid` started (its direct children)."""
        listing = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
        pids = []
        for line in listing.splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3 and int(parts[1]) == app_pid and WORKER_ARGUMENT in parts[2]:
                pids.append(int(parts[0]))
        return sorted(pids)

    @staticmethod
    def pid_alive(pid: int) -> bool:
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def relaunch(self) -> None:
        app = self.args.app_path
        bundle_id = plistlib.loads((Path(app) / "Contents" / "Info.plist").read_bytes())["CFBundleIdentifier"]
        app_pid = int(self.sim_state().get("app_pid") or 0)
        workers_before = self.worker_pids(app_pid)
        self.sock.close()
        # The way a script or launcher quits an app: an Apple Event to its bundle id.
        quit_request = subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to quit'],
                                      check=False, capture_output=True, text=True)
        asked = time.monotonic()
        try:
            wait_for("the app to quit", lambda: not self.pid_alive(app_pid), 60, interval_s=0.5)
        except Failure:
            workers_after = self.worker_pids(app_pid)
            gone = sorted(set(workers_before) - set(workers_after))
            raise Failure(
                f"the app (pid {app_pid}) did not quit within 60s of `tell application id \"{bundle_id}\" to quit` "
                f"(osascript exit {quit_request.returncode} {quit_request.stderr.strip()[:120]}); its simulator "
                f"workers before the quit {workers_before}, after {workers_after}"
                + (f": the quit went to worker {gone}, which exited (the app started another), not to the app"
                   if gone else ""))
        self.facts["quit_seconds"] = round(time.monotonic() - asked, 2)
        if quit_request.returncode != 0:
            self.facts["quit_error"] = f"osascript exit {quit_request.returncode}: {quit_request.stderr.strip()[:200]}"

        def quit_done() -> bool:
            result = subprocess.run(["osascript", "-e", f'application id "{bundle_id}" is running'],
                                    check=False, capture_output=True, text=True)
            return result.stdout.strip() != "true"

        # Its workers share the bundle id: `open` would reuse a lingering one.
        wait_for("the app's workers to exit with it", quit_done, 15, interval_s=0.5)
        env_args = ["--env", "SUPERMUX_DEBUG_LOOPBACK_DEVICE=1"]
        if self.args.projects_file:
            env_args += ["--env", f"SUPERMUX_PROJECTS_FILE={self.args.projects_file}"]
        if self.args.slow_simctl:
            env_args += ["--env", f"{SIMCTL_DELAY_ENV}={self.args.slow_simctl}"]
        subprocess.run(["open", "-g", *env_args, app], check=True)

        def socket_alive() -> bool:
            probe = Socket(self.sock.path, timeout_s=3)
            try:
                probe.connect()
                probe.call("supermux.devices.list", {})
                return True
            except (OSError, Failure):
                return False
            finally:
                probe.close()

        wait_for("the relaunched app's socket", socket_alive, 60, interval_s=0.5)
        self.sock.connect()

    def screenshot(self, label: str) -> Optional[str]:
        """Best effort: keeps a window screenshot of the mirror next to the report."""
        try:
            self.sock.call("workspace.select", {"workspace_id": self.mirror})
            time.sleep(1.0)
            shot = self.sock.call("debug.window.screenshot", {"label": f"mirror-simulator-{label}"}) or {}
        except Failure as error:
            self.facts.setdefault("screenshot_errors", []).append(str(error))
            return None
        path = str(shot.get("path") or "")
        if not path or not Path(path).exists():
            return None
        kept = self.report_path.with_suffix("").as_posix() + f"-{label}.png"
        shutil.copyfile(path, kept)
        return kept

    def need_udid(self) -> str:
        if not self.udid:
            raise Failure("precondition: no simulator device")
        return self.udid

    # -- run ------------------------------------------------------------------

    def cleanup(self) -> None:
        if not self.args.keep:
            try:
                if not self.sock.connected:  # a relaunch that failed left it closed
                    self.sock.connect()
                self.close_test_workspaces()
            except (Failure, OSError) as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))
        if not self.args.keep_device:
            for udid in self.created_udids:
                simctl("shutdown", udid, check=False)
                simctl("delete", udid, check=False)
            self.facts["deleted_devices"] = self.created_udids

    def close_test_workspaces(self) -> None:
        try:
            state = self.sim_state()
            for kind in ("viewer", "local"):
                for panel in self.panels(self.mirror, kind, state):
                    self.sock.call("surface.close", {"workspace_id": self.mirror, "surface_id": panel["panel_id"],
                                                     "force": True})
        except Failure as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))
        for workspace_id in (self.mirror, self.source):
            if not workspace_id:
                continue
            try:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except Failure as error:
                if "not_found" not in str(error):
                    self.facts.setdefault("cleanup_errors", []).append(str(error))

    def run(self) -> bool:
        ok = self.step("setup", self.setup, needs_simulator=False)
        ok = ok and self.step("source_and_mirror", self.source_and_mirror, needs_simulator=False)
        if ok:
            self.step("simulator_device", self.simulator_device, needs_simulator=False)
            for name, check in [
                ("boot_from_mirror_terminal", self.boot_from_mirror_terminal),
                ("socket_create_in_mirror_never_local", self.socket_create_in_mirror_never_local),
                ("new_simulator_runs_on_owner", self.new_simulator_runs_on_owner),
                ("build_booted_simulator_shows_up", self.build_booted_simulator_shows_up),
                ("streams_video", self.streams_video),
                ("device_picker_lists_owner_devices", self.device_picker_lists_owner_devices),
                ("home_button_reaches_owner", self.home_button_reaches_owner),
                ("rotate_via_control", self.rotate_via_control),
                ("quality_cap", self.quality_cap),
                ("layout_follows_with_simulator", self.layout_follows_with_simulator),
                ("close_mirror_terminal_with_viewer_open", self.close_mirror_terminal_with_viewer_open),
                ("link_drop_reconnects", self.link_drop_reconnects),
                ("superseded_no_ping_pong", self.superseded_no_ping_pong),
                ("owner_close_closes_viewer", self.owner_close_closes_viewer),
                ("viewer_close_closes_owner_panel", self.viewer_close_closes_owner_panel),
                ("new_simulator_tab_bar_runs_on_owner", self.new_simulator_tab_bar_runs_on_owner),
                ("slow_simctl_lists_and_streams", self.slow_simctl_lists_and_streams),
                ("slow_simctl_device_menu_says_so", self.slow_simctl_device_menu_says_so),
                ("restore_rebinds", self.restore_rebinds),
            ]:
                ok = self.step(name, check) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait before a check gives up")
    parser.add_argument("--keep", action="store_true", help="leave the test workspaces open")
    parser.add_argument("--udid", help="use this existing simulator instead of creating one (never deleted)")
    parser.add_argument("--keep-device", action="store_true", help="do not delete the simulators this suite created")
    parser.add_argument("--app-path", help="the tagged .app to quit and relaunch for the restore check")
    parser.add_argument("--projects-file", help="SUPERMUX_PROJECTS_FILE to relaunch with")
    parser.add_argument("--report", help="report path")
    parser.add_argument("--slow-simctl", type=float, default=float(os.environ.get("CMUX_E2E_SLOW_SIMCTL") or 0),
                        help="seconds every simctl spawn of the app waits, for the whole run (DEBUG hook)")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    path = args.socket or socket_path_for_tag(args.tag)
    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_mirror_simulator_e2e-{args.tag or 'socket'}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = MirrorSimulatorE2E(sock, args, report_path)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-mirror-simulator-e2e",
        "tag": args.tag,
        "socket": path,
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
