# Remote Macs foundation (F1): API for the M and P workstreams

Status: implemented on `remote-workspace-sync`. Design: [DESIGN.md](DESIGN.md). Touchpoints
**#517–#522** in `SUPERMUX-TOUCHPOINTS.md`. Everything below is `@MainActor` unless noted.

Where things live:

| Area | Files |
|---|---|
| App-target facade, index, opener, socket | `Sources/Supermux/Devices/*.swift` |
| Pure, package-tested pieces | `Packages/SupermuxKit/Sources/SupermuxKit/Devices/*.swift` (tests: `Packages/SupermuxKit/Tests/SupermuxKitTests/Supermux{DeviceBindingStore,GitRemoteURLResolver,DevicesSettings,ProjectGitRemotes}Tests.swift`) |
| Composition (one instance each) | `Sources/Supermux/Devices/SupermuxComposition+Devices.swift` |

## Composition

```swift
SupermuxComposition.devices               // SupermuxDevices (facade; started on first use)
SupermuxComposition.deviceWorkspaceIndex  // SupermuxDeviceWorkspaceIndex
SupermuxComposition.deviceWorkspaceOpener // SupermuxDeviceWorkspaceOpener
SupermuxComposition.deviceBindings        // SupermuxDeviceBindingStore (UserDefaults, per app domain)
SupermuxComposition.devicesSettings       // SupermuxDevicesSettings (.autoMirror)
SupermuxComposition.gitRemoteResolver     // SupermuxGitRemoteURLResolver (actor)
SupermuxComposition.projectGitRemotes     // SupermuxProjectGitRemotes (@Observable)
```

`SupermuxDevicesGlue.activateIfNeeded()` runs at launch (from `SupermuxMobileHostGlue.activateIfNeeded()`,
i.e. the existing `mobile-supermux-observers` touchpoint): it starts the facade and keeps
`projectGitRemotes` refreshed whenever `SupermuxProjectsModel.projects` changes. Start new device
coordinators (auto-mirror, status projector) from the same glue.

## `SupermuxDevices` — the facade

