# Projects across Macs (P1): API for P2, W and M

Status: implemented on the P1 branch. Design: [DESIGN.md](DESIGN.md) decisions 4–6. Builds on
[FOUNDATION-API.md](FOUNDATION-API.md). Touchpoints **#560–#561**. Everything below is `@MainActor`
unless it says otherwise.

| Area | Files |
|---|---|
| Pure types and rules (package-tested) | `Packages/SupermuxKit/Sources/SupermuxKit/Devices/Supermux{ProjectLocation,UnifiedProject,UnifiedProjects,UnifiedProjectList,ProjectSyncPlanner,ProjectSyncSuppression,RemoteProjectsCache,RemoteWorktree,ProjectSetupService}.swift`, `SupermuxPaths+RemoteProjects.swift` |
| Sidebar UI (package) | `…/SupermuxKit/UI/Supermux{DeviceChip,RemoteProjectRowView,RemoteWorktreeRowView,RemoteNewWorktreeSheet,ProjectSetupSheet,RemoteProjectActions,RemoteProjectsPresentation}.swift`, `SupermuxProjectsSectionView+Remote.swift`, `SupermuxProjectRowView+Remote.swift` |
| App glue | `Sources/Supermux/Projects/*.swift` |
| Wire contract | `SupermuxMobileMethod.projectProbe/.projectClone`, `SupermuxMobileCapability.projectSetupV1`, `SupermuxProjectProbeDTO` (SupermuxMobileCore) |
| Tests | `Packages/SupermuxKit/Tests/SupermuxKitTests/Supermux{UnifiedProjects,ProjectSyncPlanner,RemoteProjectsCache}Tests.swift`, `…/SupermuxMobileCoreTests/SupermuxProjectProbeDTOCodingTests.swift`, E2E `tests/supermux/loopback_projects_e2e.py` |

## Composition

```swift
SupermuxComposition.remoteProjects          // SupermuxRemoteProjectsModel (per-device projects, runs, worktrees, icons, cache)
SupermuxComposition.unifiedProjects         // SupermuxUnifiedProjectsModel (.list, .mirrorOwners, .hasRemoteOnlyProjects)
SupermuxComposition.projectSync             // SupermuxProjectSyncCoordinator
SupermuxComposition.projectSetupService     // SupermuxProjectSetupService (probe + git clone; nonisolated)
SupermuxComposition.projectSyncSuppression  // SupermuxProjectSyncSuppression (roots a user removed; actor, shared file)
SupermuxRemoteProjectCommands.shared        // the one path for remote project actions (below)
```

`SupermuxProjectsGlue.activateIfNeeded()` starts the three models; it runs from
`SupermuxDevicesGlue.activateIfNeeded()` (no new upstream hook).

## Types other workstreams consume (SupermuxKit, `public`, `Sendable`)

```swift
struct SupermuxProjectDevice { machineID: String; name: String; isOnline: Bool }

struct SupermuxProjectLocation: Identifiable {           // one Mac's copy of a project
    enum Place { case thisMac, device(SupermuxProjectDevice) }
    let place: Place
    let projectID: UUID      // that Mac's project id — only ever use it in RPCs to that Mac
    let rootPath: String     // the root on that Mac
    var id: String           // "local:<uuid>" or "<machine>:<uuid>"
    var isThisMac, device, machineID, isOnline
}

struct SupermuxUnifiedProject: Identifiable {             // one sidebar project row
    let id: UUID             // local project id when this Mac has a copy; else a derived id
    let name, colorHex, iconSymbol, gitRemoteIdentity
    let locations: [SupermuxProjectLocation]              // This Mac first, then devices in device order
    var localLocation, localProjectID, remoteLocations, isRemoteOnly
    func location(onMachine: String) -> SupermuxProjectLocation?
    func devicesLacking(among: [SupermuxProjectDevice]) -> [SupermuxProjectDevice]   // "Set Up on <Mac>" targets
}

struct SupermuxUnifiedProjectList {
    let projects: [SupermuxUnifiedProject]                 // sidebar order
    var remoteOnly: [SupermuxUnifiedProject]
    func project(id: UUID) -> SupermuxUnifiedProject?
    func projectID(onMachine: String, remoteProjectID: UUID) -> UUID?   // record.supermux_project_id → unified
    func projectID(forLocalProject: UUID) -> UUID?
    func project(forLocalProject: UUID) -> SupermuxUnifiedProject?
}

enum SupermuxUnifiedProjects {
    static func merge(local: [LocalProject], devices: [DeviceProjects]) -> SupermuxUnifiedProjectList
    static func remoteOnlyID(machineID: String, projectID: UUID) -> UUID
    static func sameRoot(_:_:) -> Bool
}
struct SupermuxRemoteWorktree { location, path, branch, isDirty, pullRequest; id; displayName }
struct SupermuxRemoteWorktreeRequest { workspaceName, branchName, baseBranch }   // blank = let the Mac decide
enum SupermuxProjectSetupDestination { case thisMac, device(SupermuxProjectDevice) }
```

