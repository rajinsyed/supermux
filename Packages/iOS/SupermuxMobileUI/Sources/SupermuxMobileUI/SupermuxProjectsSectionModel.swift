public import Foundation
import Observation
import SupermuxMobileCore
public import SupermuxMobileKit

/// Main-actor owner of the phone's Projects section state.
///
/// Lives at the shell list's scope (one `@State` instance per list) and owns
/// one ``SupermuxMobileProjectsStore`` per Mac connection: the section driver
/// (`supermuxProjectsSectionDriver`) calls ``runSession(client:hostCapabilities:)``
/// whenever the connection identity or capability snapshot changes, so stores
/// and capabilities are RECREATED per connection rather than mutated — the
/// capability snapshot inside a store never goes stale.
///
/// The section view renders from the value ``snapshot`` and reaches back only
/// through the closure ``actions`` bundle, keeping store references out of
/// the `List` subtree per the repo's snapshot-boundary rule.
@MainActor
@Observable
public final class SupermuxProjectsSectionModel {
    /// The live session's store; `nil` while disconnected. Exposed for the
    /// shell's own diagnostics/tests; views consume ``snapshot`` instead.
    public private(set) var store: SupermuxMobileProjectsStore?

    /// The live session's run store (run state + start/stop/launch/action
    /// calls); `nil` while disconnected. Runs alongside ``store`` in the
    /// same session task; views consume the row snapshots' `run` values and
    /// the ``actions`` bundle instead.
    public private(set) var runStore: SupermuxMobileRunStore?

    /// Local collapse toggle. `nil` follows the Mac's `section_collapsed`
    /// seed; a tap overrides it for this session (phone-local, read-only
    /// milestone — nothing is written back to the Mac).
    private var collapsedOverride: Bool?

    // The inline-nesting members below are internal (not private) because
    // the m6-f1 half of this model lives in
    // `SupermuxProjectsSectionModel+Nesting.swift` (file-length budget).

    /// Per-project inline-disclosure state (m6-f1, mac-sidebar-style
    /// nesting). Phone-local and UserDefaults-persisted by project id — NOT
    /// the Mac-shared `section_collapsed`, which stays the whole-section
    /// toggle above.
    var expandedProjectIDs: Set<String>

    /// Backing store for ``expandedProjectIDs`` (injectable so tests never
    /// touch the real defaults).
    @ObservationIgnored let expansionDefaults: UserDefaults
    static let expansionDefaultsKey = "supermux.projects.expandedProjectIDs"

    /// The project currently routed to the DETAIL screen (info accessory or
    /// long-press menu); `nil` while no detail is pushed. The section driver
    /// binds this to a `navigationDestination`.
    public internal(set) var detailProjectID: String?

    /// The routed project's row as last resolved from a LIVE snapshot —
    /// captured when the detail route opens. ``detailRow`` falls back to it
    /// only while the section snapshot is hidden/unloaded (session torn down
    /// or still reloading), so the pushed detail never flashes the
    /// "no longer available" placeholder unless the project genuinely
    /// disappeared from a loaded projects list.
    var detailFallbackRow: SupermuxProjectRowSnapshot?

    /// Error surface for a failed nested-worktree open (UI-03: visible,
    /// never silent). Cleared via ``dismissNestedOpenError()``.
    public internal(set) var nestedOpenErrorMessage: String?

    /// One expanded project's section-owned worktree session: the store plus
    /// the task running its event loop (fetch on expand, refetch on
    /// `supermux.worktrees.updated`).
    struct WorktreeSession {
        let store: SupermuxMobileWorktreesStore
        let task: Task<Void, Never>
    }

    /// Section-owned worktree sessions for the EXPANDED projects, by project
    /// id. Ignored by observation: every mutation co-occurs with an
    /// observable one (``expandedProjectIDs`` or ``store``), and the
    /// projection reads the stores' own `@Observable` state.
    @ObservationIgnored var worktreeSessions: [String: WorktreeSession] = [:]

