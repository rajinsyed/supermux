# Supermux: remote Macs as first-class workspaces (DESIGN)

Status: implemented on branch `remote-workspace-sync`; verified end to end with the DEBUG loopback
device (`tests/supermux/run_all_loopback_e2e.sh`), not yet between two physical Macs. Owner: Supermux
fork. APIs: [FOUNDATION-API.md](FOUNDATION-API.md), [PROJECTS-API.md](PROJECTS-API.md); test harness:
[LOOPBACK-HARNESS.md](LOOPBACK-HARNESS.md).

## Problem

Workspaces on another Mac ("devices", upstream `Sources/Devices/*`) are reachable only from the
right-sidebar **Cloud** tab (`RightSidebarMode.machines`). They reach the left sidebar only after a
manual "open", they carry no project nesting, no agent activity, no branch/PR, no status pills, and
there is no way to pick a device when creating a worktree. The user does most coding on a remote
MacBook and wants Superset-style UX: every workspace from every Mac in the LEFT sidebar, grouped by
project, a device picker on create, live sync, correct notifications (including phone pushes while
the main Mac is closed), and the same on iOS.

## What already exists (do not rebuild)

- `DeviceLink` (one per remote Mac instance) speaks the same mobile RPC as the phone over iroh.
  `link.request(method, params:)` can call ANY host method, including `mobile.supermux.*` (iroh-admitted
  Mac peers get no per-request auth narrowing). `link.mirror.workspaces.orderedRecords` holds full
  `WorkspaceSyncRecord`s including the fork fields `supermux_project_id/activity/branch/pull_request/
  unread_count/unread_panel_ids`.
- `DeviceSurfaceProvider` publishes remote terminals into `SurfaceCatalog.shared`; opening a remote
  workspace projects it into an ordinary local `Workspace` whose panes are manual-mirror terminals
  (`DeviceTerminalMirrorSession`), with two-way layout sync (`DeviceWorkspaceLayoutCoordinator`),
  title sync, device notification feed delivery (`DeviceSurfaceProvider+Notifications`), and session
  restore of projected panes.
- Canonical "open existing remote workspace as local" sequence: `SurfaceSocketCommands.swift:~490`
  (`remoteWorkspaceGroup` → `CloudWorkspaceLayoutTranslator.fetch` → `projectGroupAsNewLocalWorkspace`
  → `bindCloudWorkspace`). Canonical create: `CloudTreeNodeActions.createWorkspaceAndOpenLocally` with a
  window-scoped `CloudWorkspaceCreationHost(manager:)`.
- Host RPCs for projects: `mobile.supermux.projects.list`, `project.open/create/update/delete/icon`,
  `worktrees.list{include_branches}`, `worktree.suggest_branch/create{open}/open/remove`,
  `agent.options/start`, `run.state/start/stop`, `action.run`, `preset.*`, `changes.*`, `files.*`.
- iOS already aggregates workspaces from every paired Mac (upstream multi-Mac P1–P5).

## Decisions

1. **Auto-mirror.** Every workspace on every connected device automatically gets a local mirror
   `Workspace` (setting `supermux.devices.autoMirror`, default ON). Mirrors are real local workspaces,
   so selection, unread, notification text, banners, tabs/splits, close, restore and keyboard
   navigation all reuse existing machinery. Superset shows every host's workspaces the same way.
2. **Mirrors are never re-exported.** The host skips device-mirror workspaces in `mobile.sync.*` and
   `mobile.workspace.list` (touchpoint). This prevents mirror-of-mirror loops between Macs and phone
   duplicates (the phone connects to both Macs directly).
3. **Close = close on the owning Mac**, with this Mac's normal close confirmations only (as for a
   local workspace; no prompt of the fork's). A close while that Mac is offline is kept (persisted)
   and sent when it reconnects; auto-mirror does not reopen it meanwhile, and Reopen Closed Workspace
   cancels it. Delete Group closes member mirrors on their Mac the same way. The row menu's "Hide Here"
   keeps it running there: it detaches and remembers the remote id in a hidden set so auto-mirror
   does not re-open it. A remote workspace that disappears on its host closes its local mirror.
   Closing a mirrored tab ends that terminal there (`force`), like a local tab.
4. **Remote Mac is the source of truth for its own projects.** Remote projects are aggregated live
   (never written into `supermux-projects.json`). Projects merge across devices into one sidebar row
   when their normalized git origin URL matches (new additive DTO field `git_remote_url`), falling
   back to identical `name` + `root_path`. Unmatched remote projects render as their own project rows
   with a device chip.
5. **Nesting by explicit id, never by path.** A mirror nests under the unified project that owns the
   remote record's `supermux_project_id`. Local path association (`SupermuxWorkspaceAssociationStore`)
   must never claim a mirror.
