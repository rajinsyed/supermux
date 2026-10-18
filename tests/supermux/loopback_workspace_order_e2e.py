#!/usr/bin/env python3
"""End-to-end test of one shared workspace and project order across Macs and
the iPhone, against one tagged DEBUG build running the loopback device.

The loopback device ("Loopback Mac") is this same app's own mobile host, so
every local (own) workspace also has a mirror, and the mirror's remote id is
its source's id. A mirror's order key is therefore its source's key, and an
own row sorts before its mirror on a tie. That gives one oracle for the whole
suite: every mirror sits immediately after its source (a grouped source's
mirrors sit right after the whole group). Every phone request goes through
`supermux.devices.request`, which reaches the exact handlers a phone's request
does. Each workspace has one order key, written only by the Mac that owns it;
every other device places its rows by those keys.

Invariants, waited for after every mutating step:

  C1 adjacency       in each window, every scratch source is directly followed by
                     its mirror (a group's mirrors directly follow the group)
  C2 keys on wire    every scratch row of `mobile.workspace.list` carries a valid
                     `supermux_order_key` (rocicorp fractional index, <= 128 chars),
                     and its v2 record (`mobile.sync.fetch`) carries the same key
  C3 phone == Mac    the phone's order (a stdlib port of the shared comparator:
                     tier, group unit, key, id) of each window's scratch rows is
                     that window's own scratch rows in tab order
  C4 owner keys      in `supermux.devices.order_state`, the own scratch rows' keys
                     strictly increase in tab order within each pin tier

Steps:

   1. setup                       the loopback linked and fetched, auto-mirror on;
                                  `mobile.host.status` lists supermux.order_sync.v1;
                                  `order_debug {mode: normal}`
   2. scratch_rows                four new workspaces W1..W4 (named by the tab order
                                  upstream gave them) and their mirrors M1..M4: C1-C4,
                                  and no own row moved (migration moves only mirrors)
   3. mac_reorder_moves_mirrors   `workspace.reorder` W4 before W1: own order W4, W1,
                                  W2, W3 with M4 directly after W4; C1-C4; W4's key
                                  written once, nothing sent to an owner, apply ran
   4. move_to_top_action          `workspace.action move_top` on W3: W3 first among the
                                  scratch rows, M3 right after; C1-C4
   5. old_phone_move              the phone's `workspace.move` W1 before W4: M1 right
                                  after W1; C1-C4
   6. mirror_drag_moves_source    M2 dragged above the first scratch row: W2 (its
                                  owner's row) becomes the first scratch row with M2
                                  right after; one set_order sent, received, none
                                  refused; W2's key written exactly once
   7. phone_set_order             a key minted between two adjacent own rows Wa, Wb
                                  (`order_key_between`), sent for the last own row Wx
                                  with `mobile.supermux.workspace.set_order`: the reply
                                  echoes it and Wx (with Mx) sits between Wa/Ma and Wb
   8. key_only_set_order          a key minted between the second and third own rows,
                                  sent for the second: no tab moves, yet the legacy
                                  list carries the new key within 2 s and the Mac emits
                                  `workspace.updated` (a phone that holds this Mac as a
                                  secondary refetches only on that event)
   9. set_order_rejects           a mirror id, a stale `is_pinned`, a malformed key and
                                  an unknown id answer not_owned, conflict,
                                  invalid_params and not_found; nothing moves
  10. new_workspace_keyed         a workspace created after W2 (W5) stays where upstream
                                  put it, M5 right after it; no set_order sent
  11. pin_tier                    W3 pinned: W3 and its mirrored-pin M3 lead the window,
                                  the phone puts W3 before every unpinned scratch row;
                                  unpinned again: C1-C4; no set_order sent
  12. notification_bump           a notification on the last scratch row (W1 selected)
                                  bumps it first among unpinned rows, its mirror right
                                  after; C3 (skipped when the auto-reorder setting is off)
  13. group_unit                  W1, W2 grouped: the window reads ...W1, W2, M1, M2...;
                                  the phone's unit-aware arrange is the Mac's own order;
                                  apply stops rising within 3 s; ungrouped: C1-C4
  14. group_clamped_set_order     the first two own rows grouped; set_order asks the
                                  group's last (non-anchor) member for a key after every
                                  own row: the group clamp keeps it in place, so the
                                  reply and the stored key are its old key (C4 holds),
                                  and no row moves
  15. local_group_pin_not_sent    a mirror alone in a local group G, an own row alone in
                                  a group H, both groups pinned, then G moved to the
                                  other side of H: the mirror is pinned only by its
                                  local group, so no set_order is sent
  16. nested_rows_follow_order    a project with three worktree workspaces P1..P3: its
                                  nested rows read P1, MP1, P2, MP2, P3, MP3; MP3 dragged
                                  above P1: P3, MP3, P1, MP1, P2, MP2, and the phone's
                                  nested order reads P3, P1, P2
  17. cross_window_move           W2 moved to a new window: it is that window's last row
                                  and stays there for 2 s, its key above every key before
                                  it there; C3; moved back, the window closed
  18. projects_order              two scratch projects P, Q (the app writes the scratch
                                  --projects-file, never the user's): unstamped at first;
                                  `project_move` Q over P stamps every project and lists
                                  Q before P (projects.list and the sidebar);
                                  `projects.set_order` P with an older stamp is refused,
                                  a newer one puts P before Q
  19. owner_offline_drag_beeps    the loopback transport dropped until the link is down:
                                  a mirror dragged first snaps back with one beep (the
                                  owner is unreachable, not an old host); after the
                                  link returns: C1-C4
  20. old_host_fallback           `order_debug old_host` + link restart: no capability,
                                  no keys, nested rows in per-device blocks again. Then
                                  `old_peer` (the owner still old, this Mac's reconciler
                                  running again, as an up-to-date viewer next to an old
                                  owner Mac): a mirror dropped first stays there for 2 s
                                  though passes ran, its source does not move, no
                                  set_order sent. Back to normal + link restart: C1-C4,
                                  the own order and W2's key unchanged, still no
                                  set_order sent
  21. quiescence                  5 s idle: tabs, keys and pending keys unchanged; no key
                                  writes, applies or set_order sends
  22. relaunch                    (--relaunch, needs --app-path; the runner passes both)
                                  every scratch notification read, then quit the tagged
                                  app, wait for its process to exit and relaunch it:
                                  every scratch row keeps its key, the main window's own
                                  scratch order is identical; C1
  23. sidebar_screenshot          the window, for the report

What it guards against: an upgrade that moves this Mac's own rows (2); a reorder
entry point that skips the keys (3-5, 10-13, 16, 17); a mirror drag that never
reaches its owner (6); a key-only change a secondary phone never hears of (8);
apply's own moves or the fork's sibling placement and mirrored pin sent to an
owner as user moves (10, 11, 21); a group split by apply (13); a clamped
set_order that stores a key the row does not sit at (14); a local group's pin
sent to an owner (15); nested rows kept Mac by Mac (16); a cross-window drop
moved away (17); an older project stamp winning or an upgrade stamping projects
(18); a silent snap-back while the owner is offline (19); an old host, an
unkeyed mirror placed or sent by an up-to-date viewer, and a resume that moves
the owner's rows (20); an echo loop (21); keys lost on restore (22); and leaked scratch state (cleanup).

A step that needs a command this build does not serve (the DEBUG order
commands, the set_order RPCs) fails at once with a message naming it, and the
suite moves on. Behavioural checks run before those, so on a build without
order sync, steps 3, 6 and 13 fail on what the sidebar shows.

Writes a JSON report (default tests/supermux/artifacts/loopback_workspace_order_e2e-<tag>.json)
holding, per step, the tabs of every window before and after, the keys, the
phone order, the counters and the timing, plus the sidebar screenshot next to
it. Exits non-zero on any failure. Creates and removes all of its own state
(workspaces, projects, the group, the extra window, the order_debug mode).
Stdlib only.

Usage:
  CMUX_TAG=<tag> python3 tests/supermux/loopback_workspace_order_e2e.py \\
      [--scratch /tmp/<tag>-e2e/order] [--projects-file /tmp/<tag>-e2e/projects.json] \\
      [--app-path "<App path printed by reload.sh>" [--relaunch]] [--report PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import time
import traceback
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
from loopback_auto_mirror_e2e import (  # noqa: E402
    ARTIFACTS_DIR,
    LOOPBACK_DEVICE_ID,
    Failure,
    Socket,
    hold,
    socket_path_for_tag,
    up,
    wait_for,
)

CAPABILITY = "supermux.order_sync.v1"
SET_ORDER = "mobile.supermux.workspace.set_order"
PROJECTS_SET_ORDER = "mobile.supermux.projects.set_order"
DEBUG_PREFIX = "supermux.devices."
# A rocicorp-valid key, for requests whose key only has to parse.
VALID_KEY = "a0"
BASE_62_DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
SMALLEST_INTEGER = "A" + "0" * 26
MAX_KEY_LENGTH = 128
# How long one call keeps retrying the socket's per-connection polling limit.
RATE_LIMIT_PATIENCE_S = 10.0
# The app's UserDefaults key behind `app.reorderOnNotification`.
REORDER_ON_NOTIFICATION_DEFAULT = "workspaceAutoReorderOnNotification"


class Unavailable(Exception):
    """A command this suite needs is not served by this build (yet). Not a
    `Failure`, so `wait_for` does not retry it: the step fails at once."""


# -- the shared order, ported --------------------------------------------------

def is_valid_key(key: Any) -> bool:
    """`SupermuxOrderKey.isValid`: a rocicorp fractional-index key (base-62
    digits, a well-formed integer head, no trailing zero digit), <= 128 chars."""
    if not isinstance(key, str) or not key or len(key) > MAX_KEY_LENGTH:
        return False
    if any(c not in BASE_62_DIGITS for c in key) or key == SMALLEST_INTEGER:
        return False
    head = key[0]
    if "a" <= head <= "z":
        integer_length = ord(head) - ord("a") + 2
    elif "A" <= head <= "Z":
        integer_length = ord("Z") - ord(head) + 2
    else:
        return False
    return integer_length <= len(key) and not key[integer_length:].endswith("0")


def phone_arrange(rows: Sequence[Dict[str, Any]], groups: Sequence[Dict[str, Any]] = ()) -> List[str]:
    """`SupermuxOrderArrangement.arrange` as the phone calls it (nothing fixed):
    per pin tier (a grouped row takes its group's pin), group members gather
    into one unit ranked by its lowest (key, id) sort key; ranked units by
    rank, then unranked units in input order; members by sort key, unkeyed
    last. Returns the row ids (uppercase) in display order."""
    group_pins = {up(g.get("id")): bool(g.get("is_pinned")) for g in groups}
    by_tier: Dict[int, Dict[str, List[Any]]] = {0: {}, 1: {}}
    for row in rows:
        workspace_id, group = up(row.get("id")), up(row.get("group_id"))
        pinned = group_pins[group] if group in group_pins else bool(row.get("is_pinned"))
        tier = 0 if pinned else 1
        key = row.get("supermux_order_key")
        sort_key = (key, workspace_id, 0) if is_valid_key(key) else None
        unit = f"g:{group}/{tier}" if group else workspace_id
        by_tier[tier].setdefault(unit, []).append((sort_key, workspace_id))
    ordered: List[str] = []
    for tier in (0, 1):
        units = by_tier[tier]

        def rank(unit: str) -> Any:
            keyed = [sort_key for sort_key, _ in units[unit] if sort_key]
            return min(keyed) if keyed else None

        ranked = sorted((u for u in units if rank(u) is not None), key=rank)
        for unit in ranked + [u for u in units if rank(u) is None]:
            members = units[unit]
            ordered += [i for _, i in sorted((m for m in members if m[0]), key=lambda m: m[0])]
            ordered += [i for sort_key, i in members if not sort_key]
    return ordered


def git(*args: str, cwd: Path) -> None:
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise Failure(f"git {' '.join(args)}: {result.stderr.strip()}")


def git_repo(path: Path) -> Path:
    path.mkdir(parents=True)
    git("init", "-q", "-b", "main", cwd=path)
    git("-c", "user.email=e2e@example.com", "-c", "user.name=Supermux E2E", "commit", "-q", "--allow-empty",
        "-m", "init", cwd=path)
    return path


def moved_before(order: List[str], moved: str, anchor: str) -> List[str]:
    """`order` with `moved` taken out and put right before `anchor`."""
    rest = [i for i in order if i != moved]
    rest.insert(rest.index(anchor), moved)
    return rest


class WorkspaceOrderE2E:
    def __init__(self, sock: Socket, args: argparse.Namespace) -> None:
        self.sock = sock
        self.args = args
        self.timeout = args.timeout
        self.nonce = uuid.uuid4().hex[:6]
        self.root = Path(args.scratch) / f"order-{self.nonce}"
        self.steps: List[Dict[str, Any]] = []
        self.facts: Dict[str, Any] = {"nonce": self.nonce, "scratch": str(self.root)}
        self.machine = ""
        self.main_window = ""
        self.labels: Dict[str, str] = {}      # workspace id -> W1, P2, ...
        self.sources: List[str] = []          # own scratch workspaces (sources of mirrors)
        self.nested_project = ""
        self.projects: List[str] = []         # scratch project ids to delete
        self.group_id = ""
        self.extra_window = ""
        self.initial_auto_mirror: Optional[bool] = None
        self.debug_mode_touched = False

    # -- transport --------------------------------------------------------------

    def call(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Dict[str, Any]:
        """A socket call. The app rate-limits polling reads (`workspace.list`,
        `window.list`, ...) per connection and answers `rate_limited` with a
        retry hint; this suite polls a lot, so it waits and retries those."""
        deadline = time.monotonic() + RATE_LIMIT_PATIENCE_S
        while True:
            try:
                return self.sock.call(method, params or {}, timeout_s=timeout_s) or {}
            except Failure as error:
                if "rate_limited" not in str(error) or time.monotonic() > deadline:
                    raise
                time.sleep(0.15)

    def debug(self, name: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """A DEBUG `supermux.devices.<name>` command; Unavailable when this build lacks it."""
        try:
            return self.call(DEBUG_PREFIX + name, params)
        except Failure as error:
            if "method_not_found" in str(error):
                raise Unavailable(f"{DEBUG_PREFIX}{name} is not in this build ({error})") from None
            raise

    def phone(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: float = 60) -> Dict[str, Any]:
        """A request the way the phone sends it: to this Mac's mobile host."""
        try:
            result = self.call("supermux.devices.request", {
                "machine": self.machine, "method": method, "params": params or {}, "timeout_seconds": timeout_s,
            }, timeout_s=timeout_s + 5)
        except Failure as error:
            if "method_not_found" in str(error):
                raise Unavailable(f"{method} is not served by this build ({error})") from None
            raise Failure(f"{method}: {error}") from None
        if result.get("error"):
            raise Failure(f"{method}: {result.get('error')}")
        return result.get("result") or {}

    def phone_error(self, method: str, params: Dict[str, Any]) -> Optional[str]:
        """The error code the host answers `method` with, or None when it accepted it."""
        try:
            self.phone(method, params)
            return None
        except Unavailable:
            return "method_not_found"
        except Failure as error:
            # "<method>: supermux.devices.request: <code>: <message>"
            parts = str(error).split(": ")
            return parts[2] if len(parts) > 2 else str(error)

    # -- reads ------------------------------------------------------------------

    def loopback_device(self) -> Dict[str, Any]:
        for device in self.call("supermux.devices.list").get("devices") or []:
            if device.get("is_loopback") or str(device.get("device_id", "")).lower() == LOOPBACK_DEVICE_ID:
                return device
        raise Failure("no loopback device (launch with SUPERMUX_DEBUG_LOOPBACK_DEVICE=1)")

    def wait_connected(self) -> Dict[str, Any]:
        def ready() -> Optional[Dict[str, Any]]:
            device = self.loopback_device()
            if device.get("link_state") != "connected" or not device.get("has_fetched_records"):
                raise Failure(f"link_state={device.get('link_state')} fetched={device.get('has_fetched_records')}")
            return device

        return wait_for("the loopback device to connect", ready, self.timeout * 2)

    def windows(self) -> List[str]:
        return [up(w.get("id")) for w in self.call("window.list").get("windows") or []]

    def tab_rows(self, window: str) -> List[Dict[str, Any]]:
        return self.call("workspace.list", {"window_id": window}).get("workspaces") or []

    def tab_ids(self, window: str) -> List[str]:
        return [up(w.get("id")) for w in self.tab_rows(window)]

    def window_of(self, workspace_id: str) -> str:
        for window in self.windows():
            if workspace_id in self.tab_ids(window):
                return window
        raise Failure(f"{self.name(workspace_id)} is in no window")

    def mirror_map(self) -> Dict[str, str]:
        """Source id -> its loopback mirror's id."""
        mirrors = self.call("supermux.devices.bindings").get("mirrors") or []
        return {up(m.get("remote_workspace_id")): up(m.get("workspace_id")) for m in mirrors
                if m.get("machine") == self.machine}

    def mirror_of(self, source: str) -> str:
        mirror = self.mirror_map().get(source)
        if not mirror:
            raise Failure(f"{self.name(source)} has no mirror")
        return mirror

    def own_order(self, window: Optional[str] = None) -> List[str]:
        """The window's own scratch rows in tab order."""
        sources = set(self.sources)
        return [i for i in self.tab_ids(window or self.main_window) if i in sources]

    def scratch_tabs(self, window: Optional[str] = None) -> List[str]:
        """The window's scratch rows (own and mirror) in tab order."""
        scratch = set(self.sources) | set(self.mirror_map().values())
        return [i for i in self.tab_ids(window or self.main_window) if i in scratch]

    def phone_list(self) -> Dict[str, Any]:
        return self.phone("mobile.workspace.list")

    def phone_keys(self) -> Dict[str, Any]:
        """Own scratch row -> its `supermux_order_key` on the phone's list."""
        rows = {up(r.get("id")): r for r in self.phone_list().get("workspaces") or []}
        return {s: (rows.get(s) or {}).get("supermux_order_key") for s in self.sources}

    def phone_key(self, workspace_id: str) -> str:
        key = self.phone_keys().get(workspace_id)
        if not is_valid_key(key):
            raise Failure(f"{self.name(workspace_id)} has no valid supermux_order_key on mobile.workspace.list ({key!r})")
        return str(key)

    def phone_order(self, ids: Optional[Iterable[str]] = None) -> List[str]:
        """The phone's display order of `ids` (default: the scratch rows)."""
        listed = self.phone_list()
        wanted = set(ids if ids is not None else self.sources)
        return [i for i in phone_arrange(listed.get("workspaces") or [], listed.get("groups") or []) if i in wanted]

    def sync_records(self) -> List[Dict[str, Any]]:
        fetched = self.phone("mobile.sync.fetch", {"collections": [{"id": "workspaces"}]})
        return (fetched.get("workspaces") or {}).get("records") or []

    def order_state(self) -> Dict[str, Any]:
        return self.debug("order_state")

    def counters(self) -> Dict[str, Any]:
        return self.order_state().get("counters") or {}

    def counters_or_none(self) -> Optional[Dict[str, Any]]:
        try:
            return self.counters()
        except (Unavailable, Failure):
            return None

    def sidebar_projects(self) -> List[Dict[str, Any]]:
        return self.call("supermux.devices.sidebar_rows").get("projects") or []

    def nested_rows(self, project_id: str) -> List[str]:
        for project in self.sidebar_projects():
            if up(project.get("project_id")) == project_id:
                return [up(r.get("workspace_id")) for r in project.get("rows") or []]
        return []

    # -- naming -----------------------------------------------------------------

    def label(self, workspace_id: str, name: str) -> None:
        self.labels[workspace_id] = name
        if workspace_id not in self.sources:
            self.sources.append(workspace_id)
        self.facts.setdefault("workspaces", {})[name] = workspace_id

    def name(self, workspace_id: str, mirrors: Optional[Dict[str, str]] = None) -> str:
        if workspace_id in self.labels:
            return self.labels[workspace_id]
        for source, mirror in (mirrors if mirrors is not None else {}).items():
            if mirror == workspace_id and source in self.labels:
                source_name = self.labels[source]
                return "M" + (source_name[1:] if source_name.startswith("W") else source_name)
        return "~" + workspace_id[:6]

    def named(self, ids: Iterable[str]) -> List[str]:
        mirrors = self.mirror_map()
        return [self.name(i, mirrors) for i in ids]

    def id(self, name: str) -> str:
        return next(i for i, n in self.labels.items() if n == name)

    # -- invariants -------------------------------------------------------------

    def check_adjacency(self, units: Sequence[Sequence[str]] = ()) -> Dict[str, Any]:
        """C1: every scratch source directly followed by its mirror; the members
        of each unit in `units` contiguous, their mirrors right after the unit."""
        mirrors = self.mirror_map()
        grouped = {member for unit in units for member in unit}
        shown: Dict[str, List[str]] = {}
        for window in self.windows():
            ids = self.tab_ids(window)
            names = [self.name(i, mirrors) for i in ids]
            shown[window[:8]] = names
            for source in self.sources:
                if source not in ids or source in grouped:
                    continue
                mirror = mirrors.get(source)
                if not mirror:
                    raise Failure(f"{self.name(source)} has no mirror")
                if mirror not in ids:
                    continue  # the mirror lives in another window (a cross-window move)
                at = ids.index(source)
                if at + 1 >= len(ids) or ids[at + 1] != mirror:
                    raise Failure(f"{self.name(mirror, mirrors)} is not right after {self.name(source)}: {names}")
            for unit in units:
                members = [i for i in ids if i in set(unit)]
                if not members:
                    continue
                start = ids.index(members[0])
                if ids[start:start + len(members)] != members:
                    raise Failure(f"the group {self.named(unit)} is not contiguous: {names}")
                expected = [mirrors.get(m) for m in members]
                after = ids[start + len(members):start + 2 * len(members)]
                if after != expected:
                    raise Failure(f"the group's mirrors {[self.name(m or '', mirrors) for m in expected]} are not "
                                  f"right after {self.named(members)}: {names}")
        return shown

    def check_wire_keys(self) -> Dict[str, Any]:
        """C2: a valid key on every scratch row of the legacy list, the same key on its v2 record."""
        legacy = {up(r.get("id")): r for r in self.phone_list().get("workspaces") or []}
        records = {up(r.get("id")): r for r in self.sync_records()}
        problems: List[str] = []
        keys: Dict[str, Any] = {}
        for source in self.sources:
            row, record = legacy.get(source), records.get(source)
            if row is None or record is None:
                problems.append(f"{self.name(source)} missing from {'mobile.workspace.list' if row is None else 'the v2 records'}")
                continue
            key = row.get("supermux_order_key")
            keys[self.name(source)] = key
            if not is_valid_key(key):
                problems.append(f"{self.name(source)} carries no valid supermux_order_key on mobile.workspace.list ({key!r})")
            elif record.get("supermux_order_key") != key:
                problems.append(f"{self.name(source)}'s v2 record key {record.get('supermux_order_key')!r} != {key!r}")
        if problems:
            raise Failure("; ".join(problems))
        return keys

    def check_phone_order(self) -> Dict[str, Any]:
        """C3: per window, the phone's order of that window's scratch rows is its tab order."""
        phone = self.phone_order()
        shown: Dict[str, List[str]] = {}
        for window in self.windows():
            mac = self.own_order(window)
            if not mac:
                continue
            on_phone = [i for i in phone if i in set(mac)]
            if on_phone != mac:
                raise Failure(f"the phone shows {self.named(on_phone)}, the Mac's tabs {self.named(mac)}")
            shown[window[:8]] = self.named(mac)
        return shown

    def check_owner_keys(self) -> Dict[str, Any]:
        """C4: own scratch keys strictly increase in tab order within each tier."""
        sources = set(self.sources)
        found: Dict[str, Any] = {}
        for window in self.order_state().get("windows") or []:
            rows = [r for r in window.get("rows") or []
                    if not r.get("is_mirror") and up(r.get("workspace_id")) in sources]
            for tier in (0, 1):
                keyed = [(self.name(up(r.get("workspace_id"))), r.get("key")) for r in rows
                         if r.get("tier", 0 if r.get("is_pinned") else 1) == tier]
                if any(not is_valid_key(k) for _, k in keyed):
                    raise Failure(f"own rows without a valid key in order_state: {keyed}")
                if any(a[1] >= b[1] for a, b in zip(keyed, keyed[1:])):
                    raise Failure(f"own keys do not increase in tab order (tier {tier}): {keyed}")
                found.update(dict(keyed))
        return found

    def invariants(self, units: Sequence[Sequence[str]] = ()) -> Dict[str, Any]:
        return {
            "c1_tabs": wait_for("C1: every mirror right after its source", lambda: self.check_adjacency(units), self.timeout),
            "c2_keys": wait_for("C2: the same valid key on both transports", self.check_wire_keys, self.timeout),
            "c3_phone": wait_for("C3: the phone's order is the Mac's", self.check_phone_order, self.timeout),
            "c4_owner_keys": wait_for("C4: own keys increase in tab order", self.check_owner_keys, self.timeout),
        }

    def wait_order(self, expected: List[str], followed: Sequence[str] = (), first: Optional[str] = None) -> Dict[str, Any]:
        """Waits for the main window's own scratch order to be `expected`, each
        row in `followed` directly followed by its mirror, and `first` (when
        given) the first scratch row."""
        def settled() -> Optional[Dict[str, Any]]:
            own = self.own_order()
            if own != expected:
                raise Failure(f"own order {self.named(own)}, expected {self.named(expected)}")
            mirrors = self.mirror_map()
            ids = self.tab_ids(self.main_window)
            for source in followed:
                at = ids.index(source) if source in ids else len(ids)
                if at + 1 >= len(ids) or ids[at + 1] != mirrors.get(source):
                    raise Failure(f"{self.name(mirrors.get(source, ''), mirrors)} is not right after "
                                  f"{self.name(source)}: {self.named(ids)}")
            if first and self.scratch_tabs()[:1] != [first]:
                raise Failure(f"{self.name(first)} is not the first scratch row: {self.named(self.scratch_tabs())}")
            return {"own_order": self.named(own)}

        return wait_for(f"own order {self.named(expected)}", settled, self.timeout)

    def expect_counters(self, before: Optional[Dict[str, Any]], exact: Optional[Dict[str, int]] = None,
                        at_least: Optional[Dict[str, int]] = None,
                        writes: Optional[Dict[str, int]] = None) -> Dict[str, Any]:
        """Checks counter deltas since `before` (read before the action)."""
        after = self.counters()
        if before is None:
            raise Failure("the counters were not readable before the action")
        delta = {k: (after.get(k) or 0) - (before.get(k) or 0) for k in (exact or {}).keys() | (at_least or {}).keys()}
        problems = [f"{k} {delta[k]:+d}, expected {v:+d}" for k, v in (exact or {}).items() if delta[k] != v]
        problems += [f"{k} {delta[k]:+d}, expected at least {v:+d}" for k, v in (at_least or {}).items() if delta[k] < v]
        before_writes = {up(k): v for k, v in (before.get("own_key_writes_by_workspace") or {}).items()}
        after_writes = {up(k): v for k, v in (after.get("own_key_writes_by_workspace") or {}).items()}
        for workspace_id, count in (writes or {}).items():
            written = after_writes.get(workspace_id, 0) - before_writes.get(workspace_id, 0)
            delta[f"own_key_writes[{self.name(workspace_id)}]"] = written
            if written != count:
                problems.append(f"{self.name(workspace_id)}'s key written {written} times, expected {count}")
        if problems:
            raise Failure("; ".join(problems))
        return delta

    # -- actions ----------------------------------------------------------------

    def create_workspace(self, label: str) -> str:
        folder = self.root / label
        folder.mkdir(parents=True, exist_ok=True)
        created = self.call("workspace.create", {
            "title": f"order-{label}-{self.nonce}", "focus": False, "working_directory": str(folder),
        })
        workspace_id = up(created.get("workspace_id") or created.get("created_workspace_id"))
        if not workspace_id:
            raise Failure(f"workspace.create returned no id: {created}")
        self.sources.append(workspace_id)
        return workspace_id

    def create_project(self, folder: str) -> str:
        """A scratch git repo added as a project the way the phone adds one."""
        repo = git_repo(self.root / folder)
        project = self.phone("mobile.supermux.project.create", {"root_path": str(repo)}).get("project") or {}
        project_id = up(project.get("id"))
        if not project_id:
            raise Failure(f"project.create returned no project: {project}")
        self.projects.append(project_id)
        return project_id

    def wait_mirrors(self, sources: Iterable[str]) -> Dict[str, str]:
        wanted = list(sources)

        def all_mirrored() -> Optional[Dict[str, str]]:
            mirrors = self.mirror_map()
            missing = [self.name(s) for s in wanted if s not in mirrors]
            if missing:
                raise Failure(f"no mirror yet of {missing}")
            return {s: mirrors[s] for s in wanted}

        return wait_for("the mirrors", all_mirrored, self.timeout * 3)

    def attempt(self, description: str, action: Callable[[], Any]) -> bool:
        """Runs a restoring action without masking the step's own error."""
        try:
            action()
            return True
        except (Failure, Unavailable, OSError, ValueError) as error:
            self.facts.setdefault("cleanup_errors", []).append(f"{description}: {error}")
            return False

    def link_restart(self) -> None:
        self.call("supermux.devices.link", {"machine": self.machine, "action": "stop"})
        wait_for("the loopback link to drop", lambda: self.loopback_device().get("link_state") != "connected", self.timeout)
        self.call("supermux.devices.link", {"machine": self.machine, "action": "restore"})
        self.wait_connected()

    # -- report -----------------------------------------------------------------

    def snapshot(self) -> Dict[str, Any]:
        """What every party shows right now, for the report. Never raises."""
        snap: Dict[str, Any] = {}
        try:
            snap["tabs"] = {window[:8]: self.named(self.tab_ids(window)) for window in self.windows()}
        except Exception as error:  # noqa: BLE001 - a report never fails a step
            snap["tabs"] = f"unreadable: {error}"
        try:
            listed = self.phone_list()
            rows = {up(r.get("id")): r for r in listed.get("workspaces") or []}
            snap["keys"] = {self.name(s): (rows.get(s) or {}).get("supermux_order_key") for s in self.sources}
            arranged = phone_arrange(listed.get("workspaces") or [], listed.get("groups") or [])
            snap["phone_order"] = self.named([i for i in arranged if i in set(self.sources)])
        except Exception as error:  # noqa: BLE001
            snap["phone"] = f"unreadable: {error}"
        try:
            snap["counters"] = self.counters()
        except Exception as error:  # noqa: BLE001
            snap["counters"] = f"unreadable: {error}"
        return snap

    def step(self, name: str, action: Callable[[], Optional[Dict[str, Any]]]) -> bool:
        record: Dict[str, Any] = {"name": name, "before": self.snapshot()}
        started = time.monotonic()
        try:
            result = action() or {}
            record.update(result)
            record["ok"] = None if "skipped" in result else True
        except (Failure, Unavailable) as error:
            record["ok"] = False
            record["error"] = str(error)
        except Exception as error:  # noqa: BLE001 - a harness bug fails this step, not the suite
            record["ok"] = False
            record["error"] = f"harness error {type(error).__name__}: {error}"
            record["traceback"] = traceback.format_exc()
        record["seconds"] = round(time.monotonic() - started, 2)
        record["after"] = self.snapshot()
        self.steps.append(record)
        status = {True: "PASS", False: "FAIL", None: "SKIP"}[record["ok"]]
        detail = record.get("error") or record.get("skipped") or ""
        print(f"{status} {name} ({record['seconds']}s)" + (f": {detail}" if detail else ""), file=sys.stderr)
        return record["ok"] is not False

    # -- steps ------------------------------------------------------------------

    def setup(self) -> Dict[str, Any]:
        device = self.wait_connected()
        self.machine = device["machine"]
        self.initial_auto_mirror = self.call("supermux.devices.remote_macs_settings").get("auto_mirror")
        if not self.initial_auto_mirror:
            self.call("supermux.devices.set_auto_mirror", {"enabled": True})
        capabilities = self.phone("mobile.host.status").get("capabilities") or []
        if CAPABILITY not in capabilities:
            raise Failure(f"mobile.host.status does not list {CAPABILITY}")
        self.debug("order_debug", {"mode": "normal"})
        return {"machine": self.machine, "capability": CAPABILITY}

    def scratch_rows(self) -> Dict[str, Any]:
        created = [self.create_workspace(f"w{i}") for i in range(4)]
        self.main_window = self.window_of(created[0])
        self.facts["main_window"] = self.main_window
        # Named by where upstream put them, so "creation order" is this order.
        for index, workspace_id in enumerate(i for i in self.tab_ids(self.main_window) if i in set(created)):
            self.label(workspace_id, f"W{index + 1}")
        creation_order = self.own_order()
        self.wait_mirrors(created)
        result = self.invariants()
        if self.own_order() != creation_order:
            raise Failure(f"an own row moved: {self.named(creation_order)} -> {self.named(self.own_order())}")
        return {"creation_order": self.named(creation_order), **result}

    def mac_reorder_moves_mirrors(self) -> Dict[str, Any]:
        w1, w4 = self.id("W1"), self.id("W4")
        before = self.counters_or_none()
        expected = moved_before(self.own_order(), w4, w1)
        self.call("workspace.reorder", {"workspace_id": w4, "before_workspace_id": w1})
        order = self.wait_order(expected, followed=[w4])
        result = self.invariants()
        counters = self.expect_counters(before, exact={"set_order_sent": 0}, at_least={"applies": 1}, writes={w4: 1})
        return {**order, **result, "counters": counters}

    def move_to_top_action(self) -> Dict[str, Any]:
        w3 = self.id("W3")
        expected = [w3] + [i for i in self.own_order() if i != w3]
        self.call("workspace.action", {"workspace_id": w3, "action": "move_top"})
        return {**self.wait_order(expected, followed=[w3], first=w3), **self.invariants()}

    def old_phone_move(self) -> Dict[str, Any]:
        w1, w4 = self.id("W1"), self.id("W4")
        expected = moved_before(self.own_order(), w1, w4)
        self.phone("workspace.move", {"workspace_id": w1, "before_workspace_id": w4, "window_id": self.main_window})
        return {**self.wait_order(expected, followed=[w1]), **self.invariants()}

    def mirror_drag_moves_source(self) -> Dict[str, Any]:
        w2 = self.id("W2")
        m2 = self.mirror_of(w2)
        target = next(i for i in self.scratch_tabs() if i not in (w2, m2))
        before = self.counters_or_none()
        expected = [w2] + [i for i in self.own_order() if i != w2]
        self.call("workspace.reorder", {"workspace_id": m2, "before_workspace_id": target})
        order = self.wait_order(expected, followed=[w2], first=w2)
        result = self.invariants()
        counters = self.expect_counters(before, exact={
            "set_order_sent": 1, "set_order_received": 1, "set_order_refused": 0,
        }, writes={w2: 1})
        return {"dropped_before": self.name(target), **order, **result, "counters": counters}

    def phone_set_order(self) -> Dict[str, Any]:
        own = self.own_order()
        wa, wb, wx = own[0], own[1], own[-1]
        key = self.debug("order_key_between", {"lower": self.phone_key(wa), "upper": self.phone_key(wb)}).get("key")
        if not is_valid_key(key):
            raise Failure(f"order_key_between returned {key!r}")
        reply = self.phone(SET_ORDER, {"workspace_id": wx, "order_key": key, "is_pinned": False})
        if reply.get("order_key") != key or up(reply.get("workspace_id")) != wx:
            raise Failure(f"set_order answered {reply}, not {self.name(wx)} at {key!r}")
        expected = [wa, wx] + [i for i in own[1:] if i != wx]
        order = self.wait_order(expected, followed=[wa, wx])
        return {"between": self.named([wa, wb]), "moved": self.name(wx), "key": key, **order, **self.invariants()}

    def key_only_set_order(self) -> Dict[str, Any]:
        own = self.own_order()
        if len(own) < 3:
            raise Failure(f"needs three own rows: {self.named(own)}")
        wa, wb, wc = own[0], own[1], own[2]
        key = self.debug("order_key_between", {"lower": self.phone_key(wb), "upper": self.phone_key(wc)}).get("key")
        if not is_valid_key(key):
            raise Failure(f"order_key_between returned {key!r}")
        tabs_before = self.tab_ids(self.main_window)
        before = self.counters()
        reply = self.phone(SET_ORDER, {"workspace_id": wb, "order_key": key, "is_pinned": False})
        if reply.get("order_key") != key:
            raise Failure(f"set_order answered {reply}, not {self.name(wb)} at {key!r}")
        started = time.monotonic()
        wait_for(f"{self.name(wb)}'s new key on mobile.workspace.list",
                 lambda: self.phone_keys().get(wb) == key, 2.0, interval_s=0.2)
        listed_after_s = round(time.monotonic() - started, 2)

        def emitted() -> Optional[int]:
            delta = (self.counters().get("workspace_updated_emits") or 0) - (before.get("workspace_updated_emits") or 0)
            if delta < 1:
                raise Failure(f"workspace_updated_emits {delta:+d}")
            return delta

        emits = wait_for("a workspace.updated emit for the key-only change", emitted, 3.0, interval_s=0.2)
        if self.tab_ids(self.main_window) != tabs_before:
            raise Failure(f"a key-only set_order moved tabs: {self.named(tabs_before)} -> "
                          f"{self.named(self.tab_ids(self.main_window))}")
        return {"moved": self.name(wb), "between": self.named([wb, wc]), "key": key,
                "listed_after_s": listed_after_s, "workspace_updated_emits": emits,
                "own_order": self.named(self.own_order()), **self.invariants()}

    def set_order_rejects(self) -> Dict[str, Any]:
        target = self.own_order()[0]
        mirror = self.mirror_of(target)
        tabs_before = {w: self.tab_ids(w) for w in self.windows()}
        keys_before = self.phone_keys()
        cases = [
            ("mirror id", {"workspace_id": mirror, "order_key": VALID_KEY, "is_pinned": False}, "not_owned"),
            ("stale is_pinned", {"workspace_id": target, "order_key": VALID_KEY, "is_pinned": True}, "conflict"),
            ("malformed key", {"workspace_id": target, "order_key": "!!", "is_pinned": False}, "invalid_params"),
            ("unknown id", {"workspace_id": str(uuid.uuid4()).upper(), "order_key": VALID_KEY, "is_pinned": False}, "not_found"),
        ]
        answers = {label: self.phone_error(SET_ORDER, params) for label, params, _ in cases}
        wrong = {label: f"{answers[label]} (expected {code})" for label, _, code in cases if answers[label] != code}
        if wrong:
            raise Failure(f"set_order answered {wrong}")
        time.sleep(1.0)
        tabs_after = {w: self.tab_ids(w) for w in self.windows()}
        if tabs_after != tabs_before:
            raise Failure(f"a rejected set_order moved rows: {tabs_before} -> {tabs_after}")
        if self.phone_keys() != keys_before:
            raise Failure(f"a rejected set_order changed keys: {keys_before} -> {self.phone_keys()}")
        return {"answers": answers}

    def new_workspace_keyed(self) -> Dict[str, Any]:
        w2 = self.id("W2")
        before = self.counters_or_none()
        self.call("workspace.select", {"workspace_id": w2})
        w5 = self.create_workspace("w5")
        self.label(w5, "W5")
        placed = self.own_order(self.window_of(w5))
        self.wait_mirrors([w5])
        result = self.invariants()
        if self.own_order(self.window_of(w5)) != placed:
            raise Failure(f"an own row moved after the create: {self.named(placed)} -> "
                          f"{self.named(self.own_order(self.window_of(w5)))}")
        counters = self.expect_counters(before, exact={"set_order_sent": 0})
        return {"placed": self.named(placed), **result, "counters": counters}

    def is_pinned(self, workspace_id: str) -> bool:
        window = self.window_of(workspace_id)
        return any(up(w.get("id")) == workspace_id and w.get("pinned") for w in self.tab_rows(window))

    def pin_tier(self) -> Dict[str, Any]:
        w3 = self.id("W3")
        before = self.counters_or_none()
        self.call("workspace.action", {"workspace_id": w3, "action": "pin"})
        try:
            def pinned_first() -> Optional[Dict[str, Any]]:
                m3 = self.mirror_of(w3)
                rows = self.tab_rows(self.main_window)
                ids = [up(w.get("id")) for w in rows]
                pinned = [up(w.get("id")) for w in rows if w.get("pinned")]
                if w3 not in pinned or m3 not in pinned:
                    raise Failure(f"W3 pinned={w3 in pinned}, M3 pinned={m3 in pinned}")
                at = ids.index(w3)
                if at >= len(pinned) or ids[at + 1:at + 2] != [m3]:
                    raise Failure(f"W3 and M3 are not in the pinned prefix, M3 right after W3: {self.named(ids)}")
                phone = self.phone_order()
                if phone[:1] != [w3]:
                    raise Failure(f"the phone does not put W3 before every unpinned scratch row: {self.named(phone)}")
                return {"tabs": self.named(ids), "phone_order": self.named(phone)}

            pinned = wait_for("W3 and its mirrored pin first", pinned_first, self.timeout)
        finally:
            self.attempt("unpin W3", lambda: self.call("workspace.action", {"workspace_id": w3, "action": "unpin"}))
        wait_for("W3 and M3 unpinned", lambda: not self.is_pinned(w3) and not self.is_pinned(self.mirror_of(w3)), self.timeout)
        result = self.invariants()
        counters = self.expect_counters(before, exact={"set_order_sent": 0})
        return {"pinned": pinned, **result, "counters": counters}

    def reorder_setting(self) -> Optional[str]:
        """`app.reorderOnNotification` as the tagged app reads it (None: the default)."""
        if not self.args.app_path:
            return None
        bundle_id = plistlib.loads((Path(self.args.app_path) / "Contents" / "Info.plist").read_bytes())["CFBundleIdentifier"]
        read = subprocess.run(["defaults", "read", bundle_id, REORDER_ON_NOTIFICATION_DEFAULT],
                              capture_output=True, text=True, timeout=10)
        return read.stdout.strip() if read.returncode == 0 else None

    def notification_bump(self) -> Dict[str, Any]:
        setting = self.reorder_setting()
        if setting in ("0", "false", "off"):
            return {"skipped": f"app.reorderOnNotification is off ({setting})"}
        w1 = self.id("W1")
        self.call("workspace.select", {"workspace_id": w1})
        target = [i for i in self.own_order() if i != w1][-1]
        surfaces = self.call("surface.list", {"workspace_id": target}).get("surfaces") or []
        terminal = next((s["id"] for s in surfaces if s.get("type") == "terminal"), None)
        if not terminal:
            raise Failure(f"{self.name(target)} has no terminal to notify")
        self.call("notification.create_for_surface", {
            "workspace_id": target, "surface_id": terminal,
            "title": f"order-bump-{self.nonce}", "body": "workspace order e2e",
        })

        def bumped() -> Optional[Dict[str, Any]]:
            rows = self.tab_rows(self.main_window)
            unpinned = [up(w.get("id")) for w in rows if not w.get("pinned")]
            if unpinned[:2] != [target, self.mirror_of(target)]:
                raise Failure(f"unpinned rows {self.named(unpinned)}")
            return {"unpinned": self.named(unpinned)}

        shown = wait_for(f"{self.name(target)} bumped first, its mirror right after", bumped, self.timeout)
        phone = wait_for("C3: the phone's order is the Mac's", self.check_phone_order, self.timeout)
        return {"target": self.name(target), "setting": setting or "default", **shown, "c3_phone": phone}

    def applies_settle(self, within_s: float = 3.0, quiet_s: float = 1.0) -> int:
        """Waits for the apply counter to hold still for `quiet_s` within `within_s`."""
        deadline = time.monotonic() + within_s
        last, since = self.counters().get("applies"), time.monotonic()
        while time.monotonic() < deadline:
            time.sleep(0.25)
            value = self.counters().get("applies")
            if value != last:
                last, since = value, time.monotonic()
            elif time.monotonic() - since >= quiet_s:
                return int(value or 0)
        raise Failure(f"applies kept rising for {within_s:.0f} s (now {last})")

    def group_unit(self) -> Dict[str, Any]:
        unit = [self.id("W1"), self.id("W2")]
        created = self.call("workspace.group.create", {"name": f"order-group-{self.nonce}", "child_workspace_ids": unit})
        self.group_id = up((created.get("group") or {}).get("id"))
        if not self.group_id:
            raise Failure(f"workspace.group.create returned no group: {created}")
        try:
            tabs = wait_for("the group, then its mirror unit", lambda: self.check_adjacency([unit]), self.timeout)
            phone = wait_for("the phone's unit-aware order to be the Mac's", self.check_phone_order, self.timeout)
            applies = self.applies_settle()
        finally:
            if self.attempt("ungroup", lambda: self.call("workspace.group.ungroup", {"group_id": self.group_id})):
                self.group_id = ""
        return {"grouped_tabs": tabs, "grouped_phone": phone, "applies": applies, **self.invariants()}

    def group_clamped_set_order(self) -> Dict[str, Any]:
        unit = self.own_order()[:2]
        created = self.call("workspace.group.create", {"name": f"order-clamp-{self.nonce}", "child_workspace_ids": unit})
        group = created.get("group") or {}
        self.group_id = up(group.get("id"))
        if not self.group_id:
            raise Failure(f"workspace.group.create returned no group: {created}")
        try:
            wait_for("the group, then its mirror unit", lambda: self.check_adjacency([unit]), self.timeout)
            anchor = up(group.get("anchor_workspace_id"))
            members = [i for i in self.own_order() if i in set(unit)]
            member = members[-1]
            if member == anchor:
                raise Failure(f"the group's last member {self.name(member)} is its anchor")
            held_before = self.phone_key(member)
            last_key = max(self.phone_key(i) for i in self.own_order())
            key = self.debug("order_key_between", {"lower": last_key}).get("key")
            own_before, tabs_before = self.own_order(), self.tab_ids(self.main_window)
            reply = self.phone(SET_ORDER, {"workspace_id": member, "order_key": key, "is_pinned": False})
            held = self.phone_key(member)
            if reply.get("order_key") != held:
                raise Failure(f"set_order answered {reply.get('order_key')!r}, but {self.name(member)} holds {held!r}")
            if held == key:
                raise Failure(f"{self.name(member)} stores the requested key {key!r} though the group clamp kept it in place")
            keys = wait_for("C4: own keys increase in tab order", self.check_owner_keys, self.timeout)
            if self.own_order() != own_before:
                raise Failure(f"own rows moved: {self.named(own_before)} -> {self.named(self.own_order())}")
            hold("the window's tabs unchanged", lambda: self.tab_ids(self.main_window) == tabs_before, 1.5)
        finally:
            if self.attempt("ungroup", lambda: self.call("workspace.group.ungroup", {"group_id": self.group_id})):
                self.group_id = ""
        return {"member": self.name(member), "requested": key, "held_before": held_before, "reply": reply.get("order_key"),
                "c4_owner_keys": keys, **self.invariants()}

    def local_group_pin_not_sent(self) -> Dict[str, Any]:
        own = self.own_order()
        low, high = own[0], own[-1]
        mirror = self.mirror_of(low)
        groups: Dict[str, str] = {}
        before = self.counters()
        try:
            for name, member in (("G", mirror), ("H", high)):
                created = self.call("workspace.group.create", {
                    "name": f"order-{name.lower()}-{self.nonce}", "child_workspace_ids": [member]})
                groups[name] = up((created.get("group") or {}).get("id"))
                if not groups[name]:
                    raise Failure(f"workspace.group.create returned no group: {created}")
                self.call("workspace.group.pin", {"group_id": groups[name]})

            def pinned_groups() -> Optional[List[str]]:
                listed = self.call("workspace.group.list", {"window_id": self.main_window}).get("groups") or []
                order = [up(g.get("id")) for g in listed if up(g.get("id")) in groups.values() and g.get("is_pinned")]
                if len(order) != 2:
                    raise Failure(f"pinned groups {order}")
                return order

            order = wait_for("G and H pinned", pinned_groups, self.timeout)
            self.applies_settle()
            mid = self.counters()
            if order[0] == groups["G"]:
                self.call("workspace.group.move", {"group_id": groups["G"], "after_group_id": groups["H"]})
            else:
                self.call("workspace.group.move", {"group_id": groups["G"], "before_group_id": groups["H"]})
            wait_for("G moved to the other side of H", lambda: pinned_groups() == list(reversed(order)), self.timeout)
            time.sleep(1.5)
            moved = self.expect_counters(mid, exact={"set_order_sent": 0})
            counters = self.expect_counters(before, exact={"set_order_sent": 0})
        finally:
            for name in ("G", "H"):
                if groups.get(name):
                    self.attempt(f"unpin {name}", lambda g=groups[name]: self.call("workspace.group.unpin", {"group_id": g}))
                    self.attempt(f"ungroup {name}", lambda g=groups[name]: self.call("workspace.group.ungroup", {"group_id": g}))
        return {"mirror": self.name(mirror, self.mirror_map()), "own": self.name(high), "group_order_before": order,
                "after_move": moved, "counters": counters, **self.invariants()}

    def nested_rows_follow_order(self) -> Dict[str, Any]:
        self.nested_project = self.create_project("nested-repo")
        created = []
        for index in range(3):
            opened = self.phone("mobile.supermux.worktree.create", {
                "project_id": self.nested_project,
                "workspace_name": f"order-p{index}-{self.nonce}",
                "branch_name": f"order-p{index}-{self.nonce}",
                "open": True,
            }, timeout_s=180)
            workspace_id = up(opened.get("workspace_id"))
            if not workspace_id:
                raise Failure(f"worktree.create returned no workspace: {opened}")
            self.sources.append(workspace_id)
            created.append(workspace_id)
        for index, workspace_id in enumerate(i for i in self.tab_ids(self.window_of(created[0])) if i in set(created)):
            self.label(workspace_id, f"P{index + 1}")
        mirrors = self.wait_mirrors(created)
        p1, p2, p3 = (self.id(f"P{n}") for n in (1, 2, 3))
        wait_for("six nested rows", lambda: set(self.nested_rows(self.nested_project)) >= set(created) | set(mirrors.values()),
                 self.timeout)

        def nested_reads(expected: List[str]) -> Callable[[], Optional[List[str]]]:
            def probe() -> Optional[List[str]]:
                rows = self.nested_rows(self.nested_project)
                if rows != expected:
                    raise Failure(f"nested rows {self.named(rows)}")
                return self.named(rows)
            return probe

        first = wait_for("nested rows P1, MP1, P2, MP2, P3, MP3",
                         nested_reads([p1, mirrors[p1], p2, mirrors[p2], p3, mirrors[p3]]), self.timeout)
        self.call("workspace.reorder", {"workspace_id": mirrors[p3], "before_workspace_id": p1})
        moved = wait_for("nested rows P3, MP3, P1, MP1, P2, MP2",
                         nested_reads([p3, mirrors[p3], p1, mirrors[p1], p2, mirrors[p2]]), self.timeout)

        def phone_nested() -> Optional[List[str]]:
            rows = [{**r, "group_id": None} for r in self.phone_list().get("workspaces") or []
                    if up(r.get("supermux_project_id")) == self.nested_project]
            order = phone_arrange(rows)
            if order != [p3, p1, p2]:
                raise Failure(f"the phone's nested order {self.named(order)}")
            return self.named(order)

        phone = wait_for("the phone's nested order P3, P1, P2", phone_nested, self.timeout)
        return {"project_id": self.nested_project, "first": first, "after_mirror_drag": moved, "phone_nested": phone}

    def cross_window_move(self) -> Dict[str, Any]:
        w2 = self.id("W2")
        self.extra_window = up(self.call("window.create").get("window_id"))
        if not self.extra_window:
            raise Failure("window.create returned no window")
        try:
            self.call("workspace.move_to_window", {"workspace_id": w2, "window_id": self.extra_window})

            def last_there() -> bool:
                ids = self.tab_ids(self.extra_window)
                return bool(ids) and ids[-1] == w2

            wait_for("W2 the new window's last row", last_there, self.timeout)
            hold("W2 the new window's last row", last_there, 2.0)
            phone = wait_for("C3: the phone's order is the Mac's", self.check_phone_order, self.timeout)
            window = next((w for w in self.order_state().get("windows") or [] if up(w.get("window_id")) == self.extra_window), {})
            rows = window.get("rows") or []
            keys = [(self.name(up(r.get("workspace_id"))), r.get("key")) for r in rows]
            at = next((n for n, r in enumerate(rows) if up(r.get("workspace_id")) == w2), None)
            if at is None or not is_valid_key(rows[at].get("key")):
                raise Failure(f"W2 has no key in the new window: {keys}")
            lower = [k for _, k in keys[:at] if k]
            if any(k >= rows[at]["key"] for k in lower):
                raise Failure(f"W2's key is not above the keys before it: {keys}")
            return {"new_window": self.named(self.tab_ids(self.extra_window)), "keys": keys, "c3_phone": phone}
        finally:
            self.attempt("move W2 back", lambda: self.call(
                "workspace.move_to_window", {"workspace_id": w2, "window_id": self.main_window}))
            if self.attempt("close the extra window", lambda: self.call(
                    "window.close", {"window_id": self.extra_window, "force": True})):
                self.extra_window = ""

    def projects_list(self) -> List[Dict[str, Any]]:
        return self.phone("mobile.supermux.projects.list").get("projects") or []

    def projects_order(self) -> Dict[str, Any]:
        if not self.args.projects_file:
            return {"skipped": "pass --projects-file (the app's SUPERMUX_PROJECTS_FILE) to run"}
        p, q = self.create_project("project-p"), self.create_project("project-q")
        names = {p: "P", q: "Q"}
        path = Path(self.args.projects_file)

        def file_lists_both() -> bool:
            listed = {up(r.get("id")) for r in json.loads(path.read_text()).get("projects") or []}
            return {p, q} <= listed

        try:
            wait_for(f"{path} to list P and Q", file_lists_both, self.timeout)
        except (Failure, OSError, ValueError) as error:
            raise Failure(f"refusing to move projects: the app does not write {path} ({error})") from None
        unstamped = {names[up(r.get("id"))]: r.get("order") for r in self.projects_list() if up(r.get("id")) in names}
        if any(unstamped.values()) or len(unstamped) != 2:
            raise Failure(f"before any move P and Q must be listed without an order: {unstamped}")

        def listed_order() -> List[str]:
            return [names[up(r.get("id"))] for r in self.projects_list() if up(r.get("id")) in names]

        def sidebar_order() -> List[str]:
            return [names[up(r.get("project_id"))] for r in self.sidebar_projects() if up(r.get("project_id")) in names]

        def lists(expected: List[str]) -> Callable[[], Optional[Dict[str, Any]]]:
            def probe() -> Optional[Dict[str, Any]]:
                rows = self.projects_list()
                if listed_order() != expected:
                    raise Failure(f"projects.list reads {listed_order()}")
                if not all(r.get("order") for r in rows):
                    raise Failure(f"rows without an order: {[r.get('name') for r in rows if not r.get('order')]}")
                if sidebar_order() != expected:
                    raise Failure(f"the sidebar (sidebar_rows projects, every project in drawn order) reads {sidebar_order()}")
                return {"projects_list": expected, "sidebar": expected}
            return probe

        self.debug("project_move", {"project_id": q, "over_project_id": p})
        moved = wait_for("Q before P everywhere, every project stamped", lists(["Q", "P"]), self.timeout)
        stamps = {up(r.get("id")): r.get("order") or {} for r in self.projects_list()}
        key = self.debug("order_key_between", {"upper": stamps[q].get("key")}).get("key")
        origin = f"phone:e2e-{self.nonce}"
        oldest = min(s.get("updated_at") or 0 for s in stamps.values() if s)
        newest = max(s.get("updated_at") or 0 for s in stamps.values() if s)

        def set_order(updated_at: float) -> Dict[str, Any]:
            reply = self.phone(PROJECTS_SET_ORDER, {"stamps": [{"project_id": p, "order": {
                "key": key, "updated_at": updated_at, "origin": origin}}]})
            return next((r for r in reply.get("results") or [] if up(r.get("project_id")) == p), {})

        older = set_order(oldest - 60)
        if older.get("applied") is not False:
            raise Failure(f"an older stamp was applied: {older}")
        hold("Q before P after the refused stamp", lambda: listed_order() == ["Q", "P"], 1.5)
        newer = set_order(newest + 1)
        if newer.get("applied") is not True:
            raise Failure(f"a newer stamp was not applied: {newer}")
        after = wait_for("P before Q everywhere", lists(["P", "Q"]), self.timeout)
        return {"after_move": moved, "older": older, "newer": newer, "after_newer": after}

    def owner_offline_drag_beeps(self) -> Dict[str, Any]:
        source = self.own_order()[-1]
        mirror = self.mirror_of(source)
        target = next(i for i in self.scratch_tabs() if i not in (source, mirror))
        before = self.counters()
        self.call("supermux.devices.link_impairment", {"drop_now_s": 12, "drop_cuts": True})
        try:
            wait_for("the loopback link to drop", lambda: self.loopback_device().get("link_state") != "connected",
                     self.timeout)
            self.call("workspace.reorder", {"workspace_id": mirror, "before_workspace_id": target})

            def beeped() -> Optional[Dict[str, Any]]:
                delta = (self.counters().get("set_order_beeps") or 0) - (before.get("set_order_beeps") or 0)
                if delta != 1:
                    raise Failure(f"set_order_beeps {delta:+d}")
                return {"set_order_beeps": delta}

            beeps = wait_for("one beep for the unreachable owner", beeped, self.timeout)

            def snapped_back() -> bool:
                ids = self.tab_ids(self.main_window)
                return source in ids and mirror in ids and ids.index(mirror) == ids.index(source) + 1

            wait_for("the mirror back right after its source", snapped_back, self.timeout)
        finally:
            self.attempt("lift the drop", lambda: self.call("supermux.devices.link_impairment", {"reset": True}))
            self.attempt("the link back", self.wait_connected)
        return {"dragged": self.name(mirror, self.mirror_map()), "dropped_before": self.name(target),
                **beeps, **self.invariants()}

    def old_host_fallback(self) -> Dict[str, Any]:
        w2 = self.id("W2")
        m2 = self.mirror_of(w2)
        self.debug("order_debug", {"mode": "old_host"})
        self.debug_mode_touched = True
        try:
            self.link_restart()
            capabilities = self.phone("mobile.host.status").get("capabilities") or []
            if CAPABILITY in capabilities:
                raise Failure(f"old_host still advertises {CAPABILITY}")
            wait_for("no keys on mobile.workspace.list", lambda: not any(self.phone_keys().values()), self.timeout)
            if self.nested_project:
                def blocks() -> Optional[List[str]]:
                    rows = self.nested_rows(self.nested_project)
                    mirrors = set(self.mirror_map().values())
                    kinds = ["mirror" if r in mirrors else "local" for r in rows]
                    if kinds != ["local"] * kinds.count("local") + ["mirror"] * kinds.count("mirror"):
                        raise Failure(f"nested rows {self.named(rows)}")
                    return self.named(rows)
                wait_for("nested rows in per-device blocks", blocks, self.timeout)
            # old_host stops this Mac's reconciler too, so in a loopback it is
            # also an old viewer: nothing could move a dropped mirror. old_peer
            # keeps the owner old (no capability, no keys) and runs the viewer.
            self.debug("order_debug", {"mode": "old_peer"})
            self.applies_settle()
            own_before = self.own_order()
            before = self.counters()
            self.call("workspace.reorder", {"workspace_id": m2, "index": 0})

            def dropped() -> bool:
                return self.tab_ids(self.main_window)[:1] == [m2] and self.own_order() == own_before

            wait_for("M2 first", dropped, self.timeout)
            hold("M2 where dropped, W2 unmoved", dropped, 2.0)
            counters = self.expect_counters(before, exact={"set_order_sent": 0}, at_least={"passes": 1})
        finally:
            if self.attempt("order_debug normal", lambda: self.debug("order_debug", {"mode": "normal"})):
                self.debug_mode_touched = False
            self.attempt("restart the link", self.link_restart)
        result = self.invariants()
        if self.own_order() != own_before:
            raise Failure(f"the resume moved own rows: {self.named(own_before)} -> {self.named(self.own_order())}")
        resumed = self.expect_counters(before, exact={"set_order_sent": 0}, writes={w2: 0})
        return {"dropped": counters, "resumed": resumed, **result}

    def quiescence(self) -> Dict[str, Any]:
        def picture() -> Dict[str, Any]:
            state = self.order_state()
            rows = [(r.get("workspace_id"), r.get("key"), r.get("pending_key"))
                    for w in state.get("windows") or [] for r in w.get("rows") or []]
            counters = state.get("counters") or {}
            return {
                "tabs": {w: self.tab_ids(w) for w in self.windows()},
                "rows": rows,
                "counters": {k: counters.get(k) for k in ("own_key_writes", "applies", "set_order_sent")},
            }

        first = picture()
        time.sleep(5.0)
        second = picture()
        changed = [part for part in first if first[part] != second[part]]
        if changed:
            raise Failure(f"{changed} changed while idle: {first['counters']} -> {second['counters']}")
        return {"counters": second["counters"]}

    def relaunch(self) -> Dict[str, Any]:
        if not self.args.relaunch:
            return {"skipped": "pass --relaunch (with --app-path) to run"}
        if not self.args.app_path:
            raise Failure("--relaunch needs --app-path")
        read = self.read_scratch_notifications()
        titles = {i: (next((w.get("title") for w in self.tab_rows(self.window_of(i)) if up(w.get("id")) == i), ""))
                  for i in self.sources}
        keys = {titles[i]: self.phone_key(i) for i in self.sources}
        order = [titles[i] for i in self.own_order()]
        app = self.args.app_path
        bundle_id = plistlib.loads((Path(app) / "Contents" / "Info.plist").read_bytes())["CFBundleIdentifier"]
        self.sock.close()
        subprocess.run(["osascript", "-e", "ignoring application responses", "-e",
                        f'tell application id "{bundle_id}" to quit', "-e", "end ignoring"], check=False, capture_output=True)
        # The socket goes before the process (the quit waits for the session
        # save): `open` would then reuse the dying app without the environment.
        wait_for("the app to quit", lambda: not app_running(bundle_id), 60)
        env = ["--env", "SUPERMUX_DEBUG_LOOPBACK_DEVICE=1"]
        if self.args.projects_file:
            env += ["--env", f"SUPERMUX_PROJECTS_FILE={self.args.projects_file}"]
        if self.args.push_state_dir:
            env += ["--env", f"SUPERMUX_PHONE_PUSH_STATE_DIR={self.args.push_state_dir}"]
        subprocess.run(["open", "-g", *env, app], check=True)
        wait_for("the relaunched app's socket", lambda: socket_alive(self.sock.path), 60)
        self.sock.connect()
        self.wait_connected()
        mirrors = set(self.mirror_map().values())
        by_title = {w.get("title"): up(w.get("id")) for window in self.windows() for w in self.tab_rows(window)
                    if up(w.get("id")) not in mirrors}
        missing = [t for t in titles.values() if t not in by_title]
        if missing:
            raise Failure(f"scratch rows missing after the relaunch: {missing}")
        renamed = {by_title[titles[i]]: self.labels[i] for i in self.sources}
        self.labels, self.sources = renamed, list(renamed)
        self.facts["workspaces_after_relaunch"] = {name: i for i, name in renamed.items()}
        self.main_window = self.window_of(self.sources[0])
        keys_after = {t: self.phone_keys().get(by_title[t]) for t in keys}
        changed = {t: (k, keys_after[t]) for t, k in keys.items() if keys_after[t] != k}
        if changed:
            raise Failure(f"keys changed across the relaunch: {changed}")
        title_of = {i: t for t, i in by_title.items()}
        after = [title_of[i] for i in self.own_order()]
        if after != order:
            raise Failure(f"own order changed across the relaunch: {order} -> {after}")
        tabs = wait_for("C1 once the mirrors return", self.check_adjacency, self.timeout * 3)
        return {"keys": len(keys), "own_order": order, "read_before_quit": read, "c1_tabs": tabs}

    def read_scratch_notifications(self) -> List[str]:
        """Marks every scratch row's notifications read and waits until none is
        unread. A mirror whose source still has an unread notification (step 12
        leaves one) gets it again when the link reconnects after a relaunch;
        the bump that follows is sent to the owner (design D2) and moves the
        owner's row, which is not what the relaunch step checks."""
        mirrors = self.mirror_map()
        rows = self.sources + [mirrors[s] for s in self.sources if s in mirrors]
        unread = self.unread_notification_rows(rows)
        for workspace_id in rows:
            self.call("workspace.action", {"workspace_id": workspace_id, "action": "mark_read"})
        wait_for("every scratch notification read", lambda: not self.unread_notification_rows(rows), self.timeout)
        return [self.name(i, mirrors) for i in unread]

    def unread_notification_rows(self, rows: Sequence[str]) -> List[str]:
        """The rows among `rows` holding an unread notification record."""
        records = self.debug("notification_records").get("records") or []
        unread = {up(r.get("workspace_id")) for r in records if not r.get("is_read")}
        return [i for i in rows if i in unread]

    def sidebar_screenshot(self) -> Dict[str, Any]:
        shot = self.call("debug.window.screenshot", {"label": "workspace-order"})
        path = str(shot.get("path") or "")
        if not path:
            raise Failure(f"debug.window.screenshot returned no path: {shot}")
        kept = Path(self.args.report_path).with_suffix("").as_posix() + "-sidebar.png"
        Path(kept).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, kept)
        return {"screenshot": kept}

    # -- run --------------------------------------------------------------------

    def cleanup(self) -> None:
        if self.group_id:
            self.attempt("ungroup", lambda: self.call("workspace.group.ungroup", {"group_id": self.group_id}))
        if self.extra_window:
            self.attempt("close the extra window", lambda: self.call("window.close", {"window_id": self.extra_window, "force": True}))
        if self.debug_mode_touched:
            self.attempt("order_debug normal", lambda: self.debug("order_debug", {"mode": "normal"}))
        if self.machine and self.loopback_device_state() != "connected":
            self.attempt("restore the link", lambda: self.call("supermux.devices.link", {"machine": self.machine, "action": "restore"}))
        # Close the sources only: auto-mirror closes each mirror with its source.
        for workspace_id in self.sources:
            self.attempt(f"close {self.name(workspace_id)}", lambda w=workspace_id: self.call(
                "workspace.close", {"workspace_id": w, "force": True}))
        if self.sources:
            self.attempt("mirrors to close", lambda: wait_for(
                "the mirrors to close with their sources",
                lambda: not (set(self.mirror_map()) & set(self.sources)), self.timeout))
        for project_id in self.projects:
            self.attempt(f"delete project {project_id}", lambda p=project_id: self.phone(
                "mobile.supermux.project.delete", {"project_id": p}))
        if self.initial_auto_mirror is False:
            self.attempt("auto-mirror off", lambda: self.call("supermux.devices.set_auto_mirror", {"enabled": False}))
        if not self.args.keep:
            shutil.rmtree(self.root, ignore_errors=True)

    def loopback_device_state(self) -> str:
        try:
            return str(self.loopback_device().get("link_state"))
        except (Failure, OSError):
            return "unknown"

    def run(self) -> bool:
        ok = self.step("setup", self.setup)
        if not self.machine:
            return False
        try:
            ok = self.step("scratch_rows", self.scratch_rows) and ok
            if len(self.labels) < 4:
                return False
            for name, check in [
                ("mac_reorder_moves_mirrors", self.mac_reorder_moves_mirrors),
                ("move_to_top_action", self.move_to_top_action),
                ("old_phone_move", self.old_phone_move),
                ("mirror_drag_moves_source", self.mirror_drag_moves_source),
                ("phone_set_order", self.phone_set_order),
                ("key_only_set_order", self.key_only_set_order),
                ("set_order_rejects", self.set_order_rejects),
                ("new_workspace_keyed", self.new_workspace_keyed),
                ("pin_tier", self.pin_tier),
                ("notification_bump", self.notification_bump),
                ("group_unit", self.group_unit),
                ("group_clamped_set_order", self.group_clamped_set_order),
                ("local_group_pin_not_sent", self.local_group_pin_not_sent),
                ("nested_rows_follow_order", self.nested_rows_follow_order),
                ("cross_window_move", self.cross_window_move),
                ("projects_order", self.projects_order),
                ("owner_offline_drag_beeps", self.owner_offline_drag_beeps),
                ("old_host_fallback", self.old_host_fallback),
                ("quiescence", self.quiescence),
                ("relaunch", self.relaunch),
                ("sidebar_screenshot", self.sidebar_screenshot),
            ]:
                ok = self.step(name, check) and ok
            return ok
        finally:
            self.cleanup()


