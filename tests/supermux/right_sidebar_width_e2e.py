#!/usr/bin/env python3
"""End-to-end test that the right sidebar keeps Supermux's narrow widths, against
one tagged DEBUG build.

Supermux lowers the right sidebar's minimum to 200 pt (touchpoint #26) and opens
new windows at 220 pt. Upstream's #17074 (merged 2026-10-06) also clamps the
sidebar to a content minimum, the mode bar's width with one full tab name, which
is about 290-360 pt with Supermux's tabs. Every clamp path persists the clamped
width to the `fileExplorer.width` default, so the default is what this reads:

  1. setup                      the tagged app quit; the tag's own defaults recorded
  2. saved_narrow_width_kept    launched with `fileExplorer.width` = 200 and the
                                sidebar visible: the saved width stays 200 for
                                `--hold` seconds after the window is up
  3. fresh_width_opens_at_220   launched with no saved width: the sidebar opens at
                                220 (the default is unset or 220) for `--hold` seconds
  4. cleanup                    the tag's defaults restored; the app relaunched

Only the tagged build's own defaults domain is written. Writes a JSON report
(default tests/supermux/artifacts/right_sidebar_width_e2e-<tag>.json) with a
window screenshot per step, and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/right_sidebar_width_e2e.py --app-path "<App path>" [--hold 6] [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_tab_sync_e2e import ARTIFACTS_DIR, Failure, socket_path_for_tag  # noqa: E402
from tagged_app import TaggedApp, require_isolated  # noqa: E402

WIDTH_KEY = "fileExplorer.width"
VISIBLE_KEY = "fileExplorer.isVisible"
FORK_MINIMUM = 200.0
FORK_OPENING = 220.0


class RightSidebarWidthE2E:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.app = TaggedApp(args.app_path, args.socket or socket_path_for_tag(args.tag), args.tag,
                             args.projects_file, args.push_state_dir)
        self.steps: List[Dict[str, Any]] = []
        self.saved: Dict[str, Optional[str]] = {}

    def width(self) -> Optional[float]:
        raw = self.app.read_default(WIDTH_KEY)
        return float(raw) if raw else None

    def width_holds(self, accept: Callable[[Optional[float]], bool]) -> List[Optional[float]]:
        """Samples the persisted width for `--hold` seconds; every sample must pass."""
        samples: List[Optional[float]] = []
        deadline = time.monotonic() + self.args.hold
        while time.monotonic() < deadline:
            width = self.width()
            samples.append(width)
            if not accept(width):
                raise Failure(f"{WIDTH_KEY} became {width} (samples {samples})")
            time.sleep(0.5)
        return samples

    def step(self, name: str, action: Callable[[], Optional[Dict[str, Any]]]) -> bool:
        started = time.monotonic()
        record: Dict[str, Any] = {"name": name}
        try:
            record.update(action() or {})
            record["ok"] = True
        except (Failure, subprocess.CalledProcessError, OSError) as error:
            record["ok"] = False
            record["error"] = str(error)
        record["seconds"] = round(time.monotonic() - started, 2)
        self.steps.append(record)
        print(f"{'PASS' if record['ok'] else 'FAIL'} {name} ({record['seconds']}s)"
              + ("" if record["ok"] else f": {record['error']}"))
        return record["ok"]

    def setup(self) -> Dict[str, Any]:
        self.saved = {key: self.app.read_default(key) for key in (WIDTH_KEY, VISIBLE_KEY)}
        self.app.quit()
        return {"bundle_id": self.app.bundle_id, "saved": self.saved}

    def launch_and_hold(self, label: str, accept: Callable[[Optional[float]], bool]) -> Dict[str, Any]:
        self.app.write_bool(VISIBLE_KEY, True)
        self.app.launch()
        try:
            samples = self.width_holds(accept)
        finally:
            shot = self.app.screenshot(f"right-sidebar-width-{label}")
            self.app.quit()
        return {"samples": samples, "screenshot": shot}

    def saved_narrow_width_kept(self) -> Dict[str, Any]:
        self.app.write_float(WIDTH_KEY, FORK_MINIMUM)
        return self.launch_and_hold("saved-200", lambda w: w is not None and abs(w - FORK_MINIMUM) <= 0.5)

    def fresh_width_opens_at_220(self) -> Dict[str, Any]:
        self.app.delete_default(WIDTH_KEY)
        return self.launch_and_hold("fresh", lambda w: w is None or abs(w - FORK_OPENING) <= 0.5)

    def cleanup(self) -> Dict[str, Any]:
        self.app.quit()
        for key, raw in self.saved.items():
            if raw is None:
                self.app.delete_default(key)
            elif key == WIDTH_KEY:
                self.app.write_float(key, float(raw))
            else:
                self.app.write_bool(key, raw == "1")
        self.app.launch()
        return {"restored": self.saved}

    def run(self) -> bool:
        if not self.step("setup", self.setup):
            return False
        ok = self.step("saved_narrow_width_kept", self.saved_narrow_width_kept)
        ok = self.step("fresh_width_opens_at_220", self.fresh_width_opens_at_220) and ok
        return self.step("cleanup", self.cleanup) and ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="defaults to /tmp/cmux-debug-<tag>.sock")
    parser.add_argument("--app-path", required=True)
    parser.add_argument("--projects-file", help="scratch projects document (default /tmp/<tag>-e2e/projects.json)")
    parser.add_argument("--push-state-dir", help="scratch phone push state (default /tmp/<tag>-e2e/push-state)")
    parser.add_argument("--hold", type=float, default=6.0, help="seconds each width must hold after the window is up")
    parser.add_argument("--report")
    args = parser.parse_args()
    if not args.tag:
        parser.error("set CMUX_TAG or pass --tag")
    if not require_isolated(args.app_path, args.tag):
        return 1

    e2e = RightSidebarWidthE2E(args)
    passed = e2e.run()
    report = {
        "suite": "right_sidebar_width_e2e",
        "tag": args.tag,
        "passed": passed,
        "finished_at": datetime.now(timezone.utc).isoformat(),
        "steps": e2e.steps,
    }
    path = Path(args.report) if args.report else ARTIFACTS_DIR / f"right_sidebar_width_e2e-{args.tag}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": passed, "report": str(path)}))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