A device is any `.device` machine in `SurfaceCatalog.shared` whose provider is a
`DeviceSurfaceProvider` (real Macs and F2's DEBUG loopback device alike).

```swift
@MainActor @Observable final class SupermuxDevices {
    private(set) var devices: [SupermuxDevice]   // loopback last, then by name; reassigned only on change
    private(set) var revision: UInt64            // bumps ≤1×/runloop turn on ANY SurfaceCatalog change,
                                                 // link connect/loss, supermux.* event, bind/unbind
    func device(for machine: SurfaceMachineID) -> SupermuxDevice?
    func provider(for machine: SurfaceMachineID) -> DeviceSurfaceProvider?
    func records(on machine: SurfaceMachineID) -> [WorkspaceSyncRecord]   // full records incl. supermux_*
    func record(for ref: SupermuxRemoteWorkspaceRef) -> WorkspaceSyncRecord? // case-insensitive id match
    func registerLoopback(_ instance: SurfaceDeviceInstanceID)   // F2: mark the loopback device
    func unregisterLoopback(_ instance: SurfaceDeviceInstanceID)
    func scheduleRefresh()
    // events (SupermuxDevices+Events.swift)
    func events() -> AsyncStream<SupermuxDeviceEvent>   // one independent stream per call
    // RPC (SupermuxDevices+RPC.swift)
    // Reply deadlines: SupermuxDeviceReplyDeadline (SupermuxKit), one audited per-method table
    func request(_ method: String, params: [String: Any] = [:], on: SurfaceMachineID,
                 timeout: Duration? = nil) async throws -> [String: Any]
    func request(_ method: SupermuxMobileMethod, params:, on:, timeout:) async throws -> [String: Any]
    func request<R: Decodable>(_ method: String, params:, on:, timeout:, resultKey: String? = nil,
                               as: R.Type) async throws -> R
    func hostCapabilities(on: SurfaceMachineID) async -> Set<String>?   // mobile.host.status, once per connection
    func cachedHostCapabilities(on: SurfaceMachineID) -> Set<String>?
    func supports(_ capability: SupermuxMobileCapability, on: SurfaceMachineID) async -> Bool
}

struct SupermuxDevice: Identifiable, Hashable, Sendable {
    let machine: SurfaceMachineID            // device:<uuid>@<tag>
    let instance: SurfaceDeviceInstanceID
    let displayName: String
    let linkState: SupermuxDeviceLinkState   // .connected / .connecting / .offline
    let linkDetail: String?                  // catalog linkError (why offline/connecting)
    let hasFetchedRecords: Bool              // connected ∧ post-connect fetch ran ∧ mirror has state
    let isLoopback: Bool
    var isConnected: Bool
}

enum SupermuxDeviceEvent: Sendable {
    case linkConnected(SurfaceMachineID)     // after the post-connect mobile.sync.fetch → refetch caches
    case linkLost(SurfaceMachineID)
    case topic(SurfaceMachineID, SupermuxMobileTopic, payload: Data?)  // supermux.projects/worktrees/changes/run.updated
    var machine: SurfaceMachineID; var payloadObject: [String: Any]?
}
```

Rules for consumers:

- **Never close a mirror because its record is missing unless `hasFetchedRecords` is true.** Before the
  first post-connect fetch the mirror can hold the previous connection's records (or none).
  `hasFetchedRecords` becomes true on `linkConnected` (fired after the fetch attempt; a failed fetch still
  leaves the previous records, which only ever errs toward keeping mirrors).
- `request` errors are `SupermuxDeviceError` (`unknownDevice`, `notConnected(name)`,
  `hostRejected(code:message:)`, `malformedResponse`, …; `.code` is a stable string). A request that
  **times out makes the upstream link reconnect** (every mirror of that Mac drops), so callers never
  pick deadlines: `timeout: nil` applies `SupermuxDeviceReplyDeadline.forMethod(method)`, one audited
  table (exhaustive over `SupermuxMobileMethod`, derived from the host's own git/fetch/network/
  checkout/clone bounds, package-tested). Long host work (Changes history/push/pull, commit, AI
  message, worktree create/remove, agent.start, clone, …) gets a deadline that outlasts it; calls the
  host answers from memory keep the link's 20 s default. Only the DEBUG socket driver passes one.
- Decodable variant uses the `SupermuxWireJSON` convention (plain `JSONDecoder`, DTO `CodingKeys` carry
  snake_case). Example:
  `try await devices.request(SupermuxMobileMethod.projectsList.rawValue, on: m, resultKey: "projects", as: [SupermuxProjectDTO].self)`.
- Capabilities are cleared on every link edge and refetched lazily on the next `hostCapabilities` call.
- Remote projects carry `gitRemoteURL` / `gitRemoteIdentity` (see git origin below).

Delivery path (touchpoint #517, `Sources/Devices/DeviceLink.swift` → `SupermuxDeviceLinkEvents`): every
link subscribes to the four `SupermuxMobileTopic`s; their envelopes, the post-connect signal and the
link-lost signal land on the facade.

## `SupermuxRemoteWorkspaceRef` (SupermuxKit)

```swift
public struct SupermuxRemoteWorkspaceRef: Hashable, Codable, Sendable {
    public let machineID: String     // "device:<uuid>@<tag>"
    public let workspaceID: String   // canonical: uppercase uuidString for UUIDs, else trimmed
    public init(machineID: String, workspaceID: String)
    public static func canonicalWorkspaceID(_ raw: String) -> String
}
// app target (SupermuxRemoteWorkspaceRef+Surface.swift)
init(machine: SurfaceMachineID, workspaceID: String); init(machine:, record: WorkspaceSyncRecord)
var machine: SurfaceMachineID
```

Codable keys: `machine_id`, `workspace_id` (decoding canonicalizes).

## `SupermuxDeviceWorkspaceIndex` — local ⇄ remote

```swift
static func isDeviceMirror(_ workspace: Workspace) -> Bool   // used by the export-filter touchpoints
func isDeviceMirror(_ workspace: Workspace) -> Bool
func ref(forLocal workspace: Workspace) -> SupermuxRemoteWorkspaceRef?
func ref(forLocalWorkspaceID: UUID) -> SupermuxRemoteWorkspaceRef?
func localWorkspace(showing ref: SupermuxRemoteWorkspaceRef) -> Workspace?   // any main window
func record(for ref: SupermuxRemoteWorkspaceRef) -> WorkspaceSyncRecord?
func mirrors() -> [SupermuxDeviceMirror]         // {ref, workspace, isBound}
func bind(_ workspace: Workspace, to ref: SupermuxRemoteWorkspaceRef)
func unbind(_ workspace: Workspace)              // M: call when a mirror closes / is hidden
func unbind(ref: SupermuxRemoteWorkspaceRef)
func pruneBindings()                              // ONLY after session restore finished
var storedBindings: [UUID: SupermuxDeviceBindingStore.Binding]
```

- A workspace **is a device mirror** when the binding store names it (by `Workspace.stableId`), or when
  every pane projects a terminal of one and the same device workspace (live projection, or a restored
  projection still pending the link) — the set upstream's layout coordinator keeps synchronized. A local
  workspace with one borrowed remote pane, or one borrowing terminals of several remote workspaces
  (Open in New Pane from two of them, its own shell closed), is not a mirror: closing it closes it here
  only. The check is O(1) for local workspaces (it first asks `catalog.projectionMachines(forWorkspace:)`).
- `ref(forLocal:)`: binding first, else the device workspace most of its panes project (live + pending).
- `localWorkspace(showing:)`: binding (matched to a live workspace by `stableId`) first, else an unbound
  mirror (the `mirrors()` rule) whose ref is that remote workspace. A local workspace that only borrows
  some of its terminals does not show it, so auto-mirror and the opener still give it its own mirror.
- **Identity across restart.** Session restore keeps both `Workspace.id` and `Workspace.stableId`
  (`TabManager` restore uses `WorkspaceSessionRestoreIdentity` with the persisted `workspaceId`;
  `restoreSessionSnapshot` adopts `stableId`); both change only for duplicate reopens. Bindings are keyed
  by `stableId` with the last `Workspace.id` as fallback. Stored in this app's `UserDefaults` under
  `supermux.devices.mirrorBindings.v1` (so stable and tagged builds never share it), one remote workspace ↔
  one local workspace, capped at 512 (oldest evicted).

## `SupermuxDeviceWorkspaceOpener` — the one open/create path

```swift
struct Opened { let ref: SupermuxRemoteWorkspaceRef; let workspace: Workspace; let reused: Bool }

func openMirror(of ref:, in tabManager: TabManager, focus: Bool,
                createStarterTerminalIfEmpty: Bool = false) async throws -> Opened
func createWorkspace(on machine: SurfaceMachineID, title: String?, workingDirectory: String?,
                     in tabManager: TabManager, focus: Bool) async throws -> Opened
func awaitRemoteWorkspace(_ ref:, timeout: Duration = .seconds(30),
                          requireTerminal: Bool = true) async throws -> WorkspaceSyncRecord
func openWhenAvailable(_ ref:, in tabManager:, focus:, timeout: Duration = .seconds(30)) async throws -> Opened
```

- `openMirror` returns the existing mirror (any window) when there is one (`reused: true`); concurrent
  calls for one ref share one open (auto-mirror racing a click cannot duplicate). It runs the canonical
  sequence `remoteWorkspaceGroup → CloudWorkspaceLayoutTranslator.fetch → projectGroupAsNewLocalWorkspace
  (window-scoped SurfaceCatalog.NewWorkspaceHost(tabManager:)) → bindCloudWorkspace`, binds the local
  workspace **at creation** (so the export filter never leaks it), and selects it only when `focus`.
  An open that fails after creating the local workspace (e.g. the remote workspace closed meanwhile:
  "Unknown surface") unbinds and closes it again, so nothing half-created stays in the sidebar.
  A remote workspace with no terminal throws `.nothingToMirror` unless `createStarterTerminalIfEmpty`
  (auto-mirror should pass `false`; explicit user opens `true`). Browsers in the remote workspace are
  refused by upstream's `materialize` and simply skipped.
- `createWorkspace` sends `workspace.create {focus:false, title?, working_directory?}` fork-side (the host
  validates the directory; without one it sends `supermux_root_directory: true` and a fork host starts the
  workspace in its home folder, #621, instead of inheriting whatever it has selected), re-syncs, then opens through upstream's
  `CloudTreeNodeActions.createWorkspaceAndOpenLocally(… existingWorkspace:, existingTerminal:, host:
  CloudWorkspaceCreationHost(manager:))`. Passing the already-created workspace means the reservation's
  provisional **"Cloud VM" title is replaced in the same main-actor turn** and never renders. (Upstream's own
  ⌘N-on-a-device path still shows it during the round trip; route UI through this opener instead.)
- After a remote RPC that returns `workspace_id` (`mobile.supermux.worktree.create {open:true}`,
  `agent.start`, `project.open`, `worktree.open`): `openWhenAvailable(ref, in:, focus: true)` waits for the
  record (with a terminal), nudging `mobile.sync.fetch` every 2 s, then opens. Those four RPCs are sent
  with `select: false`, so the owning Mac opens the workspace in the background (its window never switches
  under whoever is using it; the terminal still starts) and only the mirror here is selected. The phone
  sends no `select` and keeps the old behavior.

## Settings and defaults

- `SupermuxDevicesSettings(defaults:).autoMirror` — key `supermux.devices.autoMirror`, default **true**.
- For `com.supermux.app` only, `CmuxFeatureFlags.init` (touchpoint #520) seeds
  `cloud.beta.machines.enabled`, `devices.discovery.enabled`, `devices.incomingAccess.enabled` to true once
  (marker `supermux.devices.releaseDefaultsSeeded.v1`), only where no value is stored
  (`SupermuxDefaultsSeed.applyOnce`). Tagged dev builds are unaffected (their Cloud gates come from
  upstream's dogfood marker; Devices discovery/incoming stay at their stored values).

## Git origin (cross-device project identity)

- Host: `mobile.supermux.projects.list` and the `project.create/update` results carry the additive
  `git_remote_url` (`SupermuxProjectDTO.gitRemoteURL`; compare with `.gitRemoteIdentity`, the normalized
  `host/owner/repo` key). Omitted when the project has no origin (legacy wire shape).
- Resolution: `SupermuxGitRemoteURLResolver` (actor) runs `git -C <root> config --get remote.origin.url`,
  caches per standardized root for 10 min (definitive "no origin" cached; transient failures not), coalesces
  concurrent lookups; `invalidate(root:)` / `invalidateAll()`.
- Local Mac UI: `SupermuxComposition.projectGitRemotes` (`@Observable`): `urlsByProjectID`,
  `url(for:)`, `identity(for:)` — match a local project with a remote `SupermuxProjectDTO` by
  `projectGitRemotes.identity(for: local.id) == remote.gitRemoteIdentity` (fall back to `name` +
  `rootPath` per DESIGN decision 4).

## Loop guard (touchpoints #518/#519)

`MobileStateSyncHost.buildRows` (state sync v2) and `mobile.workspace.list` skip every workspace for which
`SupermuxDeviceWorkspaceIndex.isDeviceMirror` is true. The notification feed already drops `.deviceMac`
rows upstream. Consequence for M: a mirror must be bound (or fully projected) **before** anything else
could export it — the opener guarantees this; any other path that creates mirrors must call
`index.bind(_:to:)` immediately.

## Debug/E2E socket (touchpoint #521)

Raw v2 calls through the tagged CLI (socket `/tmp/cmux-debug-<tag>.sock`):

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.list '{}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.list '{"include_capabilities":true}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.bindings '{}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.local_projects '{}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.open '{"machine":"device:<uuid>@<tag>","remote_workspace_id":"<id>","focus":false}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.create_workspace '{"machine":"device:…","title":"t","cwd":"/path/on/that/mac"}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.await_open '{"machine":"device:…","remote_workspace_id":"<id>","timeout_seconds":60}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.request '{"machine":"device:…","method":"mobile.supermux.projects.list","params":{}}'   # DEBUG builds only
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.bind '{"workspace_id":"<local>","machine":"device:…","remote_workspace_id":"<id>"}'   # DEBUG only
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.unbind '{"workspace_id":"<local>"}'   # DEBUG only
```

Params: `window_id` (optional, a main window UUID) picks the target window for `open`,
`create_workspace` and `await_open`; otherwise the preferred main window. `focus` defaults to false.
`open` also takes `create_starter_terminal`. Timeouts: `await_open.timeout_seconds` 1–600 (default 30),
`request.timeout_seconds` 1–600.

Result shapes:

- `list` → `{revision, auto_mirror, devices: [{machine, device_id, tag, name, link_state, link_detail,
  has_fetched_records, is_loopback, capabilities|null, record_count, records: [{id, title, is_selected,
  current_directory, terminal_count, supermux_project_id, supermux_branch, supermux_activity,
  supermux_unread_count, mirror_workspace_id|null}]}]}`
- `bindings` → `{mirrors: [{workspace_id, stable_id, title, window_id, is_selected, machine,
  remote_workspace_id, is_bound, remote_title}], stored: [{stable_id, workspace_id, machine,
  remote_workspace_id, bound_at, is_live}], local_workspaces: [{workspace_id, stable_id, title, window_id,
  is_selected, is_device_mirror, projected_remote_status: {status_keys, log, progress}}]}`
  (`projected_remote_status`: the remote pills, log line and progress the mirror status projection left
  in that workspace; a workspace that stopped being a mirror carries none)
- `local_projects` → `{host_payload: <this Mac's exact mobile.supermux.projects.list result, with
  git_remote_url>, local: [{id, name, root_path, git_remote_url, git_remote_identity}]}` (the latter from
  `SupermuxComposition.projectGitRemotes`)
- `open` / `create_workspace` / `await_open` → `{workspace_id, stable_id, title, window_id, is_selected,
  machine, remote_workspace_id, reused}`
- `request` → `{result: <host result object>}`
- `bind` / `unbind` (DEBUG) → the local workspace payload plus `is_device_mirror` — test hooks for the
  export filter and restart-stable bindings without a second Mac
- Errors: `{ok:false, error:{code, message}}` with `invalid_params`, `unknown_device`, `not_connected`,
  `timeout`, `nothing_to_mirror`, `window_unavailable`, `malformed_response`, the host's own code, or
  `method_not_found`.

## Device mirrors: auto-mirror, close, status (workstream Ma, touchpoints #530–#537)

Implemented on `remote-workspace-sync`; E2E: `tests/supermux/loopback_auto_mirror_e2e.py`.

```swift
SupermuxComposition.deviceMirrorCoordinator   // auto-mirror loop (started by SupermuxDevicesGlue)
SupermuxComposition.deviceMirrorCloser        // user close on the Mac / Hide Here / programmatic + coordinator closes
SupermuxComposition.deviceStatusProjector     // remote record -> mirror row status
SupermuxComposition.hiddenRemoteWorkspaces    // "Hide Here" set (SupermuxKit, UserDefaults)
SupermuxComposition.pendingRemoteWorkspaceCloses // closes waiting for their Mac (same store, own key)
SupermuxDeviceMirrorsGlue.unhide(machineID:ref:)   // unhide + reconcile
```

- **Auto-mirror** (`supermux.devices.autoMirror`, default on): one mirror per remote workspace with ≥1
  terminal on every authoritative device (connected and fetched since connect), skipping hidden refs and
  refs with an open in flight, a failed open backing off (10 s) or a close pending on its Mac
  (`coordinator.busyRefs`). Opens run one at a time via `openMirror(focus: false)` into the window holding
  that device's mirrors (else the preferred main window; never a new window) and take the remote order
  among their siblings. Nothing runs until `AppDelegate.didCompleteInitialSessionRestore`; then
  `pruneBindings()` runs once. Decisions: pure `SupermuxMirrorReconciler` (SupermuxKit, package-tested).
- **Closing by the coordinator** (local only, never prompts, never remote): a mirror whose remote workspace
  is absent in two passes ≥1 s apart while the device is authoritative (also with auto-mirror off); a bound
  mirror with no live or pending projection while its remote workspace exists (orphan; reopened fresh);
  every mirror but one of a remote workspace shown twice (duplicate, e.g. a reopened closed window next to
  auto-mirror's replacement; the one the user keeps survives: a projected one first, then the one selected
  in its window, then one the user opened, reopened or restored over a copy auto-mirror opened in this
  session, then the bound one, then the lowest local id; an unbound survivor takes over the binding and its
  applied-customization baseline before the copy closes, so its local edits hold; only with auto-mirror
  on, never while an open of the ref is in flight).
- **Scheduling**: passes coalesce to the earliest pending deadline, so a failed open's 10 s backoff never
  delays the 200 ms triggers (status, new or closed remote workspaces); every pass re-arms a pass for the
  earliest backoff expiry.
- **User closes** of a mirror work like a local workspace's: only upstream's confirmations on this Mac
  (pinned, running process, the close settings, the batch "Close workspaces?"), then
  `closer.closeOnItsMac` (the #530 fence after them) closes the mirror here and sends
  `workspace.close {force: true}` to its Mac; `protected` (pinned there) unpins it there
  (`workspace.action unpin`) and closes again; any other refusal beeps and the mirror comes back. The ref
  sits in the persisted pending set (`supermux.devices.pendingRemoteCloses.v1`, never the hidden set) until
  that Mac's records no longer hold it, so a close made offline is sent on reconnect (also after a
  relaunch: `closer.sendPendingCloses()` runs on every auto-mirror pass) and auto-mirror never reopens it.
  A close not sent yet is cancelled when a live local mirror shows the ref again (Reopen Closed
  Workspace, a manual open), so ⌘⇧T after an offline close undoes it. Delete Group (sidebar, or socket
  `workspace.group.delete` with `close_workspaces`) closes member mirrors on their Mac the same way (#530
  fence 3). The phone's Delete Group (mobile `workspace.group.action delete`) hides them instead (#697):
  the phone never lists mirrors, so its confirmation never showed them. The sidebar rows' menus also offer Hide Here (no prompt). Other programmatic closes
  (`closeWorkspace(recordHistory: true)`: socket `workspace.close`, AppleScript) hide. Every close unbinds. Window close, quit
  and restore never hide or close remotely. Route any new user close UI through
  `TabManager.closeWorkspaceWithConfirmation` (or the batch variant) so it closes on the Mac.
- **Status**: `deviceStatusProjector.status(forLocal:)` → `SupermuxDeviceMirrorStatus` (activity, branch,
  PR, pills, progress, log, color, description, pin). `SupermuxWorkspaceActivityResolver.activity(for:)`,
  `Workspace.supermuxSidebarBranch` and the new `Workspace.supermuxSidebarPullRequest` already overlay it,
  so nested project rows (`SupermuxWorkspaceRow.snapshot`), the switcher and flat rows (#532) show remote
  values; changes fire `SupermuxWorkspaceLifecycleRelay`. Color, description and pin are copied only when
  the remote value changed since the one last applied; that baseline is persisted with the binding
  (`SupermuxDeviceBindingStore`, `applied_customization`), so a local edit on a mirror survives a relaunch.
  A workspace that stops being a mirror loses the remote pills, log line and projected progress. Remote pills live on the mirror under the key
  prefix `supermux.remote.` (`SupermuxDeviceStatusProjector.remoteStatusKeyPrefix`), the remote log line
  has source `supermux-remote`. Never write an agent lifecycle into mirror panes (hibernation).
- **Record fields** (state sync v2, additive): `supermux_status_entries` `[{key,value,icon?,color?,priority?}]`,
  `supermux_progress` `{value,label?}`, `supermux_log` `{message,level?}`, `supermux_working_panel_ids`
  `[terminal id]` (terminals whose own agent is running or waiting; `nil` from an older host, `[]` when
  none: the mirror spins those tabs, #716/#717; a Claude harness pane's id can appear too and matches
  no mirror tab); `supermux_branch` /
  `supermux_pull_request` now also travel for workspaces no project owns (v2 only; the phone reads them
  only on project rows). The host pokes sync on sidebar-metadata changes
  (`SupermuxMobileSidebarStatusObserver`).
- **Layout sync** skips remote non-terminal panels (browser/markdown) instead of stalling (#531), and
  a bound mirror's own non-terminal panels stay local (reserved: never pushed, grafted back) instead of
  stopping it (#706, `SupermuxDeviceLayoutSurfaceFilter.localPanelIDs`).
- **Mirror browsers** (bound or unbound mirrors) use upstream's remote-workspace mode with the owning
  app instance's proxy and a per-instance data store (#707, `SupermuxDeviceBrowserRoute`,
  `SupermuxDeviceBrowserProxies`), so their `localhost` is that Mac's.
- **Socket** (`supermux.devices.*`): `close_mirror {workspace_id, action: close_on_mac|hide}` (a user
  close without this Mac's confirmations, or Hide Here; `pending_on_mac`),
  `unhide {machine?, remote_workspace_id?}`, `hidden {}` (`hidden`, `pending_remote_closes`),
  `set_auto_mirror {enabled}`, `reconcile {}`,
  `fail_next_open {machine, remote_workspace_id}` (DEBUG: the next auto-mirror open of that ref fails),
  `user_close {workspace_id | workspace_ids, answer?}` (DEBUG: a user close with upstream's confirmations
  pre-answered and logged), `reopen_closed_workspace {}` (DEBUG: ⌘⇧T without activating; `reopened`,
  `workspace_ids`), `hold_remote_closes {enabled}` (DEBUG: keep pending closes unsent; disabling runs a
  pass);
  `list` gains `auto_mirror_state`; `bindings` gains `hidden` and a per-mirror `status` object.
  Palette: "Show Hidden Remote Workspaces".

## Sync gaps and user controls (workstream X, touchpoints #595–#599)

- **Background tab changes reach mirrors.** The owning Mac's `DeviceWorkspaceLayoutHost` captures
  through `SupermuxDeviceLayoutChangeObserver` (#595): the capture is observation-tracked (bonsplit's
  split tree and the pane registry are `@Observable`), so any tab add/close/move/reorder/selection in
  a workspace a viewer asked about triggers a re-capture 40 ms later, whether or not the workspace is
  on screen; `device.workspace.layout.changed` goes out only when the arrangement changed. Nothing
  needs to force a layout pull after a remote launch any more. E2E:
  `tests/supermux/loopback_tab_sync_e2e.py` (socket and phone tab creation, close, reorder, each
  under 1 s).
- **Settings › Automation › Remote Macs** (`SupermuxRemoteMacsSettingsCard`, #596–#598; app side
  `SupermuxComposition.remoteMacsSettings`): the `autoMirror` / `syncProjects` / `sharePush` toggles
  (auto-mirror reconciles at once), discoverable / discovering status with Turn On through upstream's
  `ComputersSettingsActions` (consent sheet included) and, once on, a "Change in Devices…" link to
  Settings › Remote & Devices › Devices (where both switches live), the known Macs with link state
  and workspace counts (laid out like the Devices page's rows; that page lists only Macs upstream's
  registry knows, so never the DEBUG loopback), and Show Hidden Workspaces.
- **Socket** (`supermux.devices.*`, all builds): `remote_macs_settings {}` (the card's snapshot plus
  `discovery_enabled` / `incoming_access_enabled`), `remote_macs_settings_set {setting:
  auto_mirror|sync_projects|share_push, enabled}` or `{action: show_hidden}` (the card's own
  actions), `flat_chips {}` (per mirror: `label`, `mac_name`, `chip_state`, `dimmed`, and what the flat
  row draws: `style: "icon"`, `symbol`, `badge_symbol`, `help`, `placement` `branch_line|title_line`). E2E:
  `tests/supermux/loopback_remote_macs_settings_e2e.py [--screenshot]`.

## Not done here (owned by later workstreams)

- Notification read mirroring / phone push (Mb).
- Remote projects model, unified project rows, device picker (P).