6. **Device picker** in the Mac New Worktree sheet (and iOS sheet): the devices where the unified
   project exists; default = the last device the user chose for a worktree (one choice for every
   project; This Mac, else the first Mac that can create, when that device lacks the project or is
   offline, and a create on that fallback does not replace the choice). Remote create runs on the
   remote (`worktree.create{open:true}` / `agent.start`), then the local mirror appears and is
   selected. "New Workspace on ▸ <Mac>" (the `+` menu and the sidebar empty area's context menu) for
   global (project-less) workspaces, which start in that Mac's home folder. A plain New Workspace
   (`+`, ⌘N, an empty-area double-click) always creates on this Mac, even with a mirror selected.
7. **Status parity on mirrors** from the remote record: activity (working / needs input / ready) via
   the fork `SupermuxWorkspaceActivityResolver` overlay; branch/PR in nested rows; additive
   `supermux_status_entries` / `supermux_progress` / `supermux_log` fields so `cmux set-status`,
   `set-progress` and `log` pills from the remote render on the mirror row. Host pokes sync on those
   changes and on branch/PR changes. A waiting agent (`backgroundWorkPending`) counts as working, and
   the additive `supermux_working_panel_ids` lets a mirror spin exactly the tabs whose agent works
   (re-synced on every status projector pass, so a tab projected after the record arrived spins too).
8. **Phone push comes from the Mac that runs the agent.** The viewer Mac never forwards `.deviceMac`
   notifications to the phone (and excludes them from its phone badge: every Mac pushes and reports
   only its OWN unread count, and the phone badges the total, keeping the latest count per Mac
   build — device id and instance tag, for the builds a Release phone pairs with — in the app group:
   `SupermuxPhoneBadgeLedger`, written by the notification service extension on every direct push
   and by the app from the foreground build's live count). The remote Mac pushes itself:
   the iPhone registers its APNs token with every connected Mac; the direct payload gains
   `macInstanceTag` so taps route; host focus-suppression becomes presence-aware (idle/locked Mac
   still pushes); Macs can share push credentials + known phone tokens with each other over the
   authenticated same-account link (opt-in setting, default ON for the Supermux identity).
9. **Notification read-state is shared.** A read/clear on the host marks the viewer's mirrored record
   read, and a read on the viewer (a click or typing in the mirror pane) reads the host's. A
   focused-pane arrival rings until clicked on either Mac, as upstream does (round 4).
10. **iOS** shows each Mac's projects (grouped per Mac when >1), navigation after Supermux RPCs maps
    Mac-local ids to scoped row ids, New Worktree has a Mac picker, push registration per Mac.
11. **Enabled by default** for `com.supermux.app`: seed `cloud.beta.machines.enabled`,
    `devices.discovery.enabled`, `devices.incomingAccess.enabled` once (only when unset).
12. **Test harness**: DEBUG-only "loopback device" (`SUPERMUX_DEBUG_LOOPBACK_DEVICE=1`) — a synthetic
    device whose DeviceLink talks in-process to this app's own mobile host. Same app = both Macs, so
    the full viewer+host pipeline runs in one tagged build (mirrors of own workspaces appear, remote
    create/close/status/notifications all exercised). Real two-Mac links need identical
    namespace+tag on two machines (release builds), which a single machine cannot provide.

## Architecture (fork-owned unless noted)

```
Sources/Supermux/Devices/
  SupermuxDevices.swift                 facade: connected devices, link access, typed RPC, host caps
  SupermuxDeviceWorkspaceIndex.swift    local mirror <-> (machine, remote workspace id) + records
  SupermuxDeviceMirrorCoordinator.swift auto-mirror reconcile loop, close/hide, restore dedupe
  SupermuxDeviceStatusProjector.swift   remote record -> mirror row status/activity/pills
  SupermuxDeviceLoopback*.swift         DEBUG harness
Sources/Supermux/Projects (remote)
  SupermuxRemoteProjectsModel.swift     per-device projects/worktrees/run state, events, cache
  SupermuxUnifiedProjects.swift         cross-device merge + nesting
  SupermuxRemoteWorktreeTarget.swift    New Worktree sheet backend over DeviceLink
Packages/SupermuxKit                    pure models + views (device chips, picker, unified rows)
Packages/Shared/SupermuxMobileCore      DTO additions (git_remote_url, status fields)
Packages/iOS/SupermuxMobile{Kit,UI}     per-Mac sessions, picker, navigation, push registration
```

Upstream touchpoints (fenced, registered from **#517**): DeviceLink event topics + supermux event
hook; host export filter for mirrors (MobileStateSync + workspace list); workspace close hook; flat
row device chip; notification phone-forward guard for `.deviceMac`; remote read mirroring; focused
arrival ack; layout-coordinator non-terminal stall fix; enablement seed next to #514; loopback
harness registration (DEBUG); iOS per-Mac seam next to #96.

## Workstreams and numbering

| Workstream | Touchpoints | pbxproj id prefix |
|---|---|---|
| F — foundation + loopback harness | #517–#529 | `50BE0004…` |
| M — mirror, status, notifications, enablement (Mac core) | #530–#559 | `50BE0005…` |
| P — projects across devices + Mac UI | #560–#579 | `50BE0006…` |
| I — iOS | #580–#599 | `50BE0007…` |

## Non-goals (this pass)

- Syncing pane geometry across devices beyond upstream's existing layout sync.
- Remote browser/markdown/simulator panels (upstream refuses to materialize them).
- Resizing the remote terminal grid to the viewer's pane (upstream pins mirrors to the source grid).
- Automatic cloning onto a device that lacks a project. Project sync only registers a repo that already exists at the same path; cloning is the explicit "Set Up on <Mac>…" action ([PROJECTS-API.md](PROJECTS-API.md)).