    /// Monotonic session counter (bumped by every ``runSession`` install and
    /// ``endSession()``). In-flight nested-worktree opens capture it so a
    /// stale connection's late answer can never navigate the current shell
    /// or surface an obsolete error.
    @ObservationIgnored var sessionGeneration = 0

    /// Shared across sessions so custom icons survive a reconnect without a
    /// re-download (the etag round-trip answers `not_modified`).
    @ObservationIgnored private let iconCache = SupermuxProjectIconCache()

    /// The live session's client + capability snapshot, retained so worktrees
    /// stores can be minted against the SAME connection the projects store
    /// uses. Cleared with the session. Ignored by observation: connection
    /// identity carries no render state. Internal (not private) for the
    /// `+Nesting.swift` count-seeding extension.
    @ObservationIgnored var sessionClient: (any SupermuxMacCalling)?
    @ObservationIgnored var sessionCapabilities: SupermuxMobileCapabilities?

    /// UNOPENED-worktree counts per project id (the mac capsule's count),
    /// fed by expanded projects' worktrees stores after each successful
    /// fetch and seeded once per session for collapsed projects (the mac
    /// eagerly refreshes every project's worktrees at load, so its capsule
    /// shows without expanding — the phone mirrors that with one-shot
    /// fetches). Observable so a fresh count re-projects the section rows.
    /// Reset per session — counts never leak across Macs.
    private var worktreeCounts: [String: Int] = [:]

    /// Project ids whose one-shot count seed already ran this session, so a
    /// projects refetch doesn't re-fetch every collapsed project's worktrees.
    /// Internal (not private) for the `+Nesting.swift` seeding extension.
    @ObservationIgnored var seededWorktreeCountProjectIDs: Set<String> = []

    /// The open workspaces the shell last reported (project-associated only),
    /// joined onto project rows in ``snapshot``. Observable so a workspace
    /// change re-projects the section.
    private var workspaceRows: [SupermuxProjectWorkspaceRowSnapshot] = []

    /// The shell's workspace-open closure, refreshed with every
    /// ``updateWorkspaces(_:selectWorkspace:)`` so it always targets the live
    /// shell. Ignored by observation: closures carry no render state.
    /// Internal (not private) for the `+Nesting.swift` extension.
    @ObservationIgnored var selectWorkspaceAction: @MainActor (_ workspaceID: String) -> Void = { _ in }

    /// Creates an empty (hidden-section) model.
    /// - Parameter expansionDefaults: Where per-project expansion persists
    ///   (phone-local UI state). Defaults to the app's standard defaults;
    ///   tests inject an isolated suite.
    public init(expansionDefaults: UserDefaults = .standard) {
        self.expansionDefaults = expansionDefaults
        self.expandedProjectIDs = Set(
            expansionDefaults.stringArray(forKey: Self.expansionDefaultsKey) ?? []
        )
    }

    /// The section's current render value. Hidden unless a session is live
    /// AND the host advertises `supermux.projects.v1` (UI-02).
    public var snapshot: SupermuxProjectsSectionSnapshot {
        guard let store, store.showsProjectsSection else { return .hidden }
        return SupermuxProjectsSectionSnapshot(
            isVisible: true,
            isCollapsed: collapsedOverride ?? store.isSectionCollapsed,
            hasLoaded: store.hasLoaded,
            rows: store.projects.map { project in
                let isExpanded = expandedProjectIDs.contains(project.id)
                // The mac row's green play indicator: mark the nested
                // workspace hosting this project's active run command
                // (run.state's workspace_id), matched by Mac-local id.
                let runningWorkspaceID = runningWorkspaceID(forProjectID: project.id)
                return SupermuxProjectRowSnapshot(
                    project: project,
                    openWorkspaces: workspaceRows
                        .filter { $0.projectID == project.id }
                        .map { $0.runningMarked($0.hostsRunningWorkspace(runningWorkspaceID)) },
                    worktreeCount: worktreeCounts[project.id],
                    run: runState(for: project),
                    isExpanded: isExpanded,
                    nestedWorktrees: isExpanded ? nestedWorktrees(forProjectID: project.id) : .unavailable
                )
            },
            showsPresets: store.showsPresets,
            presets: store.showsPresets ? store.presets : [],
            showsActions: runStore?.showsActions ?? false
        )
    }

