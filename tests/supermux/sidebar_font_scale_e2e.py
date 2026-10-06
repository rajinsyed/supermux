#!/usr/bin/env python3
"""End-to-end test that the Projects section follows cmux.json's `sidebar.fontSize`,
against one tagged DEBUG build.

Upstream's #17467 (merged 2026-10-06) made `sidebar.fontSize` a cmux.json key: the
settings file store writes it to the `cmux.settings.sidebarFontSize` default, and
`GhosttyConfig.loadForCmux()` lays it over the Ghostty config, so upstream's flat
workspace rows draw at that size. The fork's Projects section and its nested rows
must draw at the same scale (`SupermuxSidebarFontScaleStore`), which
`supermux.devices.sidebar_rows` reports as `font_scale`:

  1. setup                          the tagged app quit; the tag's own default recorded
  2. cmux_json_size_scales_projects launched with the default the cmux.json key writes
                                    (`--size`, 16 pt): `font_scale` is size / 12.5
  3. cleanup                        the tag's default restored; the app relaunched

The user's own cmux.json is never touched: the test writes only the default that
key resolves to, in the tagged build's own domain. Writes a JSON report (default
tests/supermux/artifacts/sidebar_font_scale_e2e-<tag>.json) with a window
screenshot, and exits non-zero on any failure. Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/sidebar_font_scale_e2e.py --app-path "<App path>" [--size 16] [--report PATH]
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
from loopback_tab_sync_e2e import ARTIFACTS_DIR, Failure, socket_path_for_tag, wait_for  # noqa: E402
from tagged_app import TaggedApp, require_isolated  # noqa: E402

SIZE_KEY = "cmux.settings.sidebarFontSize"
DEFAULT_SIDEBAR_FONT_SIZE = 12.5


class SidebarFontScaleE2E:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.app = TaggedApp(args.app_path, args.socket or socket_path_for_tag(args.tag))
        self.steps: List[Dict[str, Any]] = []
        self.saved: Optional[str] = None

    def font_scale(self) -> Optional[float]:
        value = (self.app.sock.call("supermux.devices.sidebar_rows", {}) or {}).get("font_scale")
        return float(value) if value is not None else None

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
        self.saved = self.app.read_default(SIZE_KEY)
        self.app.quit()
        return {"bundle_id": self.app.bundle_id, "saved": self.saved}

    def cmux_json_size_scales_projects(self) -> Dict[str, Any]:
        expected = self.args.size / DEFAULT_SIDEBAR_FONT_SIZE
        self.app.write_float(SIZE_KEY, self.args.size)
        self.app.launch()
        seen: List[Optional[float]] = []

        def matches() -> bool:
            scale = self.font_scale()
            seen.append(scale)
            return scale is not None and abs(scale - expected) < 0.001

        try:
            wait_for(f"font_scale {expected:.3f} for a {self.args.size} pt sidebar", matches, 10)
        except Failure as error:
            raise Failure(f"{error}; saw {seen[-5:]}")
        shot = self.app.screenshot("sidebar-font-scale")
        return {"expected": expected, "font_scale": seen[-1], "screenshot": shot}

    def cleanup(self) -> Dict[str, Any]:
        self.app.quit()
        if self.saved is None:
            self.app.delete_default(SIZE_KEY)
        else:
            self.app.write_float(SIZE_KEY, float(self.saved))
        self.app.launch()
        return {"restored": self.saved}

    def run(self) -> bool:
        if not self.step("setup", self.setup):
            return False
        ok = self.step("cmux_json_size_scales_projects", self.cmux_json_size_scales_projects)
        return self.step("cleanup", self.cleanup) and ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="defaults to /tmp/cmux-debug-<tag>.sock")
    parser.add_argument("--app-path", required=True)
    parser.add_argument("--size", type=float, default=16.0, help="sidebar font size in pt (10-20)")
    parser.add_argument("--report")
    args = parser.parse_args()
    if not args.tag:
        parser.error("set CMUX_TAG or pass --tag")
    if not require_isolated(args.app_path, args.tag):
        return 1

    e2e = SidebarFontScaleE2E(args)
    passed = e2e.run()
    report = {
        "suite": "sidebar_font_scale_e2e",
        "tag": args.tag,
        "passed": passed,
        "finished_at": datetime.now(timezone.utc).isoformat(),
        "steps": e2e.steps,
    }
    path = Path(args.report) if args.report else ARTIFACTS_DIR / f"sidebar_font_scale_e2e-{args.tag}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": passed, "report": str(path)}))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
