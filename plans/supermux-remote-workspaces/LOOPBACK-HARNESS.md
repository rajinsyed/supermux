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
  + Show Hidden Workspaces, the other toggles, and the flat-row chip's state for the Loopback Mac.
  `--screenshot` also opens Settings on Automation and captures the window.
- `tests/supermux/loopback_sidebar_rows_e2e.py` reads the sidebar rows as drawn
  (`supermux.devices.sidebar_rows`) and the mirror close prompt without showing it
  (`supermux.devices.close_prompt`): nested rows list this Mac's workspaces before each Mac's
  mirrors, a nested mirror's accessibility label names its Mac, `set_status` / `set_progress` show on
  nested rows (local and mirror), a flat mirror's directory line omits the Mac name, and the prompt
  is safe (destructive Close on <Mac>, Cancel as the Return/Esc default, the Mac named once, the
  worktree outcome and Hide Here explained). Layout (chip placement and alignment, spinner size,
  the footer) is checked visually.

## Mirror rendering E2E

`tests/supermux/loopback_mirror_render_e2e.py` checks what the user sees, not the buffer: it selects
a terminal and pixel-samples its pane in a `debug.window.screenshot` (a pane counts as drawn when
`--min-ink`, default 200, pixels differ clearly from the pane fill). Steps: a plain background
workspace draws (the detector's control); its auto-mirror, opened in the background, draws; a
background local terminal that set OSC 11 draws; and with `--app-path`, after a quit and relaunch,
the restored mirror draws. Each sampled screenshot is copied next to the JSON report. It guards
touchpoint #538: a terminal whose pane-local OSC 11 fill arrived off screen used to stay blank when
shown, and mirrors always hit that because the owning Mac's replay carries its colors.

```bash
CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_render_e2e.py \
  --app-path "<App path>" --projects-file /tmp/<tag>/projects.json
```

## Notification and phone-push parity E2E

`tests/supermux/loopback_notifications_e2e.py` (workstream Mb, touchpoints #545–#553) checks that
notifications behave between Macs as they do locally: the mirror copy keeps the remote project,
the viewer never forwards `.deviceMac` records to the phone (and leaves them out of the phone
badge), reads travel both ways, Mark as Unread on a host-read mirror copy survives the host's
next feed, a focused mirror pane acknowledges the host, an away host keeps a focused pane's
notification unread, `notifications.suppressWhenAppFocused` withholds only the banner (panes the
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

## New Worktree device picker E2E

`tests/supermux/loopback_new_worktree_picker_e2e.py` (workstream P2) drives the DEBUG
`supermux.devices.new_worktree.*` socket methods, which build the real New Worktree sheet model the
way a project row does. On a scratch repo it checks: the rows are This Mac then the Loopback Mac;
the Loopback Mac's branches and Claude commands load; a failing create shows the other Mac's
sentence and is not remembered; Create on the Loopback Mac ends with exactly one bound mirror,
selected in the window; the Mac is remembered and preselected next time; and Start Claude runs
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

Every suite at once: `CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh` (launches, runs and
quits the tagged app per suite; scratch state in `/tmp/<tag>-e2e`).

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
| `SupermuxDeviceLoopbackHostAcceptor.swift` | Admits each server end as an Iroh Mac peer, with the same layout-host closures `MobileHostIrxRuntime` uses. |
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