    /// The Mac-local id of the workspace hosting `projectID`'s active run
    /// command, or `nil` when nothing runs (or `supermux.run.v1` is absent).
    private func runningWorkspaceID(forProjectID projectID: String) -> String? {
        guard let runStore, runStore.showsRun,
              let row = runStore.run(forProjectID: projectID),
              row.isRunning == true else {
            return nil
        }
        return row.workspaceId
    }

    /// The run-store projection for one project row: `nil` (run UI hidden)
    /// without `supermux.run.v1` or when the project has no non-blank run
    /// command; otherwise the row's dot/control state, running only when
    /// `run.state` (or an applied start/stop answer) says so.
    private func runState(for project: SupermuxProjectDTO) -> SupermuxProjectRunState? {
        guard let runStore, runStore.showsRun else { return nil }
        let hasRunCommand = (project.runCommands ?? []).contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasRunCommand else { return nil }
        let row = runStore.run(forProjectID: project.id)
        let isRunning = row?.isRunning == true
        return SupermuxProjectRunState(
            isRunning: isRunning,
            command: isRunning ? row?.command : nil
        )
    }

    /// The closure bundle row-level views act through.
    public var actions: SupermuxProjectsSectionActions {
        SupermuxProjectsSectionActions(
            toggleCollapsed: { [weak self] in self?.toggleCollapsed() },
            iconPNGData: { [weak self] projectID in
                await self?.iconPNGData(forProjectID: projectID) ?? nil
            },
            selectWorkspace: { [weak self] workspaceID in
                self?.navigateToWorkspace(workspaceID)
            },
            makeWorktreesStore: { [weak self] projectID in
                self?.makeWorktreesStore(forProjectID: projectID)
            },
            editing: editingActions,
            run: runActions,
            toggleProjectExpanded: { [weak self] projectID in
                self?.toggleProjectExpanded(projectID)
            },
            openProjectDetail: { [weak self] projectID in
                self?.openProjectDetail(projectID)
            },
            openNestedWorktree: { [weak self] projectID, worktree in
                self?.openNestedWorktree(projectID: projectID, worktree: worktree)
            }
        )
    }

    /// The run/launch/action seam, routing through the live session's run
    /// store; `nil` while disconnected (every run affordance hides). The
    /// closures resolve the store at CALL time (weak self), so a detail
    /// screen outliving a reconnect reaches the fresh session — or, with no
    /// session, gets `SupermuxMacUnavailableError` to display.
    private var runActions: SupermuxProjectRunActions? {
        guard runStore != nil else { return nil }
        return SupermuxProjectRunActions(
            startRun: { [weak self] projectID, commandID in
                try await Self.requireRunStore(self).startRun(projectID: projectID, commandID: commandID)
            },
            stopRun: { [weak self] projectID in
                try await Self.requireRunStore(self).stopRun(projectID: projectID)
            },
            launchPreset: { [weak self] presetID, projectID in
                try await Self.requireRunStore(self).launchPreset(presetID: presetID, projectID: projectID)
            },
            runAction: { [weak self] projectID, actionID in
                try await Self.requireRunStore(self).runAction(projectID: projectID, actionID: actionID)
            }
        )
    }

    /// The live session's run store, or `SupermuxMacUnavailableError` when
    /// the session ended (e.g. a screen outlived a disconnect).
    private static func requireRunStore(
        _ model: SupermuxProjectsSectionModel?
    ) throws -> SupermuxMobileRunStore {
        guard let runStore = model?.runStore else { throw SupermuxMacUnavailableError() }
        return runStore
    }

