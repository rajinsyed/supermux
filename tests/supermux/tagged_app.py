"""Quit, relaunch and read or write the defaults of ONE tagged DEBUG build.

Shared by the suites that must set a preference before the app launches
(right_sidebar_width_e2e.py, sidebar_font_scale_e2e.py). Every write goes to the
tagged build's own defaults domain (its bundle id), never the user's app; the
suites run require_isolated_app.py before they construct one. Stdlib only.
"""

from __future__ import annotations

import plistlib
import subprocess
import sys
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_tab_sync_e2e import Failure, Socket, wait_for  # noqa: E402


def require_isolated(app_path: str, tag: str) -> bool:
    """Runs the isolation guard: refuses a seeded tag or any app but this tag's."""
    guard = Path(__file__).resolve().parent / "require_isolated_app.py"
    return subprocess.run([sys.executable, str(guard), "--app", app_path, "--tag", tag]).returncode == 0


class TaggedApp:
    def __init__(self, app_path: str, socket_path: str) -> None:
        self.app = app_path
        self.bundle_id = plistlib.loads((Path(app_path) / "Contents" / "Info.plist").read_bytes())["CFBundleIdentifier"]
        self.sock = Socket(socket_path)

    # -- defaults (this tag's domain only) --------------------------------------

    def read_default(self, key: str) -> Optional[str]:
        result = subprocess.run(["defaults", "read", self.bundle_id, key], capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None

    def write_float(self, key: str, value: float) -> None:
        subprocess.run(["defaults", "write", self.bundle_id, key, "-float", str(value)], check=True)

    def write_bool(self, key: str, value: bool) -> None:
        subprocess.run(["defaults", "write", self.bundle_id, key, "-bool", "true" if value else "false"], check=True)

    def delete_default(self, key: str) -> None:
        subprocess.run(["defaults", "delete", self.bundle_id, key], capture_output=True)

    # -- process ------------------------------------------------------------------

    def running(self) -> bool:
        script = f'application id "{self.bundle_id}" is running'
        result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        return result.stdout.strip() == "true"

    def quit(self) -> None:
        self.sock.close()
        if not self.running():
            return
        subprocess.run(["osascript", "-e", f'tell application id "{self.bundle_id}" to quit'], capture_output=True)
        wait_for("the tagged app to quit", lambda: not self.running(), 60, interval_s=0.5)

    def launch(self) -> None:
        """Opens the app in the background and connects once a main window is up."""
        subprocess.run(["open", "-g", self.app], check=True)

        def window_up() -> bool:
            probe = Socket(self.sock.path, timeout_s=3)
            try:
                probe.connect()
                return bool((probe.call("window.list", {}) or {}).get("windows"))
            except (OSError, Failure):
                return False
            finally:
                probe.close()

        wait_for("the launched app's window", window_up, 60)
        self.sock.connect()

    def screenshot(self, label: str) -> Optional[str]:
        try:
            return (self.sock.call("debug.window.screenshot", {"label": label}) or {}).get("path")
        except Failure:
            return None