### Merge rules (`SupermuxUnifiedProjects.merge`)

Per device, a remote project joins a local project when (1) their normalized origins are equal and
that origin is unique among the local projects AND among that device's projects, else (2) their
names and standardized root paths are identical and their origins do not conflict (two different
known origins never merge). A local project takes at most one project per device. Everything left
on a device becomes a remote-only project (no cross-device merge of remote-only projects). Order:
local projects in their own order, then remote-only ones grouped by device (device order), by name.
Ids: a project with a local copy keeps the local project's id — so existing nesting, association and
expansion keep working — and a remote-only project gets `remoteOnlyID(machine, remoteProjectID)`,
never the remote Mac's own UUID (the loopback device's ids equal local ids; so could a copied file's).

## `SupermuxRemoteProjectsModel` (app target, `@Observable`)

The single per-Mac Supermux state: the sidebar AND the device-mirror behaviors (⌘G / Run via
`SupermuxMirrorRunController`, presets bar via `SupermuxMirrorPresetLauncher`) read it, so each Mac
is polled once (workstream X folded W's former `SupermuxMirrorRemoteState` into it).

```swift
private(set) var devices: [SupermuxDeviceProjects]   // device order; offline ones keep cached projects
private(set) var icons: [String: NSImage]            // key: projectKey(machine:projectID:)
func device(_ machine: SurfaceMachineID) -> SupermuxDeviceProjects?
func icon(machine:projectID:) -> NSImage?
func refresh(_ machine) async                         // projects.list (projects + presets) + run.state + icons + wanted worktrees; coalesced
func refreshAll()
func refreshRuns(_ machine) async                     // run.state only (after a mirror's Run / Stop)
func apply(run: SupermuxRunStateDTO, on machine)      // fold a run.start/stop result in before the poke lands
func ensureWorktrees(on machine, projectID:)          // lazy first load (rows call it on expand)
func refreshWorktrees(on machine, projectID:) async   // worktrees.list {include_branches: false}

struct SupermuxDeviceProjects {                       // ids are that Mac's ids
    machine, name, isOnline, isLoopback, projects: [SupermuxProjectDTO], presets: [SupermuxTerminalPresetDTO],
    isFromCache, supportsProjects: Bool?, runs: [SupermuxRunStateDTO], worktreesByProjectID: [UUID: [SupermuxWorktreeDTO]], lastError
    var device: SupermuxProjectDevice
    func project(id:), isRunning(projectID:), isRunning(remoteWorkspaceID:), isRunning(projectID: String, remoteWorkspaceID:)
}
```

Refresh triggers: `.linkConnected`, `supermux.projects.updated` / `supermux.run.updated` topics (full
refresh), `supermux.worktrees.updated` (worktree lists rows asked for), a device appearing online, and
a 120 s safety net. Only devices whose host advertises `supermux.projects.v1` are fetched. The offline
cache is `SupermuxPaths.remoteProjectsCacheFileURL` (`~/Library/Application Support/cmux/supermux-remote-projects.json`,
or next to `SUPERMUX_PROJECTS_FILE` in DEBUG runs), keyed by machine wire id; the loopback device is
never cached; nothing is ever written to `supermux-projects.json`.

## Nesting (`SupermuxUnifiedProjectsModel`, `SupermuxMirrorOwnership`)

- `unifiedProjects.list` is recomputed when local projects, their origins, the remote model or
  `devices.revision` change, and reassigned only when it differs.
- `unifiedProjects.mirrorOwners: [localMirrorWorkspaceID: unifiedProjectID]` — for each mirror
  (`deviceWorkspaceIndex.mirrors()`): record → `supermux_project_id` → `list.projectID(onMachine:remoteProjectID:)`.
- `SupermuxMirrorOwnership.current()` is what the sidebar reads. `SupermuxProjectResolutionCache`
  (`filter` / `projectId(forWorkspace:…ownership:)`) resolves a mirror ONLY through it — never through
  `SupermuxWorkspaceAssociationStore` / path matching. Project-owned mirrors are hidden from the flat
  list with all existing hidden-row plumbing; project-less mirrors stay flat. With no project on any
  Mac the filter returns early as before; remote-only projects keep it running.
- `SupermuxTabManagerOpener`'s reuse-by-directory skips device mirrors.

## Remote actions (`SupermuxRemoteProjectCommands`)

All take a `SupermuxProjectLocation`/`SupermuxRemoteWorktree` on a device and a window's `TabManager`,
do the RPC, then (when the Mac returned `workspace_id`) `deviceWorkspaceOpener.openWhenAvailable(…, focus:)`.
Every RPC that opens a workspace there (`project.open`, `worktree.open`, `worktree.create {open:true}`,
`agent.start`) carries `select: false`: the host's handlers pass it to `SupermuxOpenWorkspaceRequest.
selectsWorkspace`, so `SupermuxTabManagerOpener` neither selects a reused workspace nor a new one (which it
eager-loads so its command and setup script run). Without the param (the phone) the host selects as before.

```swift
func openProject(_ location, in:) async throws -> Opened                    // project.open
func openWorktree(_ worktree, in:) async throws -> Opened                   // worktree.open
func createWorktree(_ location, request:, in:, focus: = true) async throws -> Opened   // worktree.create {open:true}
func removeWorktree(_ worktree, deleteBranch:, force:) async throws        // dirty → throws; isDirtyWorktree(_:)
func runAction(_ location, action:, in:) async throws -> URL?              // open_url → caller opens locally; a command runs in the selected mirror's workspace on that Mac, else project.open's (action.run {workspace_id})
func removeProject(_ location) async throws                                // project.delete
func addExistingFolder(_ destination, path:) async throws -> String        // project.create / local addProject
func cloneRepository(_ destination, remoteURL:, path:) async throws -> String   // project.clone / local clone + addProject
```

Also `startAgent(_ location, request: SupermuxAgentLaunchRequest, in:, focus:)` (`agent.start`,
long deadline, same open tail) and the RPC-only halves `requestWorktreeCreate(_:request:)` /
`requestAgentStart(_:request:)` → `SupermuxRemoteWorkspaceRef`, which the New Worktree sheet uses
(see "New Worktree on any Mac" below).

## Host RPCs (capability `supermux.project_setup.v1`)

| Method | Params | Result / errors |
|---|---|---|
| `mobile.supermux.project.probe` | `root_path` (absolute) | `SupermuxProjectProbeDTO`: `{root_path, exists, is_directory, is_git_repo, git_remote_url?, is_suppressed}` (flat object) · `invalid_params` |
| `mobile.supermux.project.clone` | `remote_url`, `root_path` | `{project}` (like `project.create`) after `git clone --quiet -- <url> <root>` (15 min) + `addProject`; the target must not exist or be empty; parents are created · `invalid_params`, `destination_exists`, `clone_failed` |

Both are `.macWide` in `SupermuxMobileAuthorization`, routed in `TerminalController+SupermuxMobile.swift`.
Over a device link, clone gets its long reply deadline from `SupermuxDeviceReplyDeadline` (clone
timeout plus the git work around it); callers pass none.

## Project sync (`SupermuxProjectSyncCoordinator`, setting `supermux.devices.syncProjects`, default on)

On a link connect or any change of either side's project list/origins (signature-gated; re-runs at
most every 10 min otherwise), for each connected, non-loopback device serving projects:
- **push:** `SupermuxProjectSyncPlanner.candidates(source: local, destination: device)` →
  `project.probe` on the device → `shouldRegister` (exists, folder, git, SAME origin, not suppressed)
  → `project.create` → `project.update {patch: settingsPatch(…)}` (name, color, icon symbol, default
  branch, and run/setup/teardown/actions unless the destination repo's config owns them). Needs
  `supermux.project_setup.v1` on the device.
- **pull:** the reverse, probing locally and registering through `SupermuxProjectsModel.addProject`
  + `SupermuxMobileProjectPatch`.
- Never clones, never deletes. `SupermuxProjectsModel.onRemoveProject` records every user removal
  (desktop, phone or another Mac's `project.delete`) in `SupermuxProjectSyncSuppression`; `probe`
  reports it as `is_suppressed`, so neither side re-adds that root. The roots live in
  `supermux-project-sync-suppressed.json` next to the projects document (same cross-build flock), so
  a removal made in any build on this Mac holds in all of them; a project that vanishes from the
  shared projects file (another build removed it) is suppressed too. Only a registration on this Mac
  (`SupermuxProjectsModel.onAddProject`: desktop, phone, another Mac's `project.create`/`clone`)
  clears it — never a project another build re-added to the shared file.

## Sidebar (Mac)

- `SupermuxProjectsMount` passes `remote: SupermuxRemoteProjectsPresenter.presentation(for: tabManager)`
  to `SupermuxProjectsSectionView`: remote-only `rows` (after local projects) and
  `extrasByLocalProjectID` (device worktrees, "Set Up on <Mac>" targets, clone URL) plus the window's
  `SupermuxRemoteProjectActions` (built by `SupermuxRemoteProjectActionsFactory`: alerts, dirty-worktree
  confirm → force, remove-project confirm).
- Nested mirror rows come from `SupermuxMirrorRowSnapshot` (device; branch/PR/activity/run state
  from the remote record when the mirror has none; empty directory so a same-path local worktree row
  is not hidden). The mount builds every nested row through `SupermuxNestedWorkspaceRows` (shared
  with `supermux.devices.sidebar_rows`), which orders a project's rows with
  `SupermuxNestedWorkspaceOrder`: this Mac's workspaces first (tab order), then one group per Mac
  (device order, each in its own order); a nested drag reorders within its group.
- Nested rows (local or mirror) draw no `cmux set-status` pills and no `set-progress` bar, as on
  main: the amber working spinner is their only agent status (an "Idle" or "Running" line under the
  branch would duplicate it). Flat rows, local and mirror, keep their pills and progress. A mirror's
  VoiceOver label adds "on <Mac>".
- Which Mac a row lives on is the small Mac + cloud icon `SupermuxRemoteMacIcon` (`laptopcomputer`
  with a knocked-out `cloud.fill` badge; no name capsule), its tooltip and VoiceOver label "On <Mac>"
  (plus " — Connecting…" / " — Offline", when it is also dimmed). It sits immediately before the
  branch name: on a nested mirror row before its branch (before the title when the mirror has no
  branch, `SupermuxOpenWorkspace.deviceIconPlacement`), on a remote worktree row before its branch
  name. `SupermuxDeviceChip` is now a thin wrapper that draws this icon (the remote-only project
  header keeps it after its name: it has no branch).
- Row layout (`SupermuxOpenWorkspaceRowView`), as on main and the same for local and mirror rows:
  PR and run badges, the amber working spinner (6·scale, always visible, hover included), the unread
  badge, then the close button while hovered. Remote worktree rows: the PR badge, then the hover
  arrow.
- A mirror row's menu (nested and flat, #574) offers **Hide Here** and **Close on <Mac>…** (the
  mirror close prompt); a local row keeps Close Workspace.
- Local project rows: device worktrees (chips) in the disclosure (pill shows a bare chevron until they
  load), "Open on ▸" when several Macs have it, remote worktrees in "Worktrees ▸", "Set Up on <Mac>…".
  Edit/Reveal/Move stay local-only.
- Remote-only rows: Mac icon, run indicator, dimmed + "offline" tooltip while the Mac is offline;
  tap = Open on <Mac>; menu: New Worktree… (the device-aware sheet, P2), Worktrees ▸, Actions ▸, Set Up on <Mac>…
  (incl. This Mac), Remove from Projects on <Mac>….
- Flat rows (touchpoint #561): device mirrors always show the Mac icon (`SupermuxFlatRowDeviceChip`),
  first on the row's branch/directory line in every layout, or before the title when the row draws no
  such line (`SupermuxFlatRowDeviceChip.drawsOnBranchLine`), tinted with the row's secondary color.
  It looks its Mac up in the device facade by name (`SupermuxDeviceChipState.resolve`, SupermuxKit)
  and dims while that Mac is offline or connecting; an unknown name is never dimmed. The row's directory line drops upstream's "<Mac> · " prefix
  (`SupermuxDeviceMirrorSidebar.directoryCandidates`, #532); remote paths are never abbreviated.

## Socket introspection (`supermux.devices.*`, served by `SupermuxProjectsSocketCommands`)

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.unified_projects '{}'        # {projects, mirror_owners, nesting:{window_id, workspaces:[{workspace_id,title,is_device_mirror,machine,remote_workspace_id,project_id,project_name,in_flat_list}]}}
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.remote_projects '{"refresh":true}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.remote_worktrees '{"machine":"device:…","project_id":"<that Mac's id>"}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.remote_worktree_create '{"machine":"device:…","project_id":"…","workspace_name":"x","branch_name":"y","focus":false}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.projects_presentation '{}'   # what the window's Projects section receives
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.sidebar_rows '{}'           # {window_id, font_scale, projects:[{project_id, rows:[{workspace_id,title,device_name,branch,unread_count,accessibility_label,activity,device_icon:{style,symbol,badge_symbol,help,dimmed}|null,device_icon_placement:before_branch|before_title|null}]}], flat:[{workspace_id,title,is_mirror,device_label,subtitle_candidates,branch_directory_lines,activity,device_icon,device_icon_placement:branch_line|title_line|null}]} as drawn
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.project_sync '{}'            # run a sync pass now → report
```

All take an optional `window_id`. E2E: `CMUX_TAG=<tag> python3 tests/supermux/loopback_projects_e2e.py
--projects-file <scratch projects.json>` (launch the build with `SUPERMUX_DEBUG_LOOPBACK_DEVICE=1` and
`SUPERMUX_PROJECTS_FILE` set to that file; the suite edits it as another build would).

## New Worktree on any Mac (P2)

One sheet, `SupermuxNewWorktreeSheet`, for every entry point: a local row's hover ＋ and "New
Worktree…", "New Worktree on ▸ <Mac>" (local rows whose project is on several Macs), and a
remote-only row's "New Worktree…". P1's minimal `SupermuxRemoteNewWorktreeSheet` is gone.

```swift
// SupermuxKit
@MainActor protocol SupermuxWorktreeCreationTarget: AnyObject, Sendable {   // one Mac's copy
    var projectID: UUID { get }               // THAT Mac's project id
    var remoteDeviceName: String? { get }     // nil = This Mac
    var configuredDefaultBranch: String? { get }
    func loadBranches() async throws -> [String]
    func isAINamingConfigured() async -> Bool
    func isAIBranchNamingConfigured() async -> Bool
    func suggestBranchName(forWorkspaceName:) async -> String?
    func createWorktree(branchName:baseBranch:workspaceName:) async throws   // delivers + opens
    var supportsAgentLaunch: Bool { get }; var canEditAgentCommands: Bool { get }
    var initialAgentCommands: SupermuxAgentCommandList { get }
    func setAgentCommands(_:) -> SupermuxAgentCommandList; func rememberAgentCommand(_:)
    func agentOptions(for command: String, forceRefresh: Bool) async -> SupermuxAgentLaunchOptionsDTO
    func shellLinePreview(command:model:effort:prompt:) -> String?          // nil when not known here
    func startAgent(_ request: SupermuxAgentLaunchRequest, willCreateWorktree:) async throws
}
final class SupermuxLocalWorktreeCreationTarget     // This Mac: exactly the pre-P2 calls
@Observable final class SupermuxNewWorktreeSheetModel   // entries, selectEntry(id:), load(), submit(onFinished:)
struct SupermuxWorktreeDeviceEntry { id, deviceKey ("this-mac" | machine id), name, availability, action: .create(location) | .setUp(destination), canCreate }
enum SupermuxWorktreeDevicePlanner { entries(for:availability:setUpTargets:), showsPicker(_:), defaultEntryID(in:preferredDeviceKey:lastUsedDeviceKey:) }
struct SupermuxWorktreeLastDeviceStore                  // UserDefaults `supermux.newWorktree.lastDevice.v1`
enum SupermuxRemoteWorktreeFailure { message(code:hostMessage:deviceName:) }
extension SupermuxRemoteProjectsPresentation { newWorktreeContext(forLocal:), newWorktreeContext(forRemote:), newWorktreeSheetModel(context:preferredDeviceKey:localTarget:onSetUp:) }
// SupermuxRemoteProjectActions.makeWorktreeTarget (replaces createWorktree); presentation gains deviceAvailability + lastWorktreeDevices
// app target
final class SupermuxRemoteWorktreeCreationTarget   // over the device link, opens the mirror after a create
```

- **Picker rows**: This Mac first (when it has a copy), the other Macs in location order with a
  link-state dot (connecting / offline rows listed but disabled, with a hint), then "Set Up on…"
  rows for connected Macs lacking the project (`extras.setUpTargets` / `row.setUpTargets`; hands
  off to P1's setup sheet). Hidden when there is one row in total. Which Macs are listed is fixed
  when the sheet opens, but each row's link state is read live (`presentation.deviceAvailability`
  is a provider over the observable device list): a Mac that finishes connecting becomes
  selectable, one that drops is disabled (Create too, with its hint), and neither edge touches the
  selection or the typed input. The sheet reloads when the selected Mac becomes reachable
  (`loadKey`); a reload keeps the user's model / effort picks. A load the link drops under reads
  as that Mac being unreachable (`not_connected` sentence), never as the raw `CancellationError`.
- **Default**: the row menu's Mac, else the last Mac a worktree was created on for this unified
  project (recorded only after a successful create), else the first Mac that can create, else the
  first copy (an offline-only project still opens and explains why).
- **Switching Mac** keeps the prompt, workspace name and branch, resets the starting branch to that
  Mac's default, reloads its branches (`worktrees.list {include_branches: true}`) and Claude options
  (`agent.options {project_id, command?}`; another Mac's command list is adopted from its answer and
  is not editable here); results for the previous Mac are dropped.
- **Another Mac's create**: "Creating on <Mac>…" while `worktree.create {open: true}` /
  `agent.start` runs under its long reply deadline (Cancel disabled — the other Mac
  cannot be stopped); the sheet closes when it returns, then
  `deviceWorkspaceOpener.openWhenAvailable(ref, in: <clicking window>, focus: true)` opens (or reuses
  the auto-mirror's in-flight / existing) mirror and selects it; an open failure shows an alert.
  Errors become sentences naming the Mac (`SupermuxRemoteWorktreeFailure`). A link that drops after
  the request went out (a `CancellationError` from the reconnect, or `not_connected` after a
  connected send) is `outcome_unknown`: "The connection to <Mac> dropped while it was creating the
  worktree. Check its worktrees before trying again." — never a silent return to idle (which invited a
  duplicate) or the raw error text; that Mac's worktree list is refreshed (and again on reconnect).
  Only a cancelled flow cancels silently. A blank branch is AI-named by `worktree.suggest_branch`
  only when that Mac already reported `ai_naming_configured == true` (additive `agent.options`
  field); otherwise the other Mac names it inside `worktree.create`. The launch line is previewed
  for another Mac once `agent.options` names its shell (`shell_flavor`: `posix` / `fish`, additive),
  with the same `SupermuxAgentLaunchCommand.shellLine`; it is hidden before that and for a prompt
  long enough that Mac reads it from a file. Until that Mac's command list arrives, the Claude chips
  show "Loading commands from <Mac>…".

DEBUG socket drivers (`supermux.devices.new_worktree.*`, same model as the sheet):
`open {project_id, preferred_device?, window_id?}` → `{session_id, unified_project_id, entries,
selected_entry_id, shows_picker, target, branches, base_branch, commands, command, …}`,
`select {session_id, entry_id}`, `load {session_id}`, `state {session_id}`,
`fill {session_id, prompt?, workspace_name?, branch_name?, base_branch?, command?}`,
`submit {session_id, <fill fields>, await_open?, stop_link_after_seconds?}` →
state + `{finished, machine, remote_workspace_id, mirror}` (`stop_link_after_seconds` holds that Mac's
link down that long after the request went out), `close {session_id}`,
`last_device {project_id}`, `set_agent_commands {commands?, selected?}` → `{previous, previous_selected, …}`.
E2E: `CMUX_TAG=<tag> python3 tests/supermux/loopback_new_worktree_picker_e2e.py` (also in
`tests/supermux/run_all_loopback_e2e.sh`).

## Not covered / known limits

- Loopback shares one project list with "both Macs", so remote-only rows, push/pull sync and the
  offline cache are verified by package tests and code reading only; they need a real two-Mac run.
- Merged rows remove only the local copy ("Remove from Projects on <Mac>" is on remote-only rows).
- Remote-only projects on two different devices are not merged with each other.
