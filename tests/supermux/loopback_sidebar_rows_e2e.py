#!/usr/bin/env python3
"""End-to-end test of the sidebar rows that show other Macs' workspaces (device
mirrors), against one tagged DEBUG build running the loopback device.

The loopback device ("Loopback Mac") is this same app's own mobile host, so
every local workspace also has a mirror. `supermux.devices.sidebar_rows`
reports the rows exactly as the sidebar builds them (the Projects section's
nested rows in display order, and the flat list's row snapshots). Checks:

  1. setup                               the loopback linked and fetched, auto-mirror on
  2. project_with_local_and_mirror_rows  a scratch project with two local worktree
                                         workspaces, each with its mirror nested under it
  3. nested_rows_local_first             inside the project, this Mac's rows come first
                                         (in their own order), then each Mac's mirrors
                                         grouped, even when a mirror is moved to the top
  4. nested_mirror_label_names_mac       a nested mirror's accessibility label says which
                                         Mac it is on; a local row's label is its title
  5. nested_mirror_icon_before_branch    a nested mirror marks its Mac with the small Mac +
                                         cloud icon (no name chip) right before its branch,
                                         its tooltip "On <Mac>"; a local row draws none
  6. nested_rows_show_no_status          `set_status` / `set_progress` on a local workspace,
                                         including Claude's lifecycle-less "Idle" pill, show
                                         on neither its nested row nor its mirror's (as on
                                         main); both rows still report their activity
  7. working_spinner_stays_small         with the source's agent working, the amber spinner
                                         of its nested row and of its mirror's is the 6·scale
                                         one (pixel-measured in a window screenshot, kept
                                         next to the report)
  8. flat_mirror_subtitle_omits_mac      a flat mirror's directory line does not repeat the
                                         Mac name (its icon's tooltip names it), and its Mac
                                         icon sits on that line

Writes a JSON report (default tests/supermux/artifacts/loopback_sidebar_rows_e2e-<tag>.json)
and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_sidebar_rows_e2e.py [--scratch /tmp/<tag>/rows] [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_auto_mirror_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    LOOPBACK_DEVICE_ID,
    Failure,
    Socket,
    socket_path_for_tag,
    up,
    wait_for,
)
from loopback_mirror_render_e2e import decode_png  # noqa: E402

# The glyph that marks a row living on another Mac (with a small cloud badge).
MAC_ICON_SYMBOL = "laptopcomputer"
ACTIVITIES = {"idle", "working", "needsInput", "ready"}
# The working spinner's braille dots at the rows' 6·scale size are at most 4pt
# wide and 6.5pt tall; at the oversized 10·scale they were 6pt wide or 10.5pt
# tall in every frame. Limits sit between (times the sidebar font scale).
SPINNER_MAX_WIDTH_PT = 5.0
SPINNER_MAX_HEIGHT_PT = 8.5
# How far left of the terminal pane the spinners are searched for: the
# sidebar's trailing edge, where every row draws its spinner (clear of the
# project avatars on the left).
SPINNER_BAND_PT = 70


def git(*args: str, cwd: Path) -> None:
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise Failure(f"git {' '.join(args)}: {result.stderr.strip()}")


def is_amber(pixel: bytes) -> bool:
    """The spinner's amber (Tailwind amber-500): pixels at least about a third
    covered by it, on the dark or the light sidebar. A 1x display (a headless
    Mac's virtual screen) draws the 6pt ring mostly as partly covered pixels."""
    red, green, blue = pixel[0], pixel[1], pixel[2]
    return red >= 90 and red - blue >= 60 and 0.45 * red <= green <= 0.8 * red


def amber_marks(path: str, left_pt: float, width_pt: float, window_width_pt: float) -> Tuple[List[Dict[str, Any]], float]:
    """Amber marks in a full-height strip of a window screenshot (points from
    the window's left edge), one per sidebar row: amber pixels closer than 6pt
    vertically belong to the same mark. Sizes in points; also returns the
    screenshot's pixels per point."""
    png_width, png_height, bpp, rows = decode_png(path)
    scale = png_width / window_width_pt
    left, right = max(0, int(left_pt * scale)), min(png_width, int((left_pt + width_pt) * scale))
    marks: List[Dict[str, int]] = []
    for y in range(png_height):
        row = rows[y]
        for x in range(left, right):
            if not is_amber(row[x * bpp:x * bpp + 3]):
                continue
            if marks and y - marks[-1]["bottom"] <= 6 * scale:
                mark = marks[-1]
                mark["bottom"], mark["pixels"] = y, mark["pixels"] + 1
                mark["left"], mark["right"] = min(mark["left"], x), max(mark["right"], x)
            else:
                marks.append({"top": y, "bottom": y, "left": x, "right": x, "pixels": 1})
    return [{
        "y_pt": round(mark["top"] / scale, 1),
        "width_pt": round((mark["right"] - mark["left"] + 1) / scale, 2),
        "height_pt": round((mark["bottom"] - mark["top"] + 1) / scale, 2),
        "pixels": mark["pixels"],
    } for mark in marks], scale


class SidebarRowsE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.root = Path(args.scratch) / f"rows-{self.nonce}"
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "scratch": str(self.root)}
        self.machine = ""
        self.mac_name = ""
        self.project_id = ""
        self.locals: List[str] = []
        self.mirrors: Dict[str, str] = {}
        self.created: List[str] = []
        self.initial_auto_mirror: Optional[bool] = None

    # -- reads and actions ----------------------------------------------------

    def request(self, method: str, params: Dict[str, Any], timeout_s: float = 120) -> Dict[str, Any]:
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

    def mirror_of(self, source_id: str) -> Optional[str]:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        found = [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(source_id)]
        if len(found) > 1:
            raise Failure(f"{len(found)} mirrors of {source_id}")
        return up(found[0].get("workspace_id")) if found else None

    def rows(self) -> Dict[str, Any]:
        return self.sock.call("supermux.devices.sidebar_rows", {}) or {}

    def project_rows(self) -> List[Dict[str, Any]]:
        for project in self.rows().get("projects") or []:
            if up(project.get("project_id")) == up(self.project_id):
                return project.get("rows") or []
        return []

    def row(self, workspace_id: str) -> Optional[Dict[str, Any]]:
        return next((r for r in self.project_rows() if up(r.get("workspace_id")) == up(workspace_id)), None)

    def terminal(self, workspace_id: str) -> str:
        surfaces = (self.sock.call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
        terminals = [s["id"] for s in surfaces if s.get("type") == "terminal"]
        return str(terminals[0]) if terminals else ""

    def mirror_status(self, source_id: str) -> Dict[str, Any]:
        rows = (self.sock.call("supermux.devices.bindings", {}) or {}).get("mirrors") or []
        found = [m for m in rows if m.get("machine") == self.machine and up(m.get("remote_workspace_id")) == up(source_id)]
        return (found[0].get("status") or {}) if found else {}

    def sidebar_spinners(self) -> Dict[str, Any]:
        """Screenshots the window and measures the amber marks along the
        sidebar's trailing edge (just left of the leftmost terminal pane)."""
        panes = [t for t in (self.sock.call("debug.terminals", {}) or {}).get("terminals") or []
                 if t.get("hosted_view_in_window") and (t.get("hosted_view_frame_in_window") or {}).get("width", 0) > 1]
        if not panes:
            raise Failure("no terminal pane in the window to find the sidebar's edge by")
        edge = min(p["hosted_view_frame_in_window"]["x"] for p in panes)
        window = panes[0].get("window_frame") or {}
        if edge < SPINNER_BAND_PT or not window.get("width") or not window.get("height"):
            raise Failure(f"the sidebar is hidden or too narrow (pane x={edge}, window={window})")
        shot = self.sock.call("debug.window.screenshot", {"label": "sidebar-rows-spinner"}) or {}
        path = str(shot.get("path") or "")
        if not path:
            raise Failure(f"debug.window.screenshot returned no path: {shot}")
        marks, scale = amber_marks(path, edge - SPINNER_BAND_PT, SPINNER_BAND_PT - 1, window["width"])
        kept = Path(self.args.report_path).with_suffix("").as_posix() + "-spinner.png"
        Path(kept).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, kept)
        return {"marks": marks, "screenshot": kept, "pixel_scale": round(scale, 2), "sidebar_edge_pt": edge}

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
        self.mac_name = device.get("name") or ""
        state = self.sock.call("supermux.devices.remote_macs_settings", {}) or {}
        self.initial_auto_mirror = state.get("auto_mirror")
        if not self.initial_auto_mirror:
            self.sock.call("supermux.devices.set_auto_mirror", {"enabled": True})
        return {"machine": self.machine, "mac_name": self.mac_name}

    def project_with_rows(self) -> Dict[str, Any]:
        repo = self.root / "repo"
        repo.mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=repo)
        git("-c", "user.email=e2e@example.com", "-c", "user.name=Supermux E2E", "commit", "-q", "--allow-empty", "-m", "init", cwd=repo)
        project = self.request("mobile.supermux.project.create", {"root_path": str(repo)}).get("project") or {}
        self.project_id = up(project.get("id"))
        if not self.project_id:
            raise Failure(f"project.create returned no project: {project}")
        for label in ("alpha", "beta"):
            created = self.request("mobile.supermux.worktree.create", {
                "project_id": self.project_id,
                "workspace_name": f"rows-{label}-{self.nonce}",
                "branch_name": f"rows-{label}-{self.nonce}",
                "open": True,
            }, timeout_s=180)
            workspace_id = up(created.get("workspace_id"))
            if not workspace_id:
                raise Failure(f"worktree.create returned no workspace: {created}")
            self.locals.append(workspace_id)
            self.created.append(workspace_id)
            self.mirrors[workspace_id] = wait_for(f"the {label} mirror", lambda: self.mirror_of(workspace_id), self.timeout)

        def nested() -> Optional[List[Dict[str, Any]]]:
            ids = {up(r.get("workspace_id")) for r in self.project_rows()}
            wanted = set(self.locals) | set(self.mirrors.values())
            return self.project_rows() if wanted <= ids else None

        rows = wait_for("all four rows to nest under the project", nested, self.timeout)
        return {"project_id": self.project_id, "locals": self.locals, "mirrors": self.mirrors, "rows": len(rows)}

    def nested_rows_local_first(self) -> Dict[str, Any]:
        # Put a mirror first in the window's tab order: the nested rows must
        # still list this Mac's workspaces first.
        first_mirror = self.mirrors[self.locals[0]]
        self.sock.call("workspace.reorder", {"workspace_id": first_mirror, "index": 0})

        def ordered() -> Optional[List[str]]:
            rows = self.project_rows()
            ours = [r for r in rows if up(r.get("workspace_id")) in set(self.locals) | set(self.mirrors.values())]
            if len(ours) != 4:
                return None
            kinds = ["mirror" if r.get("device_name") else "local" for r in ours]
            if kinds != ["local", "local", "mirror", "mirror"]:
                raise Failure(f"row order {[(r.get('title'), r.get('device_name')) for r in ours]}")
            return [up(r.get("workspace_id")) for r in ours]

        order = wait_for("local rows before the mirrors", ordered, self.timeout)
        tabs = [up(w.get("id") or w.get("workspace_id")) for w in (self.sock.call("workspace.list", {}) or {}).get("workspaces") or []]
        locals_in_tab_order = [w for w in tabs if w in self.locals]
        if order[:2] != locals_in_tab_order:
            raise Failure(f"local rows {order[:2]} are not in tab order {locals_in_tab_order}")
        return {"order": order}

    def nested_mirror_label_names_mac(self) -> Dict[str, Any]:
        mirror = self.row(self.mirrors[self.locals[0]]) or {}
        local = self.row(self.locals[0]) or {}
        label = mirror.get("accessibility_label") or ""
        if self.mac_name not in label:
            raise Failure(f"the mirror's label {label!r} does not name {self.mac_name!r}")
        if local.get("accessibility_label") != local.get("title"):
            raise Failure(f"the local row's label {local.get('accessibility_label')!r} is not its title {local.get('title')!r}")
        return {"mirror_label": label, "local_label": local.get("accessibility_label")}

    def nested_mirror_icon_before_branch(self) -> Dict[str, Any]:
        source = self.locals[0]

        def mirror_with_branch() -> Optional[Dict[str, Any]]:
            row = self.row(self.mirrors[source]) or {}
            return row if row.get("branch") else None

        mirror = wait_for("the nested mirror's branch", mirror_with_branch, self.timeout)
        local = self.row(source) or {}
        icon = mirror.get("device_icon") or {}
        expected = {"style": "icon", "symbol": MAC_ICON_SYMBOL, "help": f"On {self.mac_name}"}
        problems = [f"icon {key}={icon.get(key)!r}, not {value!r}" for key, value in expected.items() if icon.get(key) != value]
        if mirror.get("device_icon_placement") != "before_branch":
            problems.append(f"the icon sits {mirror.get('device_icon_placement')!r}, not 'before_branch'")
        if local.get("device_icon") is not None or local.get("device_icon_placement") is not None:
            problems.append(f"the local row draws a Mac icon: {local.get('device_icon')} {local.get('device_icon_placement')}")
        if problems:
            raise Failure("; ".join(problems) + f" — mirror row: {mirror}")
        return {"icon": icon, "placement": mirror.get("device_icon_placement"), "branch": mirror.get("branch")}

    def nested_rows_show_no_status(self) -> Dict[str, Any]:
        source = self.locals[0]
        panel = wait_for("the source terminal", lambda: self.terminal(source), self.timeout)
        text = f"hello-{self.nonce}"
        v1 = self.sock.v1
        # What leaked an "Idle" line under the branch: Claude's SessionStart
        # pill after /clear, with no lifecycle, owned by a live agent PID (this
        # test's own); plus a custom pill and a progress bar.
        v1(f"set_agent_pid claude_code {os.getpid()} --tab={source} --panel={panel}")
        v1(f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={source} --panel={panel}")
        v1(f"set_status e2e_rows_pill {text} --icon=star.fill --tab={source}")
        v1(f"set_progress 0.4 --label=building --tab={source}")
        try:
            def reached() -> Optional[Dict[str, Any]]:
                status = self.mirror_status(source)
                entries = status.get("status_entries") or []
                progress = status.get("progress") or {}
                if any(e.get("key") == "e2e_rows_pill" for e in entries) and abs((progress.get("value") or 0) - 0.4) < 1e-6:
                    return {"entries": entries, "progress": progress}
                raise Failure(f"mirror status entries={entries} progress={progress or None}")

            # The mirror has the data, so a row that draws pills would show them.
            status = wait_for("the pills and progress to reach the mirror", reached, self.timeout)
            rows = {"local": self.row(source) or {}, "mirror": self.row(self.mirrors[source]) or {}}
        finally:
            v1(f"clear_agent_pid claude_code --tab={source} --panel={panel} --clear-status")
            v1(f"clear_status e2e_rows_pill --tab={source}")
            v1(f"clear_progress --tab={source}")
        problems: List[str] = []
        for kind, row in rows.items():
            pills = [p.get("text") for p in row.get("status_pills") or []]
            if pills or row.get("progress") is not None:
                problems.append(f"the {kind} nested row draws pills {pills} and progress {row.get('progress')}")
            if row.get("activity") not in ACTIVITIES:
                problems.append(f"the {kind} nested row reports no activity ({row.get('activity')!r})")
        if problems:
            raise Failure("; ".join(problems))
        idle_sent = any(e.get("key") == "claude_code" and e.get("value") == "Idle" for e in status["entries"])
        return {"mirror_status": status, "idle_pill_reached_mirror": idle_sent,
                "activity": {kind: row.get("activity") for kind, row in rows.items()}}

    def working_spinner_stays_small(self) -> Dict[str, Any]:
        source = self.locals[0]
        mirror = self.mirrors[source]
        panel = wait_for("the source terminal", lambda: self.terminal(source), self.timeout)
        self.sock.v1(f"set_agent_lifecycle claude_code running --tab={source} --panel={panel}")
        try:
            def working() -> Optional[Dict[str, Any]]:
                states = {"local": (self.row(source) or {}).get("activity"), "mirror": (self.row(mirror) or {}).get("activity")}
                if set(states.values()) != {"working"}:
                    raise Failure(f"row activity {states}")
                return states

            wait_for("the local and mirror nested rows to be working", working, self.timeout)

            def two_spinners() -> Optional[Dict[str, Any]]:
                found = self.sidebar_spinners()
                if len(found["marks"]) < 2:
                    raise Failure(f"{len(found['marks'])} amber marks along the sidebar's edge: {found}")
                return found

            found = wait_for("the two rows' spinners in a window screenshot", two_spinners, self.timeout, interval_s=1.0)
        finally:
            self.sock.v1(f"set_agent_lifecycle claude_code idle --tab={source} --panel={panel}")
        font_scale = float(self.rows().get("font_scale") or 1)
        max_width, max_height = SPINNER_MAX_WIDTH_PT * font_scale, SPINNER_MAX_HEIGHT_PT * font_scale
        big = [m for m in found["marks"] if m["width_pt"] > max_width or m["height_pt"] > max_height]
        if big:
            raise Failure(f"spinners bigger than the 6·scale one (at most {max_width}pt wide and {max_height}pt tall): "
                          f"{big}; screenshot {found['screenshot']}")
        return {**found, "font_scale": font_scale}

    def flat_mirror_subtitle_omits_mac(self) -> Dict[str, Any]:
        folder = self.root / "flat-dir"
        folder.mkdir(parents=True, exist_ok=True)
        created = self.sock.call("workspace.create", {
            "title": f"rows-flat-{self.nonce}", "focus": False, "working_directory": str(folder),
        }) or {}
        source = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not source:
            raise Failure(f"workspace.create returned no id: {created}")
        self.created.append(source)
        mirror = wait_for("the flat workspace's mirror", lambda: self.mirror_of(source), self.timeout)

        def subtitle() -> Optional[Dict[str, Any]]:
            flat = next((r for r in self.rows().get("flat") or [] if up(r.get("workspace_id")) == mirror), None)
            if flat is None:
                raise Failure("the mirror is not in the flat list")
            lines = (flat.get("subtitle_candidates") or []) + [c for line in flat.get("branch_directory_lines") or [] for c in line]
            if not any(str(folder.name) in line for line in lines):
                raise Failure(f"no directory line yet: {lines}")
            return {"lines": lines, "device_label": flat.get("device_label"),
                    "device_icon": flat.get("device_icon"), "device_icon_placement": flat.get("device_icon_placement")}

        found = wait_for("the mirror's directory line", subtitle, self.timeout)
        repeated = [line for line in found["lines"] if self.mac_name and self.mac_name in line]
        if repeated:
            raise Failure(f"the directory line repeats the Mac name: {repeated}")
        icon = found.get("device_icon") or {}
        if icon.get("style") != "icon" or icon.get("symbol") != MAC_ICON_SYMBOL or found.get("device_icon_placement") != "branch_line":
            raise Failure(f"the flat mirror's Mac icon is {icon} at {found.get('device_icon_placement')!r}, "
                          f"not a {MAC_ICON_SYMBOL} icon on its directory line")
        return found

    # -- run ------------------------------------------------------------------

    def cleanup(self) -> None:
        # Close the sources only: auto-mirror closes each mirror once its
        # remote workspace is gone. (Hiding the mirrors and unhiding them
        # afterwards raced that removal and could reopen a mirror.)
        try:
            for workspace_id in self.created:
                self.sock.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            wait_for("the mirrors to close with their sources",
                     lambda: not any(self.mirror_of(w) for w in self.created), self.timeout)
            if self.project_id:
                self.request("mobile.supermux.project.delete", {"project_id": self.project_id})
            if self.initial_auto_mirror is False:
                self.sock.call("supermux.devices.set_auto_mirror", {"enabled": False})
        except (Failure, OSError) as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))
        if not self.args.keep:
            shutil.rmtree(self.root, ignore_errors=True)

    def run(self) -> bool:
        ok = self.step("setup", self.setup) and self.step("project_with_local_and_mirror_rows", self.project_with_rows)
        if ok:
            for name, check in [
                ("nested_rows_local_first", self.nested_rows_local_first),
                ("nested_mirror_label_names_mac", self.nested_mirror_label_names_mac),
                ("nested_mirror_icon_before_branch", self.nested_mirror_icon_before_branch),
                ("nested_rows_show_no_status", self.nested_rows_show_no_status),
                ("working_spinner_stays_small", self.working_spinner_stays_small),
                ("flat_mirror_subtitle_omits_mac", self.flat_mirror_subtitle_omits_mac),
            ]:
                ok = self.step(name, check) and ok
        self.cleanup()
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"))
    parser.add_argument("--scratch", default=None, help="scratch folder for the test repos (default /tmp/<tag>-rows)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per wait")
    parser.add_argument("--keep", action="store_true", help="keep the scratch repos")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    args.scratch = args.scratch or f"/tmp/{args.tag or 'socket'}-rows"
    args.report_path = args.report or str(ARTIFACTS_DIR / f"loopback_sidebar_rows_e2e-{args.tag or 'socket'}.json")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = SidebarRowsE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except (OSError, Failure) as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-sidebar-rows-e2e",
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
