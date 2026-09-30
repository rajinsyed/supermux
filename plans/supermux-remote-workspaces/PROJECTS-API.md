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
SupermuxComposition.projectSyncSuppression  // SupermuxProjectSyncSuppression (roots a user removed)
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

```swift
private(set) var devices: [SupermuxDeviceProjects]   // device order; offline ones keep cached projects
private(set) var icons: [String: NSImage]            // key: projectKey(machine:projectID:)
func device(_ machine: SurfaceMachineID) -> SupermuxDeviceProjects?
func icon(machine:projectID:) -> NSImage?
func refresh(_ machine) async                         // projects.list + run.state + icons + wanted worktrees; coalesced
func refreshAll()
func ensureWorktrees(on machine, projectID:)          // lazy first load (rows call it on expand)
func refreshWorktrees(on machine, projectID:) async   // worktrees.list {include_branches: false}

struct SupermuxDeviceProjects {                       // ids are that Mac's ids
    machine, name, isOnline, isLoopback, projects: [SupermuxProjectDTO], isFromCache,
    supportsProjects: Bool?, runs: [SupermuxRunStateDTO], worktreesByProjectID: [UUID: [SupermuxWorktreeDTO]], lastError
    var device: SupermuxProjectDevice
    func project(id:), isRunning(projectID:), isRunning(remoteWorkspaceID:)
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

```swift
func openProject(_ location, in:) async throws -> Opened                    // project.open
func openWorktree(_ worktree, in:) async throws -> Opened                   // worktree.open
func createWorktree(_ location, request:, in:, focus: = true) async throws -> Opened   // worktree.create {open:true}, longOperationTimeout
func removeWorktree(_ worktree, deleteBranch:, force:) async throws        // dirty → throws; isDirtyWorktree(_:)
func runAction(_ location, actionID:) async throws -> URL?                 // open_url → caller opens locally
func removeProject(_ location) async throws                                // project.delete
func addExistingFolder(_ destination, path:) async throws -> String        // project.create / local addProject
func cloneRepository(_ destination, remoteURL:, path:) async throws -> String   // project.clone / local clone + addProject
```

**P2 (device picker in the New Worktree sheet):** list the candidate Macs with
`unifiedProjects.list.project(forLocalProject:)?.locations` (online ones), and create remotely with
`SupermuxRemoteProjectCommands.shared.createWorktree(location, request:, in: tabManager)` — that is
what the minimal remote sheet (`SupermuxRemoteNewWorktreeSheet`, shown for remote-only projects)
calls today. Replace the sheet, keep the command. For `agent.start`, add a sibling command with the
same `openReturnedWorkspace` tail.

## Host RPCs (capability `supermux.project_setup.v1`)

| Method | Params | Result / errors |
|---|---|---|
| `mobile.supermux.project.probe` | `root_path` (absolute) | `SupermuxProjectProbeDTO`: `{root_path, exists, is_directory, is_git_repo, git_remote_url?, is_suppressed}` (flat object) · `invalid_params` |
| `mobile.supermux.project.clone` | `remote_url`, `root_path` | `{project}` (like `project.create`) after `git clone --quiet -- <url> <root>` (15 min) + `addProject`; the target must not exist or be empty; parents are created · `invalid_params`, `destination_exists`, `clone_failed` |

Both are `.macWide` in `SupermuxMobileAuthorization`, routed in `TerminalController+SupermuxMobile.swift`.
Callers over a device link should pass `SupermuxRemoteProjectCommands.cloneTimeout` for clone.

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
  reports it as `is_suppressed`, so neither side re-adds that root. Re-adding the folder by hand
  clears it.

## Sidebar (Mac)

- `SupermuxProjectsMount` passes `remote: SupermuxRemoteProjectsPresenter.presentation(for: tabManager)`
  to `SupermuxProjectsSectionView`: remote-only `rows` (after local projects) and
  `extrasByLocalProjectID` (device worktrees, "Set Up on <Mac>" targets, clone URL) plus the window's
  `SupermuxRemoteProjectActions` (built by `SupermuxRemoteProjectActionsFactory`: alerts, dirty-worktree
  confirm → force, remove-project confirm).
- Nested mirror rows come from `SupermuxMirrorRowSnapshot` (device chip; branch/PR/activity/run state
  from the remote record when the mirror has none; empty directory so a same-path local worktree row
  is not hidden).
- Local project rows: device worktrees (chips) in the disclosure (pill shows a bare chevron until they
  load), "Open on ▸" when several Macs have it, remote worktrees in "Worktrees ▸", "Set Up on <Mac>…".
  Edit/Reveal/Move stay local-only.
- Remote-only rows: device chip, run indicator, dimmed + "offline" tooltip while the Mac is offline;
  tap = Open on <Mac>; menu: New Worktree… (minimal sheet), Worktrees ▸, Actions ▸, Set Up on <Mac>…
  (incl. This Mac), Remove from Projects on <Mac>….
- Flat rows (touchpoint #561): device mirrors always show `SupermuxFlatRowDeviceChip`.

## Socket introspection (`supermux.devices.*`, served by `SupermuxProjectsSocketCommands`)

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.unified_projects '{}'        # {projects, mirror_owners, nesting:{window_id, workspaces:[{workspace_id,title,is_device_mirror,machine,remote_workspace_id,project_id,project_name,in_flat_list}]}}
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.remote_projects '{"refresh":true}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.remote_worktrees '{"machine":"device:…","project_id":"<that Mac's id>"}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.remote_worktree_create '{"machine":"device:…","project_id":"…","workspace_name":"x","branch_name":"y","focus":false}'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.projects_presentation '{}'   # what the window's Projects section receives
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc supermux.devices.project_sync '{}'            # run a sync pass now → report
```

All take an optional `window_id`. E2E: `CMUX_TAG=<tag> python3 tests/supermux/loopback_projects_e2e.py`
(launch the build with `SUPERMUX_DEBUG_LOOPBACK_DEVICE=1` and a scratch `SUPERMUX_PROJECTS_FILE`).

## Not covered / known limits

- Loopback shares one project list with "both Macs", so remote-only rows, push/pull sync and the
  offline cache are verified by package tests and code reading only; they need a real two-Mac run.
- Merged rows remove only the local copy ("Remove from Projects on <Mac>" is on remote-only rows).
- Remote-only projects on two different devices are not merged with each other.