    /// Builds a worktrees store for one project against the live session's
    /// client and capability snapshot. `nil` while disconnected or when the
    /// host lacks `supermux.worktrees.v1` (the capability gate — a fork phone
    /// against an upstream Mac shows no worktree UI). The store feeds the
    /// project row's worktree-count badge after each successful fetch.
    /// - Parameter projectID: The project's UUID string.
    public func makeWorktreesStore(forProjectID projectID: String) -> SupermuxMobileWorktreesStore? {
        guard let sessionClient, let sessionCapabilities,
              sessionCapabilities.supportsWorktrees else {
            return nil
        }
        return SupermuxMobileWorktreesStore(
            client: sessionClient,
            capabilities: sessionCapabilities,
            projectID: projectID,
            onWorktreesChanged: { [weak self] projectID, worktrees in
                self?.recordWorktrees(worktrees, forProjectID: projectID)
            }
        )
    }

    /// Records a project's fresh worktree list as the row badge's UNOPENED
    /// count (the mac capsule counts only worktrees without an open
    /// workspace). Internal (not private) for the `+Nesting.swift` seeding
    /// extension.
    func recordWorktrees(_ worktrees: [SupermuxWorktreeDTO], forProjectID projectID: String) {
        let count = SupermuxWorktreeRowSnapshot.unopenedRows(from: worktrees).count
        if worktreeCounts[projectID] != count {
            worktreeCounts[projectID] = count
        }
    }

    /// Feeds the shell's current workspace list (already mapped to
    /// project-associated row snapshots) and its open-workspace closure into
    /// the section. Called from the driver's `.task(id:)` whenever the shell's
    /// workspace previews change — never from a view body.
    ///
    /// - Parameters:
    ///   - rows: The project-associated workspace rows, in shell order.
    ///   - selectWorkspace: Opens a workspace by its UI row id (the same
    ///     navigation the flat list's rows use).
    public func updateWorkspaces(
        _ rows: [SupermuxProjectWorkspaceRowSnapshot],
        selectWorkspace: @escaping @MainActor (_ workspaceID: String) -> Void
    ) {
        selectWorkspaceAction = selectWorkspace
        if workspaceRows != rows {
            workspaceRows = rows
        }
    }

    /// Toggles the section's collapse state: the local override flips
    /// immediately (responsive header), and the new state persists Mac-side
    /// through `mobile.supermux.projects.set_section_collapsed` — the same
    /// shared state the desktop header mutates. A failed write leaves the
    /// session-local override in place (pre-write behavior) and surfaces on
    /// the store's error state.
    public func toggleCollapsed() {
        guard let store, store.showsProjectsSection else { return }
        let collapsed = !(collapsedOverride ?? store.isSectionCollapsed)
        collapsedOverride = collapsed
        Task { await store.setSectionCollapsed(collapsed) }
    }

    /// Fetches a project's custom icon PNG through the session store's etag
    /// cache. `nil` when disconnected, the project is unknown, or it has no
    /// custom icon.
    /// - Parameter projectID: The project's UUID string.
    public func iconPNGData(forProjectID projectID: String) async -> Data? {
        guard let store, let project = store.projects.first(where: { $0.id == projectID }) else {
            return nil
        }
        return await store.iconPNGData(for: project)
    }

