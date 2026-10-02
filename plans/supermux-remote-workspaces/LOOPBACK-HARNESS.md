# Loopback device harness (DEBUG)

A real Mac-to-Mac link needs two machines. Both must run the same bundle id and build tag
(`IrxMacPeerAuthorization`, worker SQL). The loopback harness removes that need: one tagged DEBUG
build acts as both Macs.

The harness adds a synthetic **"Loopback Mac"** device. Its `DeviceLink` talks in-process to this
same app's mobile host (`MobileHostService`). That has three effects:

- This app's own workspaces appear as the device's remote workspaces.
- Opening one creates a normal device mirror.
- Every `mobile.*`, `mobile.supermux.*` and `device.workspace.*` request the link makes runs on
  this same app.

Design decision 12 in [DESIGN.md](DESIGN.md) calls for this harness.

> **Verified 2026-10-01** on tag `rws-f2` (`--supermux-profile` build). The smoke script passes all
> 10 checks, and a mirror survives an app restart (it is restored and reconnects).
> An agent-only build (`CMUX_DEV_BACKEND_MODE=local`, not signed in) should work the same way,
> because the link never asks for a Stack token. **That was not tested.**

## Run it

```bash
export PATH="$HOME/.cargo/bin:$PATH:$HOME/.local/zig/zig-aarch64-macos-0.16.0"
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=false

# 1. Build (signed-in profile seeded from the installed Supermux app; never sign out inside it).
./scripts/reload.sh --tag <tag> --supermux-profile

# 2. Launch with the opt-in. Use the "App path:" that reload.sh printed.
open -g --env SUPERMUX_DEBUG_LOOPBACK_DEVICE=1 "<App path printed by reload.sh>"

# 3. Verify the pipeline end to end (writes tests/supermux/artifacts/loopback_device_smoke-<tag>.json).
CMUX_TAG=<tag> python3 tests/supermux/loopback_device_smoke.py
```

- **Opt-in, choose one.**
  - Set the environment variable `SUPERMUX_DEBUG_LOOPBACK_DEVICE=1` at launch (`1`, `true` or
    `yes`).
  - Or set the default:
    `defaults write com.cmuxterm.app.debug.<tag-with-dots> supermux.debug.loopbackDevice -bool true`.
    Write it **after** the reload: `--supermux-profile` re-imports the whole defaults domain and
    wipes the key. Delete it afterwards with `defaults delete … supermux.debug.loopbackDevice`.
- **Why not `reload.sh --launch`.** That launch runs the app under `env -i`, so the variable never
  reaches the app. It also needs team dev credentials (`~/.secrets/cmuxterm-dev.env`). Use
  `open --env` or the default instead.
- **Release builds.** Every harness file is wrapped in `#if DEBUG`, and so are the one call site
  and the `DeviceLinkRuntime` seam, so a Release build contains none of it. This was checked by
  reading the code; no Release build was made.
- **Without the opt-in.** A DEBUG build has no loopback machine. This was checked by relaunching
  without the opt-in: the catalog lists only `local`, and the log has no `supermux.loopback`
  lines.
- **Sanity check.** `/tmp/cmux-debug-<tag>.log` shows these lines:
  `supermux.loopback started machine=device:5e1f10b0-…@<tag> devicesEnabled=true`, then
  `supermux.loopback host admitted connection …`.

### Poke at it by hand

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh vm tree            # the device, "link connected", its workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh vm workspace open \
  device:5e1f10b0-0000-4000-8000-000000000001@<tag> <workspace-id> --no-focus   # new local mirror workspace
