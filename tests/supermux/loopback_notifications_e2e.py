#!/usr/bin/env python3
"""End-to-end check of notification and phone-push parity for remote Macs.

Runs against one tagged DEBUG build launched with the loopback device
(SUPERMUX_DEBUG_LOOPBACK_DEVICE=1), a scratch projects file and a scratch
direct-APNs directory:

  open -g --env SUPERMUX_DEBUG_LOOPBACK_DEVICE=1 \\
          --env SUPERMUX_PROJECTS_FILE=/tmp/<tag>/projects.json \\
          --env SUPERMUX_PHONE_PUSH_STATE_DIR=/tmp/<tag>/push-state "<App path>"
  CMUX_TAG=<tag> python3 tests/supermux/loopback_notifications_e2e.py --push-state-dir /tmp/<tag>/push-state

The app is both Macs: its own workspaces are the "Loopback Mac" device's
remote workspaces, so a SOURCE workspace (host side) and its local MIRROR
(viewer side) live in one process. Checks:

  1. device_connected / scratch_push_state: the loopback link is up and the
     direct lane points at the scratch directory (never the real one).
  2. source_and_mirror: a project-owned source workspace and its mirror.
  3. notification_reaches_mirror: `cmux notify` on the SOURCE surface lands on
     the MIRROR as a `device-mac:` record, with the source's project.
  4. viewer_skips_phone: the push decision log shows the mirrored record was
     never forwarded (relay not attempted, direct `skip_device_mirror`), and
     the phone badge (and host `notification.reconcile`) exclude it.
  5. host_read_marks_mirror_read: reading the source record reads the mirror copy.
  6. mark_unread_survives_host_feed: Mark as Unread on that (host-read) mirror
     copy survives the next host feed update; only a NEW host read reads it.
  7. mirror_read_marks_host_read: reading the mirror copy reads the source record.
  8. focused_mirror_arrival_rings_until_click: with the mirror pane focused
     for a present user, a new source notification arrives on the mirror
     unread, with the pane ring and the tab badge, and the source record stays
     unread; a click in the mirror pane reads the copy, clears the ring and
     reads the source record.
  8a. host_read_clears_focused_mirror_ring: with the mirror pane focused and
     lit, reading the source record on the host reads the copy and clears the
     mirror pane's ring and badges (no click here).
  8a'. newer_mirror_copy_keeps_ring: with the mirror pane focused, a second
     source notification supersedes the first on the host; the host's read of
     the first must not wipe the ring the newer, still unread copy set.
     Reading the newer one on the host then clears it.
  8b. focused_pane_rings_until_click: the SOURCE pane focused for a present
     user: the notification is unread with the ring, the tab badge and the
     workspace badge (as on any other pane), nothing reads it on its own, the
     phone is not pushed (`skip_focused_pane`), and a click in the pane reads
     it and clears the ring and the badges. A window screenshot with the ring
     is saved next to the report.
  8c. mirror_read_clears_focused_source_ring: the SOURCE pane focused and lit
     for a present user; reading the mirror copy (another Mac's read, sent over
     the Mac link) reads the source record AND clears the source pane's ring
     and badges, the way a host read clears the mirror pane's.
  9. unattended_host_keeps_unread: the SOURCE pane focused but the user away:
     the notification stays unread (and the direct lane is not skipped as
     focused); present: it also stays unread, and only the phone push is
     skipped (`skip_focused_pane`).
 10. app_focused_setting_keeps_background_unread: with upstream's
     `notifications.suppressWhenAppFocused` on and cmux frontmost for a present
     user, a notification for panes in workspaces the user is NOT looking at
     stays unread on both the source and the mirror (the setting withholds only
     the banner), and the source is not skipped as the focused pane.
 11. burst_rows_all_delivered: 7 notifications on 7 source terminals at once (over
     the 5-row admission burst) all reach the mirror without another feed event.
 12. phone_push_status_over_link: `mobile.supermux.phone_push.status` over the
     Mac link is sane and carries no key material.
 13. share_refused_for_non_mac_callers: `phone_push.share` is refused for an
     iOS peer, the Stack-bearer path and an in-process caller.
 14. share_over_mac_link: over the Mac link, a share installs a key where none
     exists (0600 files, 0700 dir), refuses a different key without touching
     the file, merges registrations, and the link-connect coordinator reports
     the peer up to date. Scratch files are removed afterwards.

Prints a JSON report, writes it to tests/supermux/artifacts/, exits non-zero on
any failed check. Stdlib only (plus /usr/bin/openssl to mint a throwaway key).

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_notifications_e2e.py --push-state-dir DIR [--keep]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_device_smoke import (  # noqa: E402
    ARTIFACTS_DIR,
    REPO_ROOT,
    LoopbackSmoke,
    SmokeFailure,
    SocketClient,
    norm,
    socket_path_for_tag,
    wait_for,
)

APNS_BUNDLE = "com.supermux.ios"


class NotificationsE2E(LoopbackSmoke):
    def __init__(self, client: SocketClient, tag: str, timeout_s: float, keep: bool, push_state_dir: Path, work_dir: Path, report_path: Path) -> None:
        super().__init__(client, timeout_s=timeout_s, keep=keep)
        self.tag = tag
        self.push_state_dir = push_state_dir
        self.work_dir = work_dir
        self.report_path = report_path
        self.project_id: Optional[str] = None
        self.project_root: Optional[Path] = None
        self.burst_surfaces: List[str] = []

    # -- helpers ------------------------------------------------------------

    def hook(self, name: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        return self.client.call(f"supermux.devices.{name}", params or {}) or {}

    def link_request(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        result = self.client.call(
            "supermux.devices.request",
            {"machine": self.facts["machine"], "method": method, "params": params or {}},
            timeout_s=60,
        ) or {}
        return result.get("result") or {}

    def records(self) -> List[Dict[str, Any]]:
        return self.hook("notification_records").get("records") or []

    def record_titled(self, title: str, workspace_id: str) -> Optional[Dict[str, Any]]:
        return next(
            (r for r in self.records() if r.get("title") == title and norm(r.get("workspace_id")) == norm(workspace_id)),
            None,
        )

    def notify_cli(self, surface_id: str, title: str, body: str) -> None:
        """`cmux notify` on a SOURCE surface of this tagged build (a test
        action on our own build), falling back to the socket if the CLI is
        unavailable."""
        env = dict(os.environ, CMUX_TAG=self.tag)
        command = [
            str(REPO_ROOT / "scripts" / "cmux-debug-cli.sh"), "notify",
            "--workspace", self.source_workspace_id or "", "--surface", surface_id,
            "--title", title, "--body", body,
        ]
        completed = subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)
        if completed.returncode != 0:
            self.facts.setdefault("cli_notify_fallbacks", []).append(completed.stderr.strip()[:300])
            self.notify_socket(surface_id, title, body)

    def notify_socket(self, surface_id: str, title: str, body: str) -> None:
        self.client.call(
            "notification.create_for_surface",
            {"workspace_id": self.source_workspace_id, "surface_id": surface_id, "title": title, "body": body},
        )

    def mirror_copy(self, title: str) -> Dict[str, Any]:
        return wait_for(
            f"the mirror copy of {title!r}",
            lambda: self.record_titled(title, self.mirror_workspace_id or ""),
            self.timeout_s,
        )

    def source_record(self, title: str) -> Dict[str, Any]:
        return wait_for(
            f"the source record {title!r}",
            lambda: self.record_titled(title, self.source_workspace_id or ""),
            self.timeout_s,
        )

    def wait_read(self, description: str, title: str, workspace_id: str) -> Dict[str, Any]:
        def probe() -> Optional[Dict[str, Any]]:
            record = self.record_titled(title, workspace_id)
            return record if record and record.get("is_read") else None

        return wait_for(description, probe, self.timeout_s)

    def decision_for(self, notification_id: str) -> Optional[Dict[str, Any]]:
        decisions = self.hook("push_decisions").get("decisions") or []
        return next((d for d in reversed(decisions) if norm(d.get("notification_id")) == norm(notification_id)), None)

    def overrides(self, **values: Any) -> Dict[str, Any]:
        return self.hook("notification_overrides", values)

    def look_away_from_source_and_mirror(self) -> List[str]:
        """Selects, in every window holding the source or its mirror, a
        workspace that is neither, so neither pane is in view. Returns the
        workspaces it selected."""
        busy = {norm(self.source_workspace_id), norm(self.mirror_workspace_id)}
        selected: List[str] = []
        for window in (self.client.call("window.list", {}) or {}).get("windows") or []:
            window_id = window.get("id")
            rows = (self.client.call("workspace.list", {"window_id": window_id}) or {}).get("workspaces") or []
            ids = [str(row.get("id") or "") for row in rows]
            if not any(norm(workspace_id) in busy for workspace_id in ids):
                continue
            other = next((w for w in ids if w and norm(w) not in busy), None)
            if other is None:
                created = self.client.call(
                    "workspace.create",
                    {"title": f"notify-e2e-other-{self.nonce}", "focus": False, "window_id": window_id},
                ) or {}
                other = str(created.get("workspace_id") or "")
                if not other:
                    raise SmokeFailure(f"workspace.create returned no workspace_id: {created}")
                self.facts.setdefault("other_workspaces_created", []).append(other)
            self.client.call("workspace.select", {"workspace_id": other})
            selected.append(other)
        if not selected:
            raise SmokeFailure("found no window holding the source or the mirror")
        return selected

    def app_focus(self, state: str) -> None:
        self.client.call("app.focus_override.set", {"state": state})

    def select(self, workspace_id: str, surface_id: str) -> None:
        self.client.call("workspace.select", {"workspace_id": workspace_id})
        self.client.call("surface.focus", {"workspace_id": workspace_id, "surface_id": surface_id})

    def indicators(self, surface_id: str) -> Dict[str, Any]:
        return self.hook("notification_indicators", {"surface_id": surface_id})

    @staticmethod
    def is_lit(state: Dict[str, Any], surface_id: str) -> bool:
        """The pane shows its notification the way any other pane does: an
        unread record, the ring, its tab's badge and the workspace's badge."""
        return bool(
            state.get("has_unread_notification")
            and state.get("has_visible_indicator")
            and norm(state.get("focused_read_indicator_surface_id")) == norm(surface_id)
            and state.get("tab_shows_notification_badge")
            and state.get("ring_visible")
            and int(state.get("workspace_unread_count") or 0) >= 1
        )

    @staticmethod
    def is_cleared(state: Dict[str, Any]) -> bool:
        return not (
            state.get("has_visible_indicator")
            or state.get("ring_visible")
            or state.get("tab_shows_notification_badge")
            or state.get("focused_read_indicator_surface_id")
        )

    def wait_lit(self, description: str, surface_id: str) -> Dict[str, Any]:
        def probe() -> Optional[Dict[str, Any]]:
            state = self.indicators(surface_id)
            return state if self.is_lit(state, surface_id) else None

        try:
            return wait_for(description, probe, self.timeout_s)
        except SmokeFailure as error:
            raise SmokeFailure(f"{error}; last indicators {self.indicators(surface_id)}") from None

    def click_until_cleared(self, description: str, surface_id: str) -> Dict[str, Any]:
        clicked = self.hook("notification_click", {"surface_id": surface_id})

        def probe() -> Optional[Dict[str, Any]]:
            state = self.indicators(surface_id)
            return state if self.is_cleared(state) else None

        try:
            cleared = wait_for(description, probe, self.timeout_s)
        except SmokeFailure as error:
            raise SmokeFailure(f"{error}; last indicators {self.indicators(surface_id)}") from None
        return {"right_after_click": clicked, "cleared": cleared}

    def screenshot(self, label: str) -> Optional[str]:
        """Best effort: the app's window, copied next to the report."""
        try:
            shot = self.client.call("debug.window.screenshot", {"label": f"notifications-{label}"}) or {}
        except SmokeFailure:
            return None
        path = str(shot.get("path") or "")
        if not path or not Path(path).exists():
            return None
        kept = self.report_path.with_name(f"{self.report_path.stem}-{label}.png")
        kept.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, kept)
        return str(kept)

    # -- steps --------------------------------------------------------------

    def check_scratch_push_state(self) -> Dict[str, Any]:
        debug = self.hook("phone_push_debug")
        base = Path(str(debug.get("base_directory") or "")).resolve()
        if base != self.push_state_dir.resolve():
            raise SmokeFailure(
                f"the direct lane uses {base}, not the scratch {self.push_state_dir}; relaunch with "
                f"--env SUPERMUX_PHONE_PUSH_STATE_DIR={self.push_state_dir} (refusing to touch real credentials)"
            )
        status = debug.get("status") or {}
        if status.get("has_credentials"):
            raise SmokeFailure("the scratch push directory already holds credentials; start from an empty directory")
        # Start loose, so the share step proves the directory is tightened to 0700.
        os.chmod(self.push_state_dir, 0o755)
        return {"base_directory": str(base), "status": status, "share_attempts": debug.get("share_attempts")}

    def create_project_source_and_mirror(self) -> Dict[str, Any]:
        self.project_root = self.work_dir / f"proj-{self.nonce}"
        self.project_root.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "-q", str(self.project_root)], check=True)
        created = self.link_request("mobile.supermux.project.create", {"root_path": str(self.project_root)})
        project = created.get("project") or {}
        self.project_id = project.get("id")
        if not self.project_id:
            raise SmokeFailure(f"project.create returned no project: {created}")
        result = self.client.call(
            "workspace.create",
            {"title": f"notify-e2e-{self.nonce}", "cwd": str(self.project_root), "focus": False},
        ) or {}
        self.source_workspace_id = str(result.get("workspace_id") or "")
        if not self.source_workspace_id:
            raise SmokeFailure(f"workspace.create returned no workspace_id: {result}")

        def remote_terminal() -> Optional[Dict[str, Any]]:
            for resource in self.catalog().get("resources") or []:
                workspace = resource.get("remote_workspace") or {}
                if resource.get("kind") == "terminal" and norm(workspace.get("id")) == norm(self.source_workspace_id):
                    return resource
            return None

        resource = wait_for("the source workspace's terminal on the device", remote_terminal, self.timeout_s)
        # Associate it explicitly: project.open reuses the open workspace at the
        # root (a /tmp root and its /private/tmp shell directory do not match by path).
        self.link_request("mobile.supermux.project.open", {"project_id": self.project_id})

        def associated() -> Optional[str]:
            for device in (self.client.call("supermux.devices.list", {}) or {}).get("devices") or []:
                for record in device.get("records") or []:
                    if norm(record.get("id")) == norm(self.source_workspace_id):
                        return record.get("supermux_project_id") if norm(record.get("supermux_project_id")) == norm(self.project_id) else None
            return None

        wait_for("the source workspace to belong to the project on the device", associated, self.timeout_s)
        self.facts.update({
            "source_workspace_id": self.source_workspace_id,
            "source_surface_id": resource["key"],
            "remote_workspace_id": resource["remote_workspace"]["id"],
            "project_id": self.project_id,
        })
        opened = self.open_mirror()
        return {"project_id": self.project_id, "source_workspace_id": self.source_workspace_id, **opened}

    def check_notification_reaches_mirror(self) -> Dict[str, Any]:
        self.app_focus("inactive")
        title = f"e2e-arrive-{self.nonce}"
        self.notify_cli(self.facts["source_surface_id"], title, "notification parity e2e")
        source = self.source_record(title)
        copy = self.mirror_copy(title)
        if not str(copy.get("origin", "")).startswith("device-mac:"):
            raise SmokeFailure(f"mirror copy origin is {copy.get('origin')!r}, expected device-mac:")
        if source.get("origin") != "local":
            raise SmokeFailure(f"source record origin is {source.get('origin')!r}")
        if norm(copy.get("surface_id")) != norm(self.facts["mirror_surface_id"]):
            raise SmokeFailure("the mirror copy is not on the mirror terminal")
        source_project = (source.get("project") or {}).get("id")
        copy_project = (copy.get("project") or {}).get("id")
        if norm(source_project) != norm(self.project_id):
            raise SmokeFailure(f"source record project {source_project} != created project {self.project_id}")
        if norm(copy_project) != norm(self.project_id):
            raise SmokeFailure(f"mirror copy project {copy_project} != the remote project {self.project_id}")
        self.facts["arrive_title"] = title
        self.facts["arrive_source_id"] = source["id"]
        self.facts["arrive_mirror_id"] = copy["id"]
        return {"source": source, "mirror_copy": copy}

    def check_viewer_skips_phone(self) -> Dict[str, Any]:
        mirror_decision = wait_for(
            "a push decision for the mirror copy",
            lambda: self.decision_for(self.facts["arrive_mirror_id"]),
            self.timeout_s,
        )
        source_decision = self.decision_for(self.facts["arrive_source_id"])
        if mirror_decision.get("origin") != "device-mac":
            raise SmokeFailure(f"mirror decision origin {mirror_decision.get('origin')}")
        if mirror_decision.get("upstream_relay_attempted") is not False:
            raise SmokeFailure("the upstream relay lane was attempted for a device-mac record")
        if mirror_decision.get("direct") != "skip_device_mirror":
            raise SmokeFailure(f"direct lane verdict {mirror_decision.get('direct')!r} for a device-mac record")
        if not source_decision or source_decision.get("direct") == "skip_device_mirror":
            raise SmokeFailure(f"source record decision unexpected: {source_decision}")
        counts = self.hook("notification_records")
        unread_mirrored = sum(
            1 for r in counts.get("records") or []
            if not r.get("is_read") and str(r.get("origin", "")).startswith("device-mac:")
        )
        expected_badge = int(counts.get("unread_count", 0)) - unread_mirrored
        if unread_mirrored < 1 or int(counts.get("phone_badge_count", -1)) != expected_badge:
            raise SmokeFailure(
                f"phone badge {counts.get('phone_badge_count')} != unread {counts.get('unread_count')} - mirrored {unread_mirrored}"
            )
        reconcile = self.link_request("notification.reconcile", {"delivered_ids": []})
        if int(reconcile.get("unread_count", -1)) != expected_badge:
            raise SmokeFailure(f"notification.reconcile unread_count {reconcile.get('unread_count')} != phone badge {expected_badge}")
        return {
            "mirror_decision": mirror_decision,
            "source_decision": source_decision,
            "unread_count": counts.get("unread_count"),
            "unread_mirrored": unread_mirrored,
            "phone_badge_count": counts.get("phone_badge_count"),
            "reconcile_unread_count": reconcile.get("unread_count"),
        }

    def check_host_read_marks_mirror_read(self) -> Dict[str, Any]:
        self.client.call("notification.mark_read", {"id": self.facts["arrive_source_id"]})
        copy = self.wait_read("the mirror copy to turn read after the host read", self.facts["arrive_title"], self.mirror_workspace_id or "")
        time.sleep(1.5)
        source = self.record_titled(self.facts["arrive_title"], self.source_workspace_id or "")
        if not source or not source.get("is_read"):
            raise SmokeFailure(f"source record flipped back: {source}")
        return {"mirror_copy_is_read": copy.get("is_read"), "source_is_read": source.get("is_read")}

    def check_mark_unread_survives_host_feed(self) -> Dict[str, Any]:
        title = self.facts["arrive_title"]
        copy = self.record_titled(title, self.mirror_workspace_id or "")
        if not copy or not copy.get("is_read"):
            raise SmokeFailure(f"expected the host-read mirror copy to be read first: {copy}")
        marked = self.hook("notification_mark_unread", {"id": copy["id"]})
        if marked.get("is_read") is not False:
            raise SmokeFailure(f"Mark as Unread did not take: {marked}")
        # Any new host notification changes the host feed; its mirror copy
        # proves the viewer refetched (and re-ran the host-read mirror).
        next_title = f"e2e-after-unread-{self.nonce}"
        self.notify_socket(self.facts["source_surface_id"], next_title, "the host feed changes")
        self.mirror_copy(next_title)
        time.sleep(1.5)
        copy = self.record_titled(title, self.mirror_workspace_id or "")
        if not copy or copy.get("is_read"):
            raise SmokeFailure("the next host feed update undid Mark as Unread on the mirror copy")
        source = self.record_titled(title, self.source_workspace_id or "")
        self.client.call("notification.mark_read", {"id": copy["id"]})
        return {"mirror_copy_is_read": copy.get("is_read"), "source_is_read": (source or {}).get("is_read")}

    def check_mirror_read_marks_host_read(self) -> Dict[str, Any]:
        title = f"e2e-viewer-read-{self.nonce}"
        self.notify_socket(self.facts["source_surface_id"], title, "viewer read")
        copy = self.mirror_copy(title)
        self.client.call("notification.mark_read", {"id": copy["id"]})
        source = self.wait_read("the source record to turn read after the viewer read", title, self.source_workspace_id or "")
        return {"source_is_read": source.get("is_read")}

    def check_focused_mirror_arrival_rings_until_click(self) -> Dict[str, Any]:
        mirror_surface = self.facts["mirror_surface_id"]
        self.select(self.mirror_workspace_id or "", mirror_surface)
        self.app_focus("active")
        overrides = self.overrides(presence="present", window_key="key")
        try:
            title = f"e2e-focused-mirror-{self.nonce}"
            self.notify_socket(self.facts["source_surface_id"], title, "the focused mirror pane's agent finished")
            copy = self.mirror_copy(title)
            if copy.get("is_read"):
                raise SmokeFailure("the focused mirror pane's copy was recorded read on arrival")
            lit = self.wait_lit("the focused mirror pane's ring, tab badge and workspace badge", mirror_surface)
            time.sleep(2)
            source = self.record_titled(title, self.source_workspace_id or "") or {}
            if source.get("is_read"):
                raise SmokeFailure("the other Mac's record turned read although nobody clicked the mirror pane")
            held = self.indicators(mirror_surface)
            if not self.is_lit(held, mirror_surface):
                raise SmokeFailure(f"the mirror pane's ring went away on its own: {held}")
            clicked = self.click_until_cleared("a click to clear the mirror pane's ring and badges", mirror_surface)
            copy = self.wait_read("the mirror copy to turn read after the click", title, self.mirror_workspace_id or "")
            source = self.wait_read("the source record to turn read after the mirror click", title, self.source_workspace_id or "")
            return {
                "overrides": overrides,
                "lit": lit,
                **clicked,
                "mirror_copy_is_read": copy.get("is_read"),
                "source_is_read": source.get("is_read"),
            }
        finally:
            self.reset_overrides()

    def wait_cleared(self, description: str, surface_id: str) -> Dict[str, Any]:
        def probe() -> Optional[Dict[str, Any]]:
            state = self.indicators(surface_id)
            return state if self.is_cleared(state) else None

        try:
            return wait_for(description, probe, self.timeout_s)
        except SmokeFailure as error:
            raise SmokeFailure(f"{error}; last indicators {self.indicators(surface_id)}") from None

    def check_host_read_clears_focused_mirror_ring(self) -> Dict[str, Any]:
        mirror_surface = self.facts["mirror_surface_id"]
        self.select(self.mirror_workspace_id or "", mirror_surface)
        self.app_focus("active")
        overrides = self.overrides(presence="present", window_key="key")
        try:
            title = f"e2e-host-read-ring-{self.nonce}"
            self.notify_socket(self.facts["source_surface_id"], title, "read on the other Mac")
            self.mirror_copy(title)
            lit = self.wait_lit("the focused mirror pane's ring before the host read", mirror_surface)
            source = self.source_record(title)
            # The read happens on the host side (the source record), not here.
            self.client.call("notification.mark_read", {"id": source["id"]})
            copy = self.wait_read("the mirror copy to turn read after the host read", title, self.mirror_workspace_id or "")
            cleared = self.wait_cleared("the host read to clear the focused mirror pane's ring and badges", mirror_surface)
            return {"overrides": overrides, "lit": lit, "cleared": cleared, "mirror_copy_is_read": copy.get("is_read")}
        finally:
            self.reset_overrides()

    def check_newer_mirror_copy_keeps_ring(self) -> Dict[str, Any]:
        mirror_surface = self.facts["mirror_surface_id"]
        self.select(self.mirror_workspace_id or "", mirror_surface)
        self.app_focus("active")
        overrides = self.overrides(presence="present", window_key="key")
        try:
            older = f"e2e-older-{self.nonce}"
            newer = f"e2e-newer-{self.nonce}"
            self.notify_socket(self.facts["source_surface_id"], older, "the first of two")
            self.mirror_copy(older)
            self.wait_lit("the focused mirror pane's ring for the first copy", mirror_surface)
            # The second notification on the same terminal supersedes the first
            # on the host (its row turns read there); the newer copy stays unread
            # and owns the pane's ring.
            self.notify_socket(self.facts["source_surface_id"], newer, "the second of two")
            newer_copy = self.mirror_copy(newer)
            self.wait_read("the older copy to turn read after the host superseded it", older, self.mirror_workspace_id or "")
            time.sleep(1.5)
            held = self.indicators(mirror_surface)
            if not self.is_lit(held, mirror_surface):
                raise SmokeFailure(
                    f"the host's read of the older notification wiped the ring the newer unread copy set: {held}"
                )
            source = self.source_record(newer)
            self.client.call("notification.mark_read", {"id": source["id"]})
            self.wait_read("the newer copy to turn read after the host read", newer, self.mirror_workspace_id or "")
            cleared = self.wait_cleared("the host read of the last copy to clear the mirror pane's ring", mirror_surface)
            return {"overrides": overrides, "held": held, "cleared": cleared, "newer_copy_id": newer_copy.get("id")}
        finally:
            self.reset_overrides()

    def check_mirror_read_clears_focused_source_ring(self) -> Dict[str, Any]:
        workspace_id = self.source_workspace_id or ""
        surface_id = self.facts["source_surface_id"]
        self.select(workspace_id, surface_id)
        self.app_focus("active")
        overrides = self.overrides(presence="present", window_key="key")
        try:
            title = f"e2e-mirror-read-ring-{self.nonce}"
            self.notify_socket(surface_id, title, "read on the other Mac")
            lit = self.wait_lit("the focused source pane's ring before the mirror read", surface_id)
            copy = self.mirror_copy(title)
            # The read happens on the viewer side (the mirror copy); it reaches
            # the host as `notification.feed.mark_read` from a Mac peer.
            self.client.call("notification.mark_read", {"id": copy["id"]})
            source = self.wait_read("the source record to turn read after the mirror read", title, workspace_id)
            cleared = self.wait_cleared("the mirror read to clear the focused source pane's ring and badges", surface_id)
            return {"overrides": overrides, "lit": lit, "cleared": cleared, "source_is_read": source.get("is_read")}
        finally:
            self.reset_overrides()

    def check_focused_pane_rings_until_click(self) -> Dict[str, Any]:
        workspace_id = self.source_workspace_id or ""
        surface_id = self.facts["source_surface_id"]
        self.select(workspace_id, surface_id)
        self.app_focus("active")
        overrides = self.overrides(presence="present", window_key="key")
        try:
            title = f"e2e-focused-ring-{self.nonce}"
            self.notify_socket(surface_id, title, "the focused pane's agent finished")
            record = self.source_record(title)
            if record.get("is_read"):
                raise SmokeFailure("the focused pane's notification was recorded read")
            lit = self.wait_lit("the focused pane's ring, tab badge and workspace badge", surface_id)
            screenshot = self.screenshot("focused-ring")
            time.sleep(1.5)
            held = self.indicators(surface_id)
            if not self.is_lit(held, surface_id):
                raise SmokeFailure(f"the focused pane's ring went away on its own: {held}")
            decision = wait_for("the focused pane's push decision", lambda: self.decision_for(record["id"]), self.timeout_s)
            if decision.get("direct") != "skip_focused_pane":
                raise SmokeFailure(f"direct lane verdict {decision.get('direct')!r} for a present user's focused pane")
            clicked = self.click_until_cleared("a click to clear the focused pane's ring and badges", surface_id)
            record = self.wait_read("the focused pane's record to turn read after the click", title, workspace_id)
            return {
                "overrides": overrides,
                "lit": lit,
                "screenshot": screenshot,
                "direct": decision.get("direct"),
                **clicked,
                "is_read_after_click": record.get("is_read"),
            }
        finally:
            self.reset_overrides()

    def check_unattended_host_keeps_unread(self) -> Dict[str, Any]:
        self.select(self.source_workspace_id or "", self.facts["source_surface_id"])
        self.app_focus("active")
        try:
            self.overrides(presence="away", window_key="key")
            away_title = f"e2e-away-{self.nonce}"
            self.notify_socket(self.facts["source_surface_id"], away_title, "nobody at the Mac")
            away = self.source_record(away_title)
            away_decision = wait_for("the away decision", lambda: self.decision_for(away["id"]), self.timeout_s)
            if away.get("is_read"):
                raise SmokeFailure("an away Mac swallowed the focused pane's notification (recorded read)")
            if away_decision.get("direct") == "skip_focused_pane":
                raise SmokeFailure("the direct lane skipped an away Mac's notification as focused")

            self.overrides(presence="present")
            present_title = f"e2e-present-{self.nonce}"
            self.notify_socket(self.facts["source_surface_id"], present_title, "someone at the Mac")
            present = self.source_record(present_title)
            present_decision = wait_for("the present decision", lambda: self.decision_for(present["id"]), self.timeout_s)
            if present.get("is_read"):
                raise SmokeFailure("a present user's focused pane recorded the notification read")
            if present_decision.get("direct") != "skip_focused_pane":
                raise SmokeFailure(f"present decision {present_decision.get('direct')!r}, expected skip_focused_pane")
            return {
                "away": {"is_read": away.get("is_read"), "direct": away_decision.get("direct")},
                "present": {"is_read": present.get("is_read"), "direct": present_decision.get("direct")},
            }
        finally:
            self.reset_overrides()
            self.client.call("notification.mark_read", {"workspace_id": self.source_workspace_id})

    def check_app_focused_setting_keeps_background_unread(self) -> Dict[str, Any]:
        stored_before = self.overrides().get("suppress_when_app_focused_stored")
        selected = self.look_away_from_source_and_mirror()
        self.app_focus("active")
        try:
            settings = self.overrides(presence="present", window_key="key", suppress_when_app_focused=True)
            if settings.get("suppress_when_app_focused") is not True:
                raise SmokeFailure(f"could not turn on suppressWhenAppFocused: {settings}")
            title = f"e2e-app-focused-{self.nonce}"
            self.notify_socket(self.facts["source_surface_id"], title, "a pane nobody is looking at")
            source = self.source_record(title)
            decision = wait_for("the source decision", lambda: self.decision_for(source["id"]), self.timeout_s)
            # A source recorded read never reaches the mirror (read rows are
            # not delivered), so check it before waiting for the copy.
            if source.get("is_read"):
                raise SmokeFailure("suppressWhenAppFocused recorded a background pane's notification read")
            if decision.get("direct") == "skip_focused_pane":
                raise SmokeFailure("the direct lane skipped a background pane as the focused pane")
            self.mirror_copy(title)
            time.sleep(1.5)
            source = self.record_titled(title, self.source_workspace_id or "") or {}
            copy = self.record_titled(title, self.mirror_workspace_id or "") or {}
            if copy.get("is_read"):
                raise SmokeFailure("suppressWhenAppFocused recorded a background mirror pane's copy read")
            if source.get("is_read"):
                raise SmokeFailure("the mirror acknowledged a background pane's notification to the host")
            return {
                "selected_workspaces": selected,
                "source_is_read": source.get("is_read"),
                "mirror_copy_is_read": copy.get("is_read"),
                "direct": decision.get("direct"),
            }
        finally:
            self.overrides(suppress_when_app_focused="live" if stored_before is None else bool(stored_before))
            self.reset_overrides()
            for workspace_id in (self.source_workspace_id, self.mirror_workspace_id):
                self.client.call("notification.mark_read", {"workspace_id": workspace_id})

    def check_burst_rows_all_delivered(self) -> Dict[str, Any]:
        surfaces = [self.facts["source_surface_id"]]
        while len(surfaces) < 7:
            # New terminal tabs, not splits: a background window has no room for 7 panes.
            created = self.client.call(
                "surface.create",
                {"workspace_id": self.source_workspace_id, "type": "terminal", "focus": False},
            ) or {}
            if not created.get("surface_id"):
                raise SmokeFailure(f"surface.create returned no surface: {created}")
            surfaces.append(str(created["surface_id"]))
        # The device must know the new terminals belong to the source workspace;
        # rows for terminals the mirror does not project yet land on the mirror
        # workspace itself (upstream placement fallback).
        def device_knows_terminals() -> bool:
            for device in (self.client.call("supermux.devices.list", {}) or {}).get("devices") or []:
                for record in device.get("records") or []:
                    if norm(record.get("id")) == norm(self.source_workspace_id):
                        return int(record.get("terminal_count") or 0) >= len(surfaces)
            return False

        wait_for("the device to list all 7 source terminals", device_knows_terminals, self.timeout_s)
        # Let the admission bucket refill from the earlier steps.
        time.sleep(6)
        titles = [f"e2e-burst-{i}-{self.nonce}" for i in range(len(surfaces))]
        retries_before = int(self.hook("phone_push_debug").get("retries_fired") or 0)
        started = time.monotonic()
        for surface, title in zip(surfaces, titles):
            self.notify_socket(surface, title, f"burst {title}")

        def delivered() -> Optional[List[str]]:
            mirror_titles = {r.get("title") for r in self.records() if norm(r.get("workspace_id")) == norm(self.mirror_workspace_id)}
            missing = [t for t in titles if t not in mirror_titles]
            if missing:
                raise SmokeFailure(f"{len(missing)} burst rows not on the mirror yet")
            return titles

        wait_for("every burst row on the mirror", delivered, 20)
        seconds = round(time.monotonic() - started, 2)
        # Reported, not asserted: a catalog change can also refold declined rows
        # before the timer does.
        retries = int(self.hook("phone_push_debug").get("retries_fired") or 0) - retries_before
        return {"rows": len(titles), "seconds_to_all_delivered": seconds, "timer_retries_fired": retries}

    def check_phone_push_status_over_link(self) -> Dict[str, Any]:
        status = self.link_request("mobile.supermux.phone_push.status")
        text = json.dumps(status)
        if "PRIVATE KEY" in text or "p8" in status:
            raise SmokeFailure("phone_push.status leaked key material")
        if status.get("bundle_id") != APNS_BUNDLE or not isinstance(status.get("has_credentials"), bool):
            raise SmokeFailure(f"unexpected status {status}")
        if not isinstance(status.get("registration_count"), int) or not isinstance(status.get("share_enabled"), bool):
            raise SmokeFailure(f"unexpected status {status}")
        caps = (self.client.call("supermux.devices.list", {"include_capabilities": True}) or {}).get("devices") or []
        loopback = next((d for d in caps if d.get("machine") == self.facts["machine"]), {})
        if "supermux.phone_push_share.v1" not in (loopback.get("capabilities") or []):
            raise SmokeFailure("the host does not advertise supermux.phone_push_share.v1")
        return {"status": status}

    def check_share_refused_for_non_mac_callers(self) -> Dict[str, Any]:
        refusals = {}
        for caller in ("ios", "stack_bearer", "none"):
            probe = self.hook("phone_push_probe", {"caller": caller, "method": "share", "params": {}})
            code = (probe.get("error") or {}).get("code")
            if probe.get("ok") is not False or code != "forbidden":
                raise SmokeFailure(f"share from {caller} was not refused: {probe}")
            refusals[caller] = code
        status_from_phone = self.hook("phone_push_probe", {"caller": "ios", "method": "status"})
        if status_from_phone.get("ok") is not True:
            raise SmokeFailure(f"status from a phone should be served: {status_from_phone}")
        return {"refusals": refusals, "status_from_phone_ok": True}

    def check_share_over_mac_link(self) -> Dict[str, Any]:
        key_pem = mint_p256_key()
        token = "ab" * 32
        share = self.link_request("mobile.supermux.phone_push.share", {
            "config": {"team_id": "TEAM123456", "key_id": "KEY1234567"},
            "p8": key_pem,
            "registrations": [{"device_token": token, "bundle_id": APNS_BUNDLE, "environment": "production"}],
        })
        if share.get("credentials") != "install" or share.get("registrations_added") != 1:
            raise SmokeFailure(f"first share not installed: {share}")
        key_path = self.push_state_dir / "supermux-apns-auth-key.p8"
        config_path = self.push_state_dir / "supermux-apns.json"
        devices_path = self.push_state_dir / "supermux-apns-devices.json"
        modes = {
            "dir": oct(stat.S_IMODE(self.push_state_dir.stat().st_mode)),
            "key": oct(stat.S_IMODE(key_path.stat().st_mode)),
            "config": oct(stat.S_IMODE(config_path.stat().st_mode)),
            "devices": oct(stat.S_IMODE(devices_path.stat().st_mode)),
        }
        if modes != {"dir": "0o700", "key": "0o600", "config": "0o600", "devices": "0o600"}:
            raise SmokeFailure(f"unexpected permissions {modes}")
        key_hash = hashlib.sha256(key_path.read_bytes()).hexdigest()
        status = self.link_request("mobile.supermux.phone_push.status")
        if not status.get("has_credentials") or status.get("key_id") != "KEY1234567" or status.get("registration_count") != 1:
            raise SmokeFailure(f"status after install: {status}")

        conflict = self.link_request("mobile.supermux.phone_push.share", {
            "config": {"team_id": "TEAM123456", "key_id": "OTHERKEY99"},
            "p8": mint_p256_key(),
            "registrations": [
                {"device_token": token, "bundle_id": APNS_BUNDLE, "environment": "production"},
                {"device_token": "cd" * 32, "bundle_id": APNS_BUNDLE, "environment": "sandbox"},
            ],
        })
        if conflict.get("credentials") != "conflict" or conflict.get("registrations_added") != 1:
            raise SmokeFailure(f"conflicting share: {conflict}")
        if hashlib.sha256(key_path.read_bytes()).hexdigest() != key_hash:
            raise SmokeFailure("a conflicting share changed the installed key")

        coordinator = self.hook("phone_push_share_now", {"machine": self.facts["machine"]}).get("result")
        return {
            "first_share": share,
            "permissions": modes,
            "status_after_install": status,
            "conflicting_share": conflict,
            "coordinator_on_self_link": coordinator,
        }

    # -- lifecycle ------------------------------------------------------------

    def reset_overrides(self) -> None:
        try:
            self.overrides(presence="live", window_key="live")
            self.app_focus("clear")
        except SmokeFailure as error:
            self.facts.setdefault("cleanup_errors", []).append(str(error))

    def cleanup(self) -> None:
        self.reset_overrides()
        for name in ("supermux-apns-auth-key.p8", "supermux-apns.json", "supermux-apns-devices.json"):
            path = self.push_state_dir / name
            if path.exists():
                path.unlink()
        if self.keep:
            return
        super().cleanup()
        for workspace_id in self.facts.get("other_workspaces_created") or []:
            try:
                self.client.call("workspace.close", {"workspace_id": workspace_id, "force": True})
            except SmokeFailure as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))
        if self.project_id:
            try:
                self.link_request("mobile.supermux.project.delete", {"project_id": self.project_id})
            except SmokeFailure as error:
                self.facts.setdefault("cleanup_errors", []).append(str(error))
        if self.project_root and self.project_root.exists():
            shutil.rmtree(self.project_root, ignore_errors=True)

    def run(self) -> bool:
        steps: List[tuple] = [
            ("device_connected", self.check_device_connected),
            ("scratch_push_state", self.check_scratch_push_state),
            ("source_and_mirror", self.create_project_source_and_mirror),
            ("notification_reaches_mirror", self.check_notification_reaches_mirror),
            ("viewer_skips_phone", self.check_viewer_skips_phone),
            ("host_read_marks_mirror_read", self.check_host_read_marks_mirror_read),
            ("mark_unread_survives_host_feed", self.check_mark_unread_survives_host_feed),
            ("mirror_read_marks_host_read", self.check_mirror_read_marks_host_read),
            ("focused_mirror_arrival_rings_until_click", self.check_focused_mirror_arrival_rings_until_click),
            ("host_read_clears_focused_mirror_ring", self.check_host_read_clears_focused_mirror_ring),
            ("newer_mirror_copy_keeps_ring", self.check_newer_mirror_copy_keeps_ring),
            ("focused_pane_rings_until_click", self.check_focused_pane_rings_until_click),
            ("mirror_read_clears_focused_source_ring", self.check_mirror_read_clears_focused_source_ring),
            ("unattended_host_keeps_unread", self.check_unattended_host_keeps_unread),
            ("app_focused_setting_keeps_background_unread", self.check_app_focused_setting_keeps_background_unread),
            ("burst_rows_all_delivered", self.check_burst_rows_all_delivered),
            ("phone_push_status_over_link", self.check_phone_push_status_over_link),
            ("share_refused_for_non_mac_callers", self.check_share_refused_for_non_mac_callers),
            ("share_over_mac_link", self.check_share_over_mac_link),
        ]
        ok = True

        def guarded(action: Callable[[], Dict[str, Any]]) -> Callable[[], Dict[str, Any]]:
            def run_action() -> Dict[str, Any]:
                try:
                    return action()
                except KeyError as missing:
                    raise SmokeFailure(f"skipped: an earlier step did not produce {missing}") from None
            return run_action

        try:
            # Like the smoke it extends, the suite opens its own mirror with
            # vm.workspace_open; with auto-mirror on that mirror would be a
            # duplicate of the auto-opened one and be closed.
            self.pause_auto_mirror()
            for name, action in steps:
                try:
                    self.step(name, guarded(action))
                except SmokeFailure:
                    ok = False
                    # The first three steps are prerequisites for the rest.
                    if name in ("device_connected", "scratch_push_state", "source_and_mirror"):
                        return False
            return ok
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.steps.append({"name": "transport", "ok": False, "error": str(error)})
            return False
        finally:
            self.cleanup()
            self.restore_auto_mirror()