    /// Runs one connection's session: builds a fresh store from the given
    /// client and capability snapshot, publishes it, and follows the live
    /// event stream until the caller (the driver's `.task(id:)`) is
    /// cancelled. Against a host without `supermux.projects.v1` the store is
    /// inert (no RPC is ever issued) and the section stays hidden.
    ///
    /// - Parameters:
    ///   - client: The Mac RPC seam for THIS connection.
    ///   - hostCapabilities: The host's raw advertised capability strings.
    public func runSession(
        client: any SupermuxMacCalling,
        hostCapabilities: Set<String>
    ) async {
        collapsedOverride = nil
        // A replacement session must never inherit the old connection's
        // worktree sessions (stale client) — end them before installing the
        // new client, then reseed below. The generation bump invalidates the
        // old session's in-flight work (nested opens, prune callbacks).
        endAllWorktreeSessions()
        sessionGeneration += 1
        let generation = sessionGeneration
        let capabilities = SupermuxMobileCapabilities(hostCapabilities: hostCapabilities)
        let store = SupermuxMobileProjectsStore(
            client: client,
            capabilities: capabilities,
            iconCache: iconCache,
            // The authoritative list prunes worktree sessions whose project
            // was deleted (their rows are gone, so they could never be
            // collapsed away — without this they would refetch forever).
            // Generation-guarded: a lingering OLD store (kept alive by an
            // in-flight write's refetch across a reconnect) must never prune
            // the NEW session with the old Mac's project ids.
            onProjectsChanged: { [weak self] projects in
                guard let self, self.sessionGeneration == generation else { return }
                self.pruneWorktreeSessions(keepingProjectIDs: projects.map(\.id))
                // Mirror the mac's eager per-project worktree refresh at
                // load: collapsed projects get a one-shot count fetch so the
                // worktree capsule shows without expanding.
                self.seedWorktreeCounts(
                    forProjectIDs: projects.map(\.id),
                    generation: generation
                )
            }
        )
        let runStore = SupermuxMobileRunStore(client: client, capabilities: capabilities)
        self.store = store
        self.runStore = runStore
        sessionClient = client
        sessionCapabilities = capabilities
        worktreeCounts = [:]
        seededWorktreeCountProjectIDs = []
        // Resume the phone-persisted inline disclosures against THIS
        // connection: each expanded project fetches on session start and
        // refetches on `supermux.worktrees.updated` (the store's own loop).
        for projectID in expandedProjectIDs {
            startWorktreeSession(forProjectID: projectID)
        }
        defer {
            // Only the still-current session clears itself; a replacement
            // session that already installed its store must not be torn down
            // by the old session's exit.
            //
            // With a project DETAIL pushed, the cancellation is (in every
            // reachable case) the navigationDestination push covering the
            // list — NavigationStack removes the root from the hierarchy, so
            // SwiftUI cancels the driver's structured `.task`. Tearing down
            // here would blank `detailRow` and swap the just-pushed detail
            // for the "no longer available" placeholder (the m6-f1 field
            // bug). Instead the session stays installed — the connection is
            // still alive, so detail actions keep working; only the event
            // loops pause — and the next `runSession` (the list reappears on
            // pop, or the connection key changes) replaces it wholesale.
            if self.store === store, detailProjectID == nil {
                self.store = nil
                self.runStore = nil
                sessionClient = nil
                sessionCapabilities = nil
                endAllWorktreeSessions()
                // Natural teardown (the driver's `.task` was cancelled with
                // no replacement, e.g. the list left the screen) must also
                // invalidate in-flight nested opens — nothing else would.
                sessionGeneration += 1
            }
        }
        // Both loops share the session's structured lifetime: cancelling the
        // driver's `.task(id:)` cancels the group, which cancels both.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.run() }
            group.addTask { await runStore.run() }
        }
    }

    /// Drops the session immediately (connection went away). Expansion
    /// state itself persists — a reconnect reseeds the worktree sessions.
    public func endSession() {
        store = nil
        runStore = nil
        sessionClient = nil
        sessionCapabilities = nil
        worktreeCounts = [:]
        seededWorktreeCountProjectIDs = []
        collapsedOverride = nil
        endAllWorktreeSessions()
        sessionGeneration += 1
        // detailProjectID / detailFallbackRow survive on purpose: a pushed
        // detail outliving a disconnect keeps rendering its last-known row
        // instead of flashing "no longer available".
    }
}