def app_running(bundle_id: str) -> bool:
    script = f'application id "{bundle_id}" is running'
    result = subprocess.run(["osascript", "-e", script], check=False, capture_output=True, text=True, timeout=30)
    return result.stdout.strip() == "true"


def socket_alive(path: str) -> bool:
    probe = Socket(path, timeout_s=3)
    try:
        probe.connect()
        probe.call("supermux.devices.list", {})
        return True
    except (OSError, Failure):
        return False
    finally:
        probe.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"))
    parser.add_argument("--socket", help="this tagged build's control socket (default: /tmp/cmux-debug-<tag>.sock; never $CMUX_SOCKET_PATH, which in a Supermux terminal names the user's own app)")
    parser.add_argument("--scratch", default=None, help="scratch folder for workspaces and repos (default /tmp/<tag>-order)")
    parser.add_argument("--projects-file", help="the app's scratch SUPERMUX_PROJECTS_FILE (projects_order needs it)")
    parser.add_argument("--app-path", help="the tagged .app (reads its settings; --relaunch quits and reopens it)")
    parser.add_argument("--push-state-dir", help="SUPERMUX_PHONE_PUSH_STATE_DIR for the relaunch")
    parser.add_argument("--relaunch", action="store_true", help="run the relaunch step (needs --app-path)")
    parser.add_argument("--timeout", type=float, default=15.0, help="seconds per wait")
    parser.add_argument("--keep", action="store_true", help="keep the scratch folder")
    parser.add_argument("--report", help="report path")
    args = parser.parse_args()
    if not args.tag and not args.socket:
        parser.error("set CMUX_TAG (or pass --tag / --socket)")
    args.scratch = args.scratch or f"/tmp/{args.tag or 'socket'}-order"
    args.report_path = args.report or str(ARTIFACTS_DIR / f"loopback_workspace_order_e2e-{args.tag or 'socket'}.json")
    path = args.socket or socket_path_for_tag(args.tag)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    sock = Socket(path)
    try:
        sock.connect()
        test = WorkspaceOrderE2E(sock, args)
        passed = test.run()
        steps, facts = test.steps, test.facts
    except (OSError, Failure) as error:
        passed, steps, facts = False, [{"name": "connect", "ok": False, "error": f"{path}: {error}"}], {}
    finally:
        sock.close()
    report = {
        "suite": "supermux-loopback-workspace-order-e2e",
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