def mint_p256_key() -> str:
    """A throwaway PKCS#8 P-256 key, never used to sign anything real."""
    generated = subprocess.run(
        ["/usr/bin/openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout"],
        check=True, capture_output=True,
    ).stdout
    pkcs8 = subprocess.run(
        ["/usr/bin/openssl", "pkcs8", "-topk8", "-nocrypt"],
        input=generated, check=True, capture_output=True,
    ).stdout
    return pkcs8.decode("ascii")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"), help="tagged build (default: $CMUX_TAG)")
    parser.add_argument("--socket", default=os.environ.get("CMUX_SOCKET_PATH"), help="override the control socket path")
    parser.add_argument("--push-state-dir", required=True, help="the SUPERMUX_PHONE_PUSH_STATE_DIR the app was launched with")
    parser.add_argument("--work-dir", help="scratch directory for the test git repo (default: /tmp/<tag>)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for each check")
    parser.add_argument("--keep", action="store_true", help="leave the source and mirror workspaces open")
    parser.add_argument("--report", help="report path (default: tests/supermux/artifacts/loopback_notifications_e2e-<tag>.json)")
    args = parser.parse_args()
    if not args.tag:
        parser.error("set CMUX_TAG (or pass --tag)")
    socket_path = args.socket or socket_path_for_tag(args.tag)
    push_state_dir = Path(args.push_state_dir).expanduser()
    # Resolved (/tmp is /private/tmp): project roots and shell directories must
    # spell the same path for the host to associate the workspace.
    work_dir = Path(args.work_dir or f"/tmp/{args.tag}").expanduser()
    work_dir.mkdir(parents=True, exist_ok=True)
    work_dir = work_dir.resolve()

    report_path = Path(args.report) if args.report else ARTIFACTS_DIR / f"loopback_notifications_e2e-{args.tag}.json"
    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with SocketClient(socket_path, timeout_s=90) as client:
            e2e = NotificationsE2E(client, args.tag, args.timeout, args.keep, push_state_dir, work_dir, report_path)
            passed = e2e.run()
            steps, facts = e2e.steps, e2e.facts
    except OSError as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{socket_path}: {error}"}], {}

    report = {
        "suite": "supermux-loopback-notifications-e2e",
        "tag": args.tag,
        "socket": socket_path,
        "started_at": started_at,
        "passed": passed,
        "steps": steps,
        "facts": facts,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"report: {report_path}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