```

> **Use `vm workspace open`, not `vm open <machine>/<ws>`.** `vm open` puts the remote terminal
> into the *current* local workspace. With the loopback, that is usually the source workspace, so
> you get a mirror pane of a terminal inside its own workspace. `vm workspace open` (socket
> `vm.workspace_open`) creates a separate mirror workspace. That is what the auto-mirror and the
> smoke script use.

In the UI, the device is listed in the right sidebar's **Cloud** tab under My Devices, as
"Loopback Mac (<tag>)".

## What the smoke script checks

`tests/supermux/loopback_device_smoke.py` is stdlib-only and takes `--keep`, `--timeout` and
`--report`. It talks to `/tmp/cmux-debug-<tag>.sock`. It prints a JSON report, saves it, and exits
non-zero on any failure. It pauses auto-mirror (`supermux.devices.set_auto_mirror`) for its run and
restores it afterwards, so step 4's explicit `vm.workspace_open` is not raced by an auto-opened mirror.
Auto-mirror, close semantics and mirror status have their own E2E:
`CMUX_TAG=<tag> python3 tests/supermux/loopback_auto_mirror_e2e.py [--git-repo /tmp/<tag>/repo]
[--app-path "<App path>" --projects-file /tmp/<tag>/projects.json]` (the app path enables the
quit + relaunch dedupe check).

1. `device_connected`: the loopback machine is in `surface.catalog` with `link_state: connected`.
2. `remote_workspaces_equal_local`: the device's remote workspaces equal this app's workspaces,
   by id and title.
3. `new_workspace_syncs_to_device`: a fresh `loopback-smoke-<nonce>` workspace reaches the device
   through live `mobile.sync.delta`.
4. `open_remote_workspace_creates_mirror`: `vm.workspace_open` creates a separate local mirror
   workspace, and the mirror takes the remote title.
5. `remote_workspaces_equal_local_with_mirror`: the same comparison as step 2, run again with the
   mirror open. The report sets `loopback_mirrors_reexported`. It is `true` while the host
   re-exports mirrors, and flips to `false` once the host export filter (design decision 2) lands.
   The step passes either way.
6. `source_output_appears_in_mirror`: the script types `echo …$((6*7))…` into the **source**
   terminal. The evaluated output appears in the **mirror** (`mobile.terminal.replay` +
   `terminal.bytes`).
7. `mirror_input_reaches_source`: the script types into the **mirror**. The command runs in the
   **source** (`mobile.terminal.input`) and its output comes back.
8. `source_notification_reaches_mirror`: a notification on the source terminal lands on the mirror
   terminal (`notification.feed.list`, subtitle "Terminal on Loopback Mac (<tag>)"). There are
   exactly 2 copies, so nothing is relayed back.
9. `source_split_reaches_mirror`: a split on the source is projected into the mirror
   (`device.workspace.layout.changed` + reconcile).
10. `mirror_split_creates_source_terminal`: a split in the mirror creates a real source terminal
    (`device.workspace.terminal.create`), and that terminal is projected back.
11. `slow_request_keeps_the_link` (#723): the loopback host holds one
    `mobile.supermux.projects.list` for 30 s (`supermux.devices.link {machine, action: "stall",
    method, seconds}`), past the link's 20 s reply deadline. Only that request fails (`timed_out`);
    for 60 s the link stays `connected` and admits no new loopback connection
    (`supermux.devices.link {action: "status"}` reports `phase`, `connections_admitted` and
    `stall_armed`), and the source's output still reaches the mirror afterwards.
12. `slow_request_keeps_the_link_while_main_is_stuck` (#723): the same, with `main_seconds: 12`,
    which blocks the app's main thread (the loopback host's) for 12 s from the moment the link sends
    its liveness probe, longer than the probe's 10 s deadline. The probe carries no `client_id`, so the
    host answers it without its main thread and the link still stays (`main_stall_armed` reports a
    block not yet used).
13. `slow_replay_reattaches_the_mirror` (#690): the loopback host holds the mirror pane's next
    `mobile.terminal.replay` for 25 s (`supermux.devices.terminal_close.replay` starts it). The replay
    misses its deadline on a live link, and the pane must be attached again within 45 s
    (`supermux.devices.terminal_close.inspect`) with the link connected throughout. Before, it stayed
    detached: the reconnect that used to re-attach it no longer comes.

Cleanup closes the mirror first, then the source. `--keep` leaves both open, which is how to test
restore: quit the app, relaunch it with the opt-in, and the mirror reconnects.

## Background tab sync and Remote Macs settings E2E

- `tests/supermux/loopback_tab_sync_e2e.py` (workstream X) creates a terminal in a background
  source workspace through the socket (`surface.create`) and through the device link
  (`mobile.terminal.create`, the phone's path), closes one and reorders the tabs, and times how fast
  the source's auto-mirror follows (limit `--latency`, default 1 s). It also checks that the source
  was never selected, so no geometry path could have carried the change.
- `tests/supermux/loopback_remote_macs_settings_e2e.py` drives the Settings "Remote Macs" card's own
  actions over `supermux.devices.remote_macs_settings_set`: auto-mirror off then on (live), Hide Here
  + Show Hidden Workspaces, the other toggles, and the flat-row Mac icon for the Loopback Mac (its
  state, tooltip, and placement on the branch line).
  `--screenshot` also opens Settings on Automation and captures the window.
- `tests/supermux/loopback_sidebar_rows_e2e.py` reads the sidebar rows as drawn
  (`supermux.devices.sidebar_rows`): nested rows list this Mac's workspaces before each Mac's
  mirrors, a nested mirror's accessibility label names its Mac, a nested mirror draws the Mac icon
  (no name capsule) before its branch, `set_status` / `set_progress` (Claude's lifecycle-less "Idle"
  pill included) show on no nested row (local or mirror), the working spinner of a nested local row
  and of its mirror is the 6·scale one (measured in a window screenshot), a flat mirror's directory
  line omits the Mac name and carries its icon. Hover behavior, the footer and the row menus (Close
  Workspace on every row, Hide Here on mirrors, no "Close on <Mac>…") are checked visually.

## Port forward E2E

`tests/supermux/loopback_port_forward_e2e.py` (round 5, Track B) forwards the Loopback Mac's ports
to this Mac. Viewer and owner are one app, so every remote port is busy here and each forward must
land on another local port. It starts `python3 -m http.server R` in a background source workspace's
terminal (`surface.send_text`, then `surface.ports_kick`) and checks: an automatic forward of R
becomes active within `--latency` (default 8 s) on L, neither R nor one of R+1…R+3 (the suite
listens on those itself), and serves the owner's page on
`127.0.0.1:L` and `[::1]:L`; a suite-owned dual-stack `[::]` listener plus a host port injected
with Track A's `supermux.devices.tunnel.inject_port` is forwarded elsewhere while `127.0.0.1:R2`
still reaches the suite's own listener; the mirror's `supermux.ports.R` pill names L and its port
chips list R; Forward a Port / Stop / Resume (`supermux.devices.ports.forward|stop|resume`); a
server that exits removes its forward; a dropped link (`supermux.devices.link stop|restore`) makes
forwards wait and empties the chips, and the suite frees R+1…R+3 while the link is down, so the
first free port above R is below L and only the forward's last-local-port preference brings it back
on L (the step fails rather than pass vacuously when nothing between R and L is free); auto-forward off keeps a
manual forward; a default-browser link from the mirror's terminal (Track C's
`supermux.devices.mirror.link_open`) goes to L; Track A's `pretend_old_host` disables
forwarding (`needs_update`); and with `supermux.devices.tunnel.fail_requests` making the loopback
host answer every `mobile.host.status` after a relink `timed_out`, R comes back once the host answers
again, with no port change and no relink (`capability_failure_retried`: the forwards ask again after
1 s, 2 s, 4 s … while the link is up), and with every `ports.list` failing until the reconnect's own
`supermux.ports.updated` pokes are over (5 s), R comes back the same way (`listing_failure_retried`:
a failed listing is fetched again by itself); the mirror's chip for R clicked with "Open Sidebar Port Links in cmux
Browser" off opens `http://localhost:L` in the default browser, never this Mac's own
`localhost:R` (`chip_default_browser_uses_local_port`); and a manual forward left waiting by a
dropped link is offered Stop Forwarding in both port menus, goes at once when stopped and never
listens again once the link is back (`pending_forward_offers_stop`); last, a terminal of this Mac
(from a local workspace, scanned there first) serving P is moved into M, and M's chip for P, clicked
with the setting off, opens `http://localhost:P` as any local workspace's chip does
(`local_terminal_chip_opens_this_mac`; before the per-port rule every chip of a mirror went to the
owning Mac's forward, so it showed "Port P from <Mac> isn't forwarded"), and clicked with the setting
on it opens the same URL in the default browser, not a cmux browser in M, which would route
`localhost` to the owning Mac (`new_browser_panel_id` must be null). The DEBUG driver
`supermux.devices.ports.*` (`Sources/Supermux/Ports/SupermuxDevicePortsSocketCommands.swift`)
answers `list {machine?}` (the forwards, availability, host listings, and each mirror's chips and
pills), `forward`, `stop`, `resume {machine, port}`, `set_auto {enabled}` (the Settings card's
action) and `refresh {machine?}`; `Sources/Supermux/Ports/SupermuxPortMenusSocketCommands.swift`
answers `chip_open {workspace_id, port, cmux_browser?}` (a sidebar chip click through the
`device-mirror-port-chip` touchpoint's call; the default browser and the alert are captured:
`external_url`, `notice`, `new_browser_panel_id`; `is_mirror` when the port is the owning Mac's,
`in_mirror` when the workspace is a mirror) and `menus {workspace_id?}` (the mirror's
"Ports on <Mac>" model and each Mac's Settings Ports… menu, every port with its `items`).

```bash
CMUX_E2E_SUITES="loopback_port_forward_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh
```

What the loopback cannot show: the same-port path (R is always busy here), real QUIC tunnels and
their limits, a Tailscale-only link (`no_direct_link`), and iOS Simulator apps. Check those on two
Macs.

## New tab order E2E

`tests/supermux/loopback_new_tab_order_e2e.py` checks where a new terminal tab lands, on the
owning side and in the mirror (read as source ids through `surface.catalog`), for every entry
point: `surface.create` and `mobile.terminal.create` in a background source; in its mirror, Cmd+T
from the last and the first tab, the tab bar `+` (`supermux.devices.mirror.tab_bar_new_tab`, the
exact `requestNewTab` call), `surface.create` on the mirror, and "New Terminal to the Right" from
the tab menu (`supermux.devices.mirror.tab_context_action`, action `newTerminalToRight`) and from
`tab.action new_terminal_right`; and in a focused local workspace, Cmd+T and `+` from its first tab
and "New Terminal to the Right". Plain new tabs must append, "to the right" must land right of its
tab, and both sides must still agree 1.5 s later. The source never selects a tab, so its pane stays
on its first tab, the headless-Mac state that put every new tab second (touchpoints #660–#664). Each
step records the before/after orders, the owning pane's selected tab and the latency.

```bash
CMUX_E2E_SUITES="loopback_new_tab_order_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh
```

## Agent activity E2E

`tests/supermux/loopback_agent_activity_e2e.py` checks the agent-working indicator while an agent is
"Waiting" and the per-tab working spinner (#715–#719). A background workspace S gets a second
terminal; with the lifecycle set over `set_agent_lifecycle`, T_A's agent `backgroundWorkPending`
must read as `working` on S's and its mirror's flat rows, the mirror status and the phone's
`mobile.workspace.list`, and only T_A's tab must spin on S and on the mirror
(`supermux.devices.mirror.tab_indicators`, DEBUG: each tab's `is_loading`, unread dot, lifecycle and,
for a mirror tab, the other Mac's terminal id); window screenshots of S and the mirror are kept next
to the report. The spinner then moves to T_B (per tab) and clears when both are idle. Last, a real
`cmux claude-hook` turn (prompt-submit, then Stop with a running `background_tasks` entry, through
`scripts/cmux-debug-cli.sh` with a scratch hook-state file) must show upstream's Waiting pill
(`work_state: waiting`), deliver no notification while waiting, keep the indicators, and on a second
Stop with the work done clear them and deliver the notification. Its hooks get exactly what cmux's
`claude` wrapper exports to Claude Code and no other agent environment: `CMUX_CLAUDE_PID` of a
stand-in running in T_A (it execs a long sleep under its own PID, as the wrapper execs Claude Code)
and the `CMUX_AGENT_LAUNCH_*` launch capture. Without the PID upstream registers no agent process, so
it hides the agent's pill; without the launch capture the pane gets no resume binding, so upstream
drops the completion notification as `session-unbound`.
Then: a Claude harness tab in S spins while its lifecycle is `running` and stops at `idle`; the
mirror's T_A tab, reset to the state a tab is created in (`supermux.devices.mirror.reset_tab_loading`,
DEBUG), spins again after one projector pass (`supermux.devices.reconcile`) with the overlay
unchanged; a second workspace S2 gets running T_A over `surface.move` and both S2's tab and the newly
projected tab in S2's mirror spin; last, T_A Waiting moves into its window's Dock
(`supermux.devices.mirror.move_into_dock`, DEBUG, the drag's `moveSurfaceIntoDock`) and its Dock tab
(`supermux.devices.mirror.dock_tab`, DEBUG) spins, stops at `idle` and spins again at `running`.

```bash
CMUX_E2E_SUITES="loopback_agent_activity_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh
```

## Mirror rendering E2E

`tests/supermux/loopback_mirror_render_e2e.py` checks what the user sees, not the buffer: it selects
a terminal and pixel-samples its pane in a `debug.window.screenshot` (a pane counts as drawn when
`--min-ink`, default 200, pixels differ clearly from the pane fill). Steps: a plain background
workspace draws (the detector's control); its auto-mirror, opened in the background, draws; a
background local terminal that set OSC 11 draws; and with `--app-path`, after a quit and relaunch,
the restored mirror draws. Each sampled screenshot is copied next to the JSON report. It guards
touchpoint #538: a terminal whose pane-local OSC 11 fill arrived off screen used to stay blank when
shown, and mirrors always hit that because the owning Mac's replay carried its colors. Since #651 a
mirror's replay carries none, so the mirror steps guard that mirrors draw and the background OSC 11
terminal step is the one that exercises the cutout.

```bash
CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_render_e2e.py \
  --app-path "<App path>" --projects-file /tmp/<tag>/projects.json
```

## Mirror appearance E2E

`tests/supermux/loopback_mirror_appearance_e2e.py` checks that a device mirror paints its
background like the local pane it mirrors (#650–#653). The DEBUG driver
`supermux.devices.mirror.terminal_background {surface_id}` reports how a terminal paints:
`background_override` (the pane-local OSC 11 color), `fill_owner` (`shared` window backdrop or
`terminal` host layer), `host_layer_alpha`, `backdrop_cutout_present`, this Mac's
`app_background_opacity`, and for a mirror the colors its replays applied
(`applied_remote_colors`, sparse) and whether the last replay's own bytes carried color OSC
(`last_replay_color_osc`). Steps: a translucency precondition (skipped, not failed, when this Mac's
Ghostty background is opaque; the driver checks still run); the source's local pane as the control
and pixel baseline; its auto-mirror matching it (driver fields and the pane's modal RGBA fill in a
`debug.window.screenshot`, within `--fill-tolerance`, default 6); the same after a fresh replay
(`supermux.devices.link` stop + restore); a program's `OSC 11` reaching the mirror live and through
the replay's authored-color sidecar; its `OSC 111` giving the mirror the shared backdrop back; and
with `--app-path`, the restored background mirror after a relaunch. Loopback shares one Ghostty
config between both ends, so a host color equal to this Mac's default could look right by accident:
`applied_remote_colors == {}` and `last_replay_color_osc == false` are the hard proof. Screenshots
are kept next to the JSON report (default `tests/supermux/artifacts/loopback_mirror_appearance_e2e-<tag>.json`).

```bash
CMUX_E2E_SUITES="loopback_mirror_appearance_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh
```

## Notification and phone-push parity E2E

`tests/supermux/loopback_notifications_e2e.py` (workstream Mb, touchpoints #545–#553) checks that
notifications behave between Macs as they do locally: the mirror copy keeps the remote project,
the viewer never forwards `.deviceMac` records to the phone (and leaves them out of the phone
badge), reads travel both ways, Mark as Unread on a host-read mirror copy survives the host's
next feed, a notification for a focused pane (the mirror's or the source's) stays unread with the
ring, the tab badge and the workspace badge until a real click in the pane clears it (DEBUG
`notification_indicators` / `notification_click`, plus a window screenshot of the ring beside the
report) or the notification is read on the other Mac (in both directions, #548/#722; a newer unread
copy on the same mirror pane keeps the ring when the host reads an older one), a present user's focused pane is not pushed to the phone while an away host's is, `notifications.suppressWhenAppFocused` withholds only the banner (panes the
user is not looking at stay unread on both Macs), a burst over the admission budget is fully
delivered, and `mobile.supermux.phone_push.status/share` work over the Mac link while `share`
refuses non-Mac callers. Like the smoke, it pauses auto-mirror for its run so its explicit
`vm.workspace_open` is the source's only mirror. Launch with a scratch direct-APNs directory so the
run never touches real credentials:

```bash
mkdir -p /tmp/<tag>/push-state
open -g --env SUPERMUX_DEBUG_LOOPBACK_DEVICE=1 --env SUPERMUX_PROJECTS_FILE=/tmp/<tag>/projects.json \
  --env SUPERMUX_PHONE_PUSH_STATE_DIR=/tmp/<tag>/push-state "<App path printed by reload.sh>"
CMUX_TAG=<tag> python3 tests/supermux/loopback_notifications_e2e.py --push-state-dir /tmp/<tag>/push-state
```

It drives DEBUG-only socket hooks (`supermux.devices.push_decisions`, `notification_records`,
`notification_overrides` (also sets `suppress_when_app_focused`), `notification_mark_unread`,
`phone_push_debug`, `phone_push_probe`, `phone_push_share_now`; see
`Sources/Supermux/Devices/SupermuxDeviceNotificationSocketCommands.swift`) and refuses to run the
share steps unless the app reports the scratch directory.

## Worktree pill E2E

`tests/supermux/loopback_worktree_disclosure_e2e.py` checks a project row's worktree pill through
`supermux.devices.projects_presentation`'s `worktree_disclosure {shown, count}` (built by the same
`SupermuxWorktreeDisclosure` the row uses). A fresh scratch project lives on This Mac and the online
Loopback Mac: it shows no pill, and the Loopback Mac's (empty) worktree list loads at refresh; a
worktree made there with `worktree.create {open: false}` shows "⑂ N ›" from a refresh alone; once
that worktree and the main checkout are open here and mirrored, the pill is gone again. It never
expands a row or calls `remote_worktrees` (both load the other Mac's list on their own). Remote-only
rows are checked against the same rule when there are any; the loopback shares this Mac's project
list, so it has none and that step is reported as skipped (`ok: null`, listed under `skipped_steps`
in the run-all summary). The remote-only pill is checked by dogfooding on a real second Mac. Best-effort
window screenshots land in `tests/supermux/artifacts/`.

```bash
CMUX_TAG=<tag> python3 tests/supermux/loopback_worktree_disclosure_e2e.py --scratch /tmp/<tag>
```

## New Worktree device picker E2E

`tests/supermux/loopback_new_worktree_picker_e2e.py` (workstream P2) drives the DEBUG
`supermux.devices.new_worktree.*` socket methods, which build the real New Worktree sheet model the
way a project row does. On a scratch repo it checks: the rows are This Mac then the Loopback Mac;
the Loopback Mac's branches and Claude commands load; a failing create shows the other Mac's
sentence and is not remembered; Create on the Loopback Mac ends with exactly one bound mirror,
selected in the window; the Mac is remembered and preselected next time, for a second project too
(one choice for every project), with This Mac preselected instead while that Mac's link is down, and
a Create on that fallback row (no row picked) does not replace the remembered Mac (the remembered
Mac is cleared at the start and restored at the end); and Start Claude runs
`agent.start` (with a temporary `echo` command, restored afterwards) and its mirror opens selected.
It then drops the loopback link on purpose (DEBUG `supermux.devices.link {machine, action:
stop|restore}`): an open sheet disables the dropped Mac and re-enables it after the redial without
losing the typed fields; a Create and a Start Claude whose link drops after the request went out (a
`post-checkout` hook slows `git worktree add` there, and `new_worktree.submit
{stop_link_after_seconds}` drops the link mid-call) end with "The connection to <Mac> dropped…",
never silently or with a raw `CancellationError`. Last, `worktree.create {open}`, `worktree.open`,
`project.open` and `agent.start` with `select: false` (what another Mac sends) leave every window's
selection alone, the phone's default still selects, and a remote create whose mirror opens unfocused
changes no selection. Because the loopback's two Macs share one window list, selection is checked
per workspace (`workspace.list`), and the sheet path checks the source workspace is not selected
while its mirror is. `--only a,b` runs a subset of steps.

```bash
open -g --env SUPERMUX_DEBUG_LOOPBACK_DEVICE=1 --env SUPERMUX_PROJECTS_FILE=/tmp/<tag>/projects.json "<App path>"
CMUX_TAG=<tag> python3 tests/supermux/loopback_new_worktree_picker_e2e.py --scratch /tmp/<tag>
```

## Mirror tab close E2E

`tests/supermux/loopback_mirror_tab_close_e2e.py` closes mirror tabs whose terminals run a program.
Three of a source workspace's seven terminals run a Claude Code stand-in (no step closes T5, so every
close is of a tab beside another; a workspace's last tab cannot be closed on its own) (alternate screen, kitty
keyboard flags, a marker line, a sleeping child; `--claude` runs the real CLI). The DEBUG drivers
`supermux.devices.terminal_close.{inspect, needs_confirm, replay}` report each mirror pane's
attachment and overlay plus the workspace's failure card, say whether the source would confirm a
close, and replay a pane. The suite checks that `mobile.terminal.close` without force answers
`confirmation_required` for a busy terminal (the host contract); closing a busy mirror tab closes it
there at once with no prompt and the tab stays gone (`busy_tab_close_forces`); a terminal projected
again into another workspace after a close on the same link attaches; Kill Terminal…
(`vm.terminal_close`) forces; an idle tab closes; and a tab closed while the link is down
(`supermux.devices.link stop`), busy or idle, disappears with no card and is closed there on
reconnect, never coming back, also when the other Mac answers that held close `server_busy`
(`offline_close_lands_on_a_busy_host`, #721: `supermux.devices.link {action: restore, busy:
"mobile.terminal.close"}` makes the loopback host answer the new connection's first such request so). On builds from before every close forced, the run pre-answers the old
"Close “X” on <Mac>?" prompt's DEBUG driver (`terminal_close.answer`) with Cancel and fails if it asked.

```bash
CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_tab_close_e2e.py [--claude]
```

## Mirror workspace close E2E

`tests/supermux/loopback_mirror_workspace_close_e2e.py` closes mirror workspaces the way the user
does: the DEBUG driver `supermux.devices.user_close {workspace_id | workspace_ids, answer}` runs
upstream's `closeWorkspaceWithConfirmation` (or the batch `closeWorkspacesWithConfirmation`) with
every close confirmation pre-answered and logged (`prompts: [{kind, title}]`), so no modal shows. It
checks that an idle mirror closes with no prompt at all and its source closes on the Mac, is not
hidden and is not reopened (W1); a mirror whose source runs a program closes there too (W2); a
multi-close of two mirrors and a local workspace asks at most upstream's "Close workspaces?" and
closes all three plus both sources (W3); a pinned source's mirror asks only "Close pinned
workspace?" (Cancel keeps both, Close closes both: the other Mac unpins it to close it, W4); a
mirror closed while the link is down goes at once, is listed in `hidden {}`'s
`pending_remote_closes`, and its source closes on reconnect without the mirror coming back (W5);
the host answers `confirmation_required` without force and closes with it (W6, the phone's
contract); and, with `--app-path`, a close made offline survives a quit and relaunch and lands once
the loopback is back (W7, run last). W8 pauses sending with the DEBUG
`supermux.devices.hold_remote_closes {enabled}` driver, so the source and its record stay while the
link is up, and checks that several auto-mirror passes reopen nothing (only the pending set guards
it), then releases the hold and the source closes. W9 closes a mirror offline, reopens it with the
DEBUG `supermux.devices.reopen_closed_workspace {}` driver (⌘⇧T, no activation) and checks that the
reconnect does not close the source and drops the pending close. W10 groups a mirror with a local
workspace and deletes the group with `workspace.group.delete {close_workspaces: true}`: the source
closes on its Mac and is not hidden. W11 builds a local workspace holding only terminals borrowed
(`surface.project`) from two sources, closes its own shell, and checks it is not taken for a mirror
and that closing it leaves both sources, their mirrors and the pending/hidden sets alone. W12 makes
the loopback host hold the next `workspace.close` for 30 s (`supermux.devices.link {action: "stall",
method: "workspace.close"}`): the close misses its 20 s deadline on a live link (`timed_out`), and for
26 s it must stay in `pending_remote_closes` with auto-mirror reopening nothing; then the source
closes and the pending close is forgotten. Before, the closer took `timed_out` as a refusal: it forgot
the close and beeped, and auto-mirror reopened the workspace until the held close ran.
W13 deletes the same kind of group from the phone (mobile `workspace.group.action {action: delete}` sent
over the loopback link with `supermux.devices.request`): the phone never listed the mirror member,
so its source stays open, is hidden here and is not queued for a close. W14 borrows one terminal of
a source into a local workspace (keeping its own shell), hides the source's mirror and unhides it:
the source gets its own mirror again, and auto-mirror runs at most a few passes in 3 s (the skip
loop ran ~15).

```bash
CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_workspace_close_e2e.py \
  [--app-path "<App path>" --projects-file /tmp/<tag>/projects.json]
```

## Terminal input E2E: tab chrome

`tests/supermux/loopback_terminal_input_e2e.py` also checks (`tabs_draw_no_device_accessory`, #720)
that, with the mirror attached to the source terminal, neither tab draws the attached-device avatar
while both keep their presence, which is what gives the tab's context menu its terminal-size section.
It reads each tab through the DEBUG `supermux.devices.mirror.tab_chrome {workspace_id, surface_id}`
driver (badge, loading state and presence with its participants). `keys_survive_busy_reconnect`
(#721) re-attaches with the loopback host answering this Mac's capability request `server_busy`
(`supermux.devices.link {action: restore, busy: "mobile.host.status"}`, what a Mac whose request quota
is full of re-attaching replays answers) and checks that Shift+Enter and a drag still reach the program
exactly, not through upstream's text path.

```bash
CMUX_E2E_SUITES="loopback_terminal_input_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh
```

## Terminal size policy E2E

`tests/supermux/loopback_terminal_sizing_policy_e2e.py` (touchpoints #665–#670) checks that a
terminal fills the Mac it is viewed from and that the size mode is one sticky choice per Mac. In the
loopback the source workspace is the "other Mac" and its auto mirror the viewer; DEBUG builds give
the loopback's mirrors a distinct sizing device id, so the two "Macs" have distinct priority keys. A
fake phone (`e2e-phone-…`, 40x12) and a fake second Mac (`e2e-mac-b-…`) report viewports
(`mobile.terminal.viewport`) on the control socket, their own connection as a real phone's or Mac's
link is: through `supermux.devices.request` they would share the mirror's device-link connection,
and the host names one client of a connection as its `self_participant_id`, so the mirror could take
the phone for itself. Steps: the source
terminal is Priority with the shown mirror first and takes its grid (decided and real PTY grid), even
while the other Mac's own small pane counts; a local terminal keeps its Mac pane's grid while the
phone views it; Follow Latest chosen on one mirror reaches every terminal, and new terminals (local
and over the link) start in it; a second Mac's own Priority choice is not pushed back by the shown
mirror (3 s hold, generation barely moves); its 400x150 pane is not clamped to 300x120; hiding then
showing the mirror, and a link drop after the other Mac reset the policy, claim the terminal again; a
priority order dragged on the mirror is stored relative to this Mac (`[phone, self]`) and reaches the
local terminal relative to its own view here (in the loopback its hidden auto-mirror, whose push of
the same order lands after the local apply, as for the source terminal); and with
`--app-path`, Largest Window survives a quit and relaunch. It drives the DEBUG
`supermux.devices.terminal_sizing.{state,reset,select_mode,set_priority}` methods
(`Sources/Supermux/Devices/SupermuxTerminalSizingSocketCommands.swift`), which run the size panel's
own actions, and resets the preference at start and end.

```bash
CMUX_TAG=<tag> python3 tests/supermux/loopback_terminal_sizing_policy_e2e.py --app-path "<App path>"
```

## Mirror Files panel E2E

`tests/supermux/loopback_mirror_files_e2e.py` checks that a device mirror's Files panel shows the
other Mac's folder. It drives the DEBUG `supermux.devices.mirror.files {workspace_id, action}` driver
(`Sources/Supermux/Mirrors/SupermuxMirrorFilesSocket.swift`), which keeps a Files store per workspace
and syncs it exactly like the right sidebar (`showHiddenFiles`, `syncWorkspaceRoot`), so the resolver,
provider, follow-the-folder observation and live refresh are the real ones. Actions: `state` (also
the expanded paths and the selection), `counters {reset?}` (the panel's visible refreshes since the
last reset, counted from the store's published values: `emptied`, `loading_shown`, `rebuilt`,
`git_published`, plus `refreshes`, the live refresh runs, which also counts a refresh that changed
nothing),
`expand`, `open` (the double-click path, after a download probe so a failure is a reply; with
`probe: false` it only starts the open and a refusal is the coordinator's alert), `preview` (the open
previews of a path and what each shows), `alert` / `dismiss_alert` (the alert up on the workspace's
window, and its OK), `materialize`, `search`, `menu` / `operation` (the context menu's file
operations), `local_rows` / `local_git_status` (what THIS Mac's panel shows for the same folder) and
`unmount`.

On a scratch git repo (dotfiles, a nested match, an image, a 9 MiB file, a symlink to `/etc` and a
sibling `outside/` folder) it checks: the Loopback Mac advertises `supermux.files_read.v1`; the
mirror's panel is the device provider at the source's folder and lists exactly what the local panel
lists there (hidden files, order); `src/` expands the same; the symlink out cannot be expanded (an
error naming the Mac); the git colors equal the local panel's; README.md opens a read-only preview in
the mirror with the file's exact bytes, and after it changes there reopening reuses that preview,
which shows the new bytes with no alert; the 9 MiB file is refused (8 MB), and opened the double-click
way the refusal is a sheet naming the limit while the app keeps answering, which OK dismisses;
Find returns the one nested hit and a query like `--version` is only a pattern; raw `files.*`
confinement probes (`..`, the symlink, a directory read, a wrong `expected_root`, renaming
`.git/HEAD`) are refused while chunked reads, `.git/HEAD` reads, hidden listing (with `home`), the
phone's dotfile-free listing, git status and search answer; a `files.read` of a named pipe in the
folder is refused at once (it never waits for a writer) and the link stays up; `cd src` / `cd ..` in the source
terminal re-roots the panel; a new file appears with no action (`--refresh-timeout`, default 6 s);
an idle panel does not refresh at all for `--idle-seconds` (default 5; every counter 0, `refreshes`
included, so a loop that re-lists unchanged folders fails too); while a file deep in `src/` and
`.git/index` change five times a second for `--churn-seconds` (default 6) the panel does not refresh
at all (every counter 0) and keeps its rows, `src/`'s expansion and the selection (the user's "refreshes
every second at the repo root": the old live refresh reloaded the whole tree for any change under
the folder); a file created and removed at the root appears and goes in place (a refresh runs and
rebuilds the rows, never emptied, `src/` still expanded, selection kept); the folder renamed away
there (the shell still in it) empties the panel with the reason, as the local reload does, and
renamed back its rows return;
the menu offers New File / New Folder / Rename / Duplicate / Move to Trash and each changes the
disk; with the link held down the panel names the Mac and says it is not connected (no rows), and
the redial brings the rows back; with `--app-path`, a relaunch with
`CMUX_DEBUG_SUPPRESS_MOBILE_CAPS=supermux.files_read.v1` shows "Update Supermux on Loopback Mac to
browse its files here." Move to Trash moves the scratch files to this Mac's Trash. macOS's own
Move to Trash can take tens of seconds per item on a headless Mac (with privacy prompts left up it
waited ~45 s in the kernel on `~/.Trash`, from any process), so Duplicate and Move to Trash get the
product's reply bound (`SupermuxDeviceReplyDeadline.fileCopy`) and the step reports each
operation's `op_seconds`. A call that gets no reply hangs up the suite's socket, so its late reply
cannot answer the next step's call.

```bash
CMUX_E2E_SUITES="loopback_mirror_files_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh
CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_files_e2e.py --scratch /tmp/<tag>/files \
  --app-path "<App path>" --projects-file /tmp/<tag>/projects.json
```

## Mirror local panels E2E

`tests/supermux/loopback_mirror_local_panels_e2e.py` checks that a mirror's own browser tabs keep the
mirror following its Mac (#706). On a background source S and its auto-mirror M it compares both
pane trees after every change, read through `supermux.devices.mirror.layout` (DEBUG: the tree the
device layout sync reads, plus each panel's kind; terminals are labelled by their source id T1…, the
mirror's browsers B and B2). A blank browser tab B joins M beside T1 (S unchanged); a split on S
reaches M with B kept beside T1; with M on screen, T2 moved after B in M reaches S without B; a
browser split B2 in M stays local while T2's split on S wraps it; B2 moved after T3 keeps its place
when S gets T4 in that pane; closing T1 in M closes it on S (the close path's guard, which still fails
with only the first fix); closing B and B2 leaves S alone and the pure mirror follows the next split.
Every expected pair must hold, then stay so for `--settle` seconds. Before the fix the third step
fails deterministically (the mirror's layout target is nil while B exists, so T2 is never projected).
The next step uses a second source S2 with ONE terminal, its mirror M2 and a browser B3 in M2: closing
the terminal's tab in M2 (`surface.close`) closes S2 on its Mac (it cannot keep a workspace without a
surface), M2 shows no failure card (`supermux.devices.terminal_close.inspect`), stays open holding only
B3 (`mirror.layout`'s `panel_kinds`) and is no longer a mirror (`supermux.devices.bindings`), S2 is not
in the Hide Here set and its pending close is forgotten (`supermux.devices.hidden`), and for at least 3
seconds nothing projects a terminal into M2, closes it or mirrors S2 again. Before that fix the owning
Mac refused `mobile.terminal.close` ("Cannot close the last surface"): the card showed, S2 kept running
and auto-mirror closed M2, browser included, as an orphan. The last step
(`last_two_terminals_beside_browser_close_source`) does the same with a third source S3 holding TWO
terminals in one pane, its mirror M3 and a browser B4 in that pane: Close Other Tabs on B4
(`tab.action close_others`) closes both terminal tabs in one main-actor turn, and the outcome must be
the same as for one terminal. The first close lands; the second is the owner's last surface and is
refused, and the mirror closes S3 on its Mac only then, on the layout that close fetched. Before
that fix the decision was taken in `projectionDidEnd` from the last accepted snapshot, which still
held both terminals, so the refused second close showed the card and auto-mirror orphan-closed M3
(the red run timed out waiting for S3 to close: "the mirror workspace closed, its browser with it").
`slow_last_terminal_close_keeps_mirror` repeats the one-terminal case with a fourth source S4 on a slow
link: the loopback host holds the `mobile.terminal.close` for 3 s (`supermux.devices.link {action:
"stall", method: "mobile.terminal.close", seconds: 3}`) before refusing it, and the step runs two
auto-mirror passes 1.2 s apart meanwhile (`supermux.devices.reconcile`, as a real link's device events
would; an idle loopback sends none). S4 must still close and M4 keep only its browser; the passes report
S4 in `busy`. Before that fix the first pass noted M4 (bound, nothing projected), the second confirmed it
as an orphan and closed it, browser included, and S4 kept running.
`late_last_terminal_close_keeps_mirror` repeats it with a fifth source S5 whose owning Mac's answer to
the `mobile.terminal.close` misses its reply deadline: `supermux.devices.tunnel.fail_requests {method:
"mobile.terminal.close", count: 1}` makes the loopback host answer it `timed_out` without running it, as
a viewer's link reports a reply that missed its 20 s deadline while that Mac still answers (#723). The
re-fetched layout still holds only that terminal, so S5 must still close and M5 keep only its browser,
with no failure card.

## Mirror browser E2E

`tests/supermux/loopback_mirror_browser_e2e.py` checks that a mirror's browser opens the owning
Mac's `localhost` (#707). In loopback both "Macs" share one loopback, so it checks the route, not
only that a page loads. Marker servers run in the script, in no workspace, one per step:
`localhost:P` opened in M loads through the mirror browser proxy and the owner's in-process tunnel
host (the tunnel journal's `opened` for P), in the loopback app instance's data store (the suite
computes it independently: a v5 UUID of `device:<uuid>@<tag>` in a namespace it pins), and the server
sees `Host: localhost:P`; `127.0.0.1` routes the same way; the same kind of URL in S stays direct (no
proxy configuration, the profile store, no tunnel open); this Mac's LAN address in M loads this
Mac's page with no tunnel open (Network.framework skips the proxy for this Mac's own addresses, as
for `localhost`, so the browser never asks it), and an authenticated CONNECT to that address, as
WebKit sends for any other LAN or public host, is dialed directly by the proxy (skipped without a
LAN address); a closed port opened in a new tab of M shows "localhost:N on <Mac> isn't
answering" within 5 s (its own tab, not the shared one: since WebKit 27 a navigation typed into a
tab, to plain HTTP on a host that is not loopback by name, as the `localhost` alias and a LAN address
are, leaves the page's hardened Enhanced Security WebContent process and swaps back at the response,
and on an affected host a swap into a WebContent process WebKit already had blocks its UI thread
about 5 s per sandbox extension, 10 s and more per page, in a bare `WKWebView` too); the proxy
refuses SOCKS no-auth (`05 FF`), a wrong password (`01 01`) and a CONNECT
without credentials (`407`), and the right credential connects; a terminal link opened in the cmux
browser from M's terminal opens a routed browser in M; the browser moved into S loses the route and
store, and moved back gets them again; with the tunnel driver's `pretend_old_host` and a relink the
page says to update Supermux on that Mac. Then the proxy's own hygiene: after relayed, refused (SOCKS
no-auth), failed (`502`), explained and, with a LAN address, direct proxy connections end, `lsof` on
the app (the pid listening on the proxy's port) shows no socket whose peer is one of the script's
clients, nor any dial to the LAN server (`proxy_connections_are_released`; before the fix each one
stayed in the app in `TIME_WAIT`); the route's data store for two machine ids that differ only by
tag are two stores (`data_store_per_app_instance`); a browser in an unbound mirror (auto-mirror off,
`vm.workspace_open`) loads the owner's page like a bound one's (`unbound_mirror_browser_routes`); 72 connections that
never send a byte are closed, at least the 8 past the 64-handshake limit at once and all by the 10 s
handshake deadline (`idle_proxy_connections_close`); after `browser_proxy_fail` the proxy replaces
its listener on its own (waited for with `browser_proxy start: false`, a read that starts no
listener, so the open tab never navigates inside the 1 s restart delay and with no restart the step
times out), then M's open tab and a new tab each load the owner's page on the fresh port
(`proxy_listener_failure_recovers`; the step it replaced navigated the open tab straight after the
failure and passed only while WebKit's swap delay above held the request past the restart: on a healthy
host it got `navigation_failed` in 0.09 s); and with the listener failed and held down
(`browser_proxy_hold`), a mirror tab opened meanwhile leaves the app instance's data store with its 2
proxy configurations, as the open tab's, a load in it while the listener is down fails and reaches
nothing, and once released it loads the owner's page (`restart_keeps_mirror_store_proxied`; before the
fix the new tab got no endpoint and its init wrote `[]` onto the store every mirror tab shares, 0
configurations, so the open tabs' `localhost` went to this Mac). Those three steps prove the route per
page, not by counting the owner's tunnel opens: this Mac runs its own server on the port they open and
the owner's page is served from another port that the loopback owner serves as that one
(`owner_and_this_mac`, `tunnel.serve_port`), so the owner's title proves the load came through the
owner and a request to this Mac's server fails the step. A count was not a proof: for 28 of 31 measured
navigations of the open tab WebKit opened 2 tunnels for its 1 request, and a request that rides a tunnel
opened earlier opens none, the likely cause of the one run where `proxy_listener_failure_recovers` saw no
`opened` for the new tab (both tabs had asked for the alias, per the app log, and no run ever sent a request
to this Mac's own server). Then `owner_localhost_keeps_origin` (#754, the user's Turnstile report): a login page with a
Cloudflare Turnstile widget (the always-passing test sitekey `1x00000000000000000000AA`) served on the owner's
`localhost:P`, with P forwarded to this Mac on P (`supermux.devices.ports.forward`), opened in a new mirror tab, must
run at `http://localhost:P`, a secure context, come from the owner (journal `opened` for P) and get a Turnstile token; the
same page in a local browser is the control that Turnstile works at all (it needs challenges.cloudflare.com). In
loopback the owner's P would be busy here too, so the owner serves P from another port Q
(`supermux.devices.tunnel.serve_port {port: P, from: Q}`, `SupermuxLoopbackServedPorts`: the loopback tunnel host
dials Q when asked for P), leaving P free for the forward as on two Macs; P is chosen below the ephemeral range, where
an outgoing connection's local port can take it meanwhile. Red before the fix: the tab ran at
`http://cmux-loopback.localtest.me:P`, `isSecureContext` false (a real dev sitekey answers 110200 there). The suite
passes with it anywhere in the order (checked first, before and after the listener-failure steps).

**A URL typed into a tab, to plain HTTP on a host that is not loopback by name, waits ~10 s on this Mac**
(WebKit and macOS 27, not the proxy; not a fail-open). WebKit 27 moves such a navigation into a new hardened
WebContent process (`triggerProcessSwapForEnhancedSecurity`, `continueNavigationInNewProcess`), and making one
blocks its UI thread in the kernel issuing font sandbox extensions (`registerUserInstalledFonts` ->
`_sandbox_extension_issue`, 759 of 1285 samples of one stall; only 1 font is installed here). Measured
2026-10-02 in a local tab with no proxy: typed navigations to the alias resolved directly took 10.76, 11.18
and 10.87 s and to this Mac's LAN address 10.47, 11.18 and 10.87 s (the first from a new tab 0.32 s), to
`localhost` 0.02–0.04 s. A mirror tab met it on every typed `localhost` URL, which became the alias: the
proxy's DEBUG connection traces (`browser_proxy` `connections`: accept, first byte, decision, tunnel open,
request/response bytes, end) showed WebKit's preconnect (its `PreconnectTask` has a 10 s timeout) completing
the SOCKS5 handshake at once, its tunnel open (main actor) waiting for the blocked main thread 11–13 s, no
request on it, and the real request on a new connection once the main thread was free; no connection
reached the proxy's handshake deadline. A deadline in the proxy could not help. A port forwarded here on the
same port loads as written (#754), so WebKit keeps the process: `typed_navigations_are_prompt` types 6
such URLs into the open mirror tab and wants each within 3 s (red on the pre-#754 build: 10.82–11.28 s,
the page at the alias; green: 0.03–0.06 s). Still slow: a mirror URL whose port is not forwarded on the
same port (the alias), and in any tab a plain-HTTP page on a LAN address or another non-localhost host.
That wait is why `proxy_listener_failure_recovers` once ran past `browser.navigate`'s own 17.5 s wait
(`navigation_timeout`); navigations of an open tab to the alias in the suite (`navigate_open_tab`) let that
wait run out and still require the owner's page. With the listener down and a Turnstile tab live in the
mirror, 4 of 4 rounds sent nothing to this Mac's own server.

DEBUG drivers
(`SupermuxMirrorBrowserSocket`): `supermux.devices.mirror.browser_route {workspace_id}` (per
browser: `routes_remotely`, `proxy_configs`, `store_identifier`), `.browser_proxy {machine, start?}`
(the endpoint it hands out now: port, credential, `owner_dials`, `direct_dials`, `failures`, `connections`
(its newest 64 connections' timelines); null
while it has none; starts the proxy unless `start` is false),
`.browser_proxy_fail {machine}` (runs the listener's `.failed` path; `failed_port`),
`.browser_proxy_hold {machine, held}` (while held no new listener is made, as when the system cannot
make one; releasing starts one),
`.browser_store {machine}` (the store identifier the route gives that app instance, any `device:` id)
and `.link_open {workspace_id, surface_id, url, destination}` (a terminal link click with the system
browser captured). It also uses the tunnel drivers `supermux.devices.tunnel.journal`,
`.pretend_old_host` and `.serve_port` of the tunnel lanes work.

```bash
CMUX_E2E_SUITES="loopback_mirror_local_panels_e2e loopback_mirror_browser_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh
```

Every suite at once: `CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh` (launches, runs and
quits the tagged app per suite; scratch state in `/tmp/<tag>-e2e`).

## Projects E2E: a blocked project folder

`loopback_projects_e2e.py`'s `projects_list_answers_while_a_folder_blocks` adds a project the way
another build does (the shared projects file, then a save that folds it in) whose `.git/config`
includes a named pipe nobody writes, so every git command there blocks, as in a folder behind an
unanswered privacy prompt. `projects.list` must answer within 4 s (the host's 2 s bound plus slack)
three times on the host (`supermux.devices.local_projects`) and once over the link; before the bound
it waited for git until the 5 s kill. Cleanup first ends any git there whose parent is launchd (left
by an app that quit, which no deadline ends any more), then opens the pipe for writing to release the
waiting git processes and removes it (a git woken from opening the pipe can still block reading it:
one ran on for an hour after a run). Each answer must also keep the healthy project's `git_remote_url` (the
last origin known stands in for a lookup not finished in time).

`first_load_is_bounded_while_a_folder_blocks` (needs `--app-path`; the runner passes it with
`--push-state-dir`) then makes a preset (`preset.create`, an `echo` command) and relaunches the app
with that project still registered, so the projects model's first load waits in its `git worktree
list` until the 30 s kill. Right after the link connects it sends, at once and each on its own socket,
`projects.list` (both projects, the healthy origin), `run.state`, `project.icon` (no icon:
`not_found` is an answer), `worktrees.list` for the healthy project and `preset.launch` into a fresh
workspace. Each must answer within 8 s (2 s for the load, 2 s more for the origins), the calls must end
within 25 s of the launch (else the step is vacuous), and the launch must open exactly one terminal.
Before the bound, `preset.launch` waited for the whole load and missed the 20 s deadline, and the
terminal still opened later.

`blocked_folder_git_never_outlives_its_bound` (the last step, also `--app-path`) runs before the
cleanup touches the pipe. A git process in the blocked folder is one named `git` (`lsof -c git`) whose
command line names the folder (`git -C <folder> …`) or whose working directory is in it (`git worktree
list`). None may have launchd as its parent (left by step 14c's quit); the origin lookups a
`projects.list` starts there must be gone 10 s after they were seen (the host kills each at 5 s); then
it sends `worktrees.list` for the blocked project (a `git worktree list` there, killed at 30 s), waits
until that git runs, quits the app, and no git process may remain in the folder 5 s after the app is
gone. It opens the app again for the cleanup. Before `SupermuxGitChildProcesses`, a git still running
when the app quit was left under launchd for good: the deadline timers die with the app.

## Tunnel lanes E2E

Port forwarding and a mirror's browser reach the owning Mac's loopback through upstream's irx
`tcp_connect` lanes on the device link's connection. The loopback link has no irx connection, so the
acceptor builds the real tunnel host for every admitted connection
(`SupermuxDeviceTunnelHosts.makeHost(peerIsMac: true, …)`, the decision `MobileHostIrxRuntime`'s
#693 fence makes for a real Mac peer) and serves it in-memory lanes
(`SupermuxDeviceLoopbackTunnelLane`: two pipes, the `IrxTunnelOpenReply` frame first, then raw bytes;
an abort on either half fails the other half's reads as a QUIC reset does). The viewer's
`SupermuxDeviceTunnelClient.open` takes that lane instead of an `IrxTunnelClient` lane when the
machine is the loopback device (`SupermuxDeviceLoopbackHarness.tunnelAcceptor(for:)`), after the same
availability checks (connected, `supermux.port_forward.v1`). So the real `IrxTunnelHost`, the
Mac-peer policy and limits, the loop guard, the MDM browser lock and Network.framework connects run;
the "owner" is this app's own loopback. The acceptor's authorization stands in for `stillAuthorized`:
managed policy plus the DEBUG revoke switch (the harness never turns on "Make this Mac
discoverable"). The host journals to its own ring (`tunnel.journal`), not the irx journal file.

`loopback_device_tunnel_e2e.py` (`supermux.devices.tunnel.*` drivers in
`SupermuxDeviceTunnelSocketCommands.swift`) runs its own marker servers, then checks: the capability
is advertised; a GET to `localhost:P` returns the marker; 30 GETs to a server that answers
`Connection: close` each read the whole page and then a clean end of stream (journal `closed clean`;
Network.framework's end-of-stream ENODATA used to abort about one in five); a `::1`-only server
answers `localhost`; the
host journals `opened {scope: loopback, port}` and never a host name; with this build's "iOS Browser
Reaches Other Hosts" turned on (`tunnel.allow_other_hosts`, read back after the opens so a cmux.json
that manages the key fails the step instead of turning it off, and put back afterwards), `169.254.169.254`,
`example.com` and `192.0.2.1` are still denied without resolving (journal `refused {scope: policy}`;
the phone's policy would resolve the name and try the literal); a closed port is `refused`; a port
registered as this app's own listener (`tunnel.own_port`) is denied (the loop guard); a revoked peer
is denied (`unauthorized`); `mobile.supermux.ports.list` attributes a server started in a workspace's
terminal to that workspace (after `surface.ports_kick`), lists the suite's own server only under
`other_ports`, and lists an injected non-listening port (`tunnel.inject_port`, which bypasses the
live-listener check) until it is cleared; a held tunnel ends when the link drops; with
`tunnel.pretend_old_host` the capability disappears and tunnels answer `needs_update`, then come back;
and when the workspace's terminal reports its live port plus one nothing serves (the v1
`report_ports`, no port scan, retried until the workspace still reports it after the listing),
`ports.list` keeps the live port and drops the dead one: the live-listener filter, not a scan,
removes it;
and with `tunnel.fail_requests` failing every
capability request after a relink (unknown capabilities, not absent ones) a tunnel answers
`unreachable`, the browser page's reason is `unreachable` and neither it nor the Settings ports note
asks for an update, the forwards' availability is `unreachable`, and once the host answers again the
forwards find it available with no relink (`unknown_capabilities_are_retryable`).

`tunnel.fail_requests {method, count}` makes the loopback host answer the next `count` requests for
`method` with `timed_out` (what the viewer's link reports for a missed reply deadline on a live
link, #723), counted only after each connection's `mobile.sync.fetch` so the dial's own
`mobile.host.status` identity check passes; `count: 0` disarms, and without `count` it reports
`{remaining, failed}`. `tunnel.http_get` answers a failed open with the mirror browser's error page
reason and headline too (`page_reason`, `page_headline`).

Run it: `CMUX_E2E_SUITES="loopback_device_tunnel_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh`.
The attribution step needs the sidebar's port detection (Settings: show ports, not "hide all
details"). Not covered here (two Macs only): `IrxTunnelClient` and QUIC flow control,
`DeviceIrxClient.supermuxTunnelConnection` (#694), the fence's `isMac` directory lookup,
`stillAuthorized` and `admission.recheck`, lane credit at 48 tunnels, a Tailscale-only link
(`no_direct_link`), and an Iroh link between dials (`unreachable`).
## Mirror simulator E2E

`tests/supermux/loopback_mirror_simulator_e2e.py` checks that a device mirror's Simulator runs on the
owning Mac (here the same app's source workspace S) and that the mirror M only shows it. The loopback
has no irx lanes, so the viewer's stream lane is the DEBUG `SupermuxRemoteSimulatorLoopbackLane`
(`Sources/Supermux/RemoteSimulator/`): two `SupermuxDeviceLoopbackPipe`s whose far end runs the
host's real `MobileSimulatorStreamV2Coordinator.handleLane`, so the real session, pump, VideoToolbox
encoder and worker ring run; only QUIC is replaced. It is chosen when the device `isLoopback`, and the
viewer owns its life (a link drop tears the stream down and closes it; the host ends `lane_closed`).

DEBUG drivers `supermux.devices.mirror.simulator.*` (`SupermuxRemoteSimulatorSocketCommands.swift`,
dispatched from `SupermuxDevicesSocketCommands`): `new_action {workspace_id, path: configured |
tab_bar}` (the configured `cmux.newSimulator` action on the selected workspace, or the pane tab bar's
button, installed on that workspace's tab bar first), `state {include_devices?}` (every Simulator tab
in every window: `class` `local` for a `SimulatorPanel`, `viewer` with `phase`, `phase_detail`,
`host_status`, `presented_frames`, `configs_applied`, `config {codec, width, height, orientation}`,
`quality`, `binding {machine, remote_workspace_id, host_panel_id, udid}` and, with `include_devices`,
the owning Mac's `devices`; plus `simulator_panel_count`, `viewer_count` and `app_pid`), the viewer's
own `input {panel_id, event: {button} | {text} | {key, down} | {touch, x, y}}`, `control {panel_id,
action}`, `quality {panel_id, preset}`, `select_device {panel_id, udid}`, `show_here {panel_id}`
(`accepted: false` when the panel is not a viewer), and `steal {host_panel_id}` (a second loopback
lane sends `start`, as the phone opening the same simulator would).

The suite creates its own simulator (`simctl create supermux-e2e-<tag>-<nonce>`, newest iOS runtime,
first iPhone type; `--udid` reuses one and never deletes it, `--keep-device` keeps it) and deletes it
at the end; with no iOS runtime every simulator step is skipped (`no_simulator_runtime`). Steps:
`xcrun simctl boot` typed into M's terminal boots it (on the owning Mac); `surface.create {type:
simulator}` on M fails; New Simulator (configured) leaves S with one `SimulatorPanel`, M with one
viewer bound to it and none of its own, the app with one `SimulatorPanel` more than before; the viewer
shows the booted device (skipped, after switching to it, when another booted simulator on this Mac is
the owner's first pick: booted, iPhone first, most recently booted; a device the suite just created and booted
has no `lastBootedAt` yet, so any simulator already booted on this Mac wins), streams (+10 frames, hevc/h264, long side <= 2000, one simulator worker more
under the app's PID; the window screenshot is kept as `…-viewer.png`); its picker equals the owner's
available iPhone/iPad simulators and choosing a second one (made for the step) boots it and the stream
follows (S's tab shows it, then the viewer plays new frames: two devices of one size bring no new config); Home brings SpringBoard back from Settings (`simulator.foreground` on S's panel, or a
`simctl io screenshot` hash); Rotate Left/Right turn the owner's simulator (`simulator.context`
orientation); Data Saver caps the next config at 800; with the viewer open a split in S is projected
into M, M splits the same way (the workspaces' own pane counts, one more than before; `pane.list` also lists the window's Dock pane), and M takes S's new name (needs the `device-layout-local-panels` fence and #739); closing a
mirror terminal tab closes its source terminal; the link held down stops the stream and back up
resumes it; `steal` leaves the viewer "superseded" for 10 s without taking the stream back, and Show
Here takes it; closing S's Simulator tab closes the viewer; closing the viewer closes S's tab, its
worker exits and the device stays booted (a new tab showing another booted simulator, the owner's first pick, is
first switched to the suite's device: the suite never stirs or touches another simulator, and an idle one may draw nothing); the tab bar's button behaves like the configured action;
with `--app-path`, the app quits within 60 s of `tell application id … to quit` while a simulator worker runs,
and osascript reports no error (the worker shares the app's bundle id and forwards the quit, #735; a failure names the
app pid and the worker pids before and after; the report records `quit_seconds`) and a relaunch restores the viewer in M, which streams S's
restored panel (on the suite's device) with no second `SimulatorPanel` (S's restored Simulator tab starts hidden, from
the stream; its first worker is replaced as the device attaches and the panel reports "worker stopped" until the
viewer asks it to recover after 5 s; a viewer that never streams reports the owner's status and its attachment).
After a failed relaunch the suite reconnects
for its cleanup, so it still closes its workspaces, deletes its simulators and writes its report. The app drops a
control-socket client that sent nothing for 30 s and step 4 waits on `simctl bootstatus`, so the suite's client
reconnects before a request after 20 s idle, and a socket error fails its step instead of ending the run. An idle home screen draws nothing, so the suite makes the simulator draw (launching
Settings, toggling the appearance) while it waits for frames.

```bash
CMUX_E2E_SUITES="loopback_mirror_simulator_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh
CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_simulator_e2e.py --app-path "<App path>" \
  --projects-file /tmp/<tag>/projects.json
```

Not covered here (two real Macs): the `simulator_stream` lane over QUIC (direct and relay) through
`DeviceIrxClient.supermuxTunnelConnection`, capture on a headless or locked owning Mac, frame rate and
latency, the phone and a Mac taking the stream from each other, and version skew.

## The ~20 s link flap (round 4) and why E2E did not see it

The round-4 visual check launched `rws-int` without `SUPERMUX_PROJECTS_FILE`, so it read the user's
real project list: 11 projects, all in ~/Documents. The tagged app's Documents privacy prompt sat
unanswered (behind two other system prompts), and every access there waited about 10 s in the kernel
and then failed (`Interrupted system call`; a `git worktree list` took 21 s). On every connect the
viewer asks `mobile.supermux.projects.list`; the host's handler waited for the projects model's first
load (31 s: each project's `config.json` import and `git worktree list`) and for a `git config`
origin lookup per project, which the 5 s git kill cannot end while the kernel holds it. The reply
missed the link's 20 s deadline, and the link took that as a dead transport and redialed: connected
for 20 s, then 30 s of backoff, 29 times in 22 minutes. Temporary request timing on both sides showed
`projects.list` timing out at 20.0 s on the viewer while the host was still running it (31.4 s), and
nothing else slow. `run_all_loopback_e2e.sh` always points `SUPERMUX_PROJECTS_FILE` at a scratch file,
so E2E runs had no ~/Documents projects and a stable link. Fixed by #723 (a missed deadline fails alone
while the host answers) and the host-side bounds (SUPERMUX.md, "A slow Mac is not a lost Mac").
When you check visually with the real project list, expect the same prompt: never answer it for the
user; the link now stays up regardless.

## How it works

```
viewer half (catalog / UI)                              host half (same process)
DeviceSurfaceProvider ── DeviceLink ── MobileCoreRPCClient
                                  │  iroh-kind route → transport admission, no Stack token
                   SupermuxDeviceLoopbackTransportFactory
                                  │  makes an in-memory pair per dial
      client end ◀── SupermuxDeviceLoopbackTransport ──▶ server end
                                                            │
                               SupermuxDeviceLoopbackHostAcceptor
                                 MobileHostService.acceptTransport(
                                   .irohAdmission(Mac grant peer),
                                   hostDeviceID: loopback id,
                                   peerRequestHandler: DeviceWorkspaceLayoutHost.handle)
                                                            │
                                 TerminalController.mobileHostHandleRPC (every mobile.* method)
```

| File (`Sources/Supermux/Devices/`) | Role |
|---|---|
| `SupermuxDeviceLoopbackHarness.swift` | Opt-in gate. Builds the record, runtime, `DeviceLink` and real `DeviceSurfaceProvider`, then calls `SurfaceCatalog.shared.register`. |
| `SupermuxDeviceLoopbackIdentity.swift` | Fixed device id `5e1f10b0-0000-4000-8000-000000000001`, synthetic Iroh endpoint and route, directory record, and the admitted Mac peer. |
| `SupermuxDeviceLoopbackHostAcceptor.swift` | Admits each server end as an Iroh Mac peer, with the same layout-host closures `MobileHostIrxRuntime` uses, and builds the connection's tunnel host. |
| `SupermuxDeviceLoopbackTunnelLane.swift` | In-memory `tcp_connect` lanes for that tunnel host (see "Tunnel lanes E2E"). |
| `SupermuxDeviceLoopbackTransport(Factory).swift`, `…Pipe.swift` | In-memory duplex byte stream with socket semantics: FIFO, EOF after close, and cancellable reads. |

- **Startup.** `SupermuxMobileHostGlue.activateIfNeeded()` starts the harness. It is a fork-owned
  file that upstream calls through the existing `mobile-supermux-observers` fence. The harness
  starts the first time that call finds the auth composition.
- **Upstream touchpoints.** There are two:
  - #525 `loopback-device-runtime`: a DEBUG extension on `DeviceLinkRuntime` that swaps its
    private `transportFactory`.
  - #526: the pbxproj entries for the six files.
- **The mobile host needs no listener.** `acceptTransport` is static, and the event, sync and
  terminal-byte planes run whenever the app runs. The harness does not turn on iOS pairing or
  "Make this Mac discoverable".
- **`DeviceLink` gates every request on `DevicesFeature.isEnabled`.** The harness registers
  process-only defaults (`register(defaults:)`, never persisted) that turn on the discovery opt-in
  and the Cloud beta toggle. An explicit `false` in the tag's defaults still wins. The log's
  `devicesEnabled=` field shows the result.
- **Why identity passes with no upstream exception.** The device id is synthetic, but the instance
  tag is this app's own tag. `mobile.host.status` answers with
  `mac_device_id = <loopback id>` (the acceptor passes `hostDeviceID`) and
  `mac_instance_tag = MobileHostIdentity.instanceTag()`. So `DeviceLinkHostIdentity.verify`
  matches, and `SurfaceDeviceInstanceID.isVisible(from:)` keeps the device visible to a dev viewer.
  A foreign tag such as `loopback` would be hidden.

## Caveats for other workstreams

> **Find devices through the catalog, not the registry.** The loopback provider is registered in
> `SurfaceCatalog.shared` only. `AppDelegate.devicesRegistry` and Settings › Devices do not know
> it. Use `SurfaceCatalog.shared.provider(for: machine) as? DeviceSurfaceProvider` and enumerate
> `.device` machines from `SurfaceCatalog.shared.snapshot.machines`. Otherwise your code does not
> see the loopback, and you cannot E2E-test it.

- **Loop hazard.** The loopback mirrors this app's own workspaces. The host export filter (#518/#519)
  keeps mirrors out of the device's records, so auto-mirror (on by default) opens exactly one mirror
  per source and never a mirror of a mirror. With the loopback on, the sidebar therefore shows every
  workspace twice (source + "Workspace on Loopback Mac" mirror). Step 5 of the smoke script reports
  whether mirrors are re-exported.
- **Ids collide.** Remote workspace and terminal ids *are* this app's local ids. Code that wrongly
  resolves a remote id as a local id (for example `Workspace.liveWorkspace(id: remoteID)`) finds
  the source and seems to work here, but breaks between two real Macs. Review id handling by
  reading the code as well.
- **Not covered.** Iroh transport, discovery and the directory, presence, `IrxMacPeerAuthorization`,
  the incoming-access toggle, pairing grants, and network-loss reconnects. A real two-Mac run is
  still required for those.
- **Admission is looser than a real Iroh peer's.** The harness skips the Iroh listener, directory
  admission and "Make this Mac discoverable". Managed policy still refuses remote control
  (`MobileRemoteControlPolicy.isDisabled`). This is acceptable only because the harness is
  DEBUG-only and opt-in.
- **Notifications show up on your desktop.** They come from the tagged app, and the first run may
  ask for notification permission.
- **Connection slot.** The loopback uses one of the host's 10 connection slots.
