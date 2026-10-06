public import Foundation
import Observation
public import SupermuxMobileCore
public import SupermuxMobileKit

/// Main-actor owner of the phone's Projects section state.
///
/// Lives at the shell list's scope (one `@State` instance per list) and owns
/// one ``SupermuxMacProjectsSession`` per connected Mac that serves
/// `supermux.projects.v1`: the section driver runs every Mac's session, so
/// the section shows the projects of EVERY connected Mac — grouped under a
/// per-Mac header once more than one Mac has projects — and a Mac's session
/// survives another Mac becoming the foreground.
///
/// Project ids are only unique on their own Mac, so everything the section
/// keys by project uses the row id (``SupermuxProjectKey/rawValue``: owning
/// pairing + project id). The public API's `projectID` parameters take that
/// row id; a single legacy session (no pairing) keeps plain project ids.
///
/// The section view renders from the value ``snapshot`` and reaches back only
/// through the closure ``actions`` bundle, keeping store references out of
/// the `List` subtree per the repo's snapshot-boundary rule.
@MainActor
@Observable
public final class SupermuxProjectsSectionModel {
    /// One session per Mac pairing, keyed by pairing id.
    var sessions: [String: SupermuxMacProjectsSession] = [:]

    /// Display order of the connected Macs (foreground first), from the shell.
    var macOrder: [String] = []

    /// Local collapse toggle. `nil` follows the lead Mac's `section_collapsed`.
    var collapsedOverride: Bool?

    /// The one list row whose swipe tray is open. Shared by every cell of the
    /// iPhone's list, so opening one tray closes the others, as in any
    /// native list.
    var openSwipeRowID: String?

    /// Open inline disclosures, by project ROW id (legacy entries may be
    /// plain project ids, which apply on every Mac). UserDefaults-persisted.
    var expandedProjectIDs: Set<String>

    /// The user's last open/closed choice for each merged project, by its
    /// merged key (``SupermuxMergedProject/id``). Every copy follows it, so
    /// a Mac whose copy loads late neither reopens a project the user closed
    /// nor stays closed inside one they opened. UserDefaults-persisted.
    var mergedDisclosure: [String: Bool]

    /// Backing store for ``expandedProjectIDs`` and ``mergedDisclosure``
    /// (injectable for tests).
    @ObservationIgnored let expansionDefaults: UserDefaults
    static let expansionDefaultsKey = "supermux.projects.expandedProjectIDs"
    static let mergedDisclosureDefaultsKey = "supermux.projects.mergedDisclosure"

    /// The project ROW routed to the detail screen; `nil` while none is.
    public internal(set) var detailProjectID: String?

    /// The routed row as last resolved from a LIVE snapshot, shown while the
    /// owning Mac's list is unloaded (see ``detailRow``).
    var detailFallbackRow: SupermuxProjectRowSnapshot?

    /// Error surface for a failed open or a navigation that never landed
    /// (UI-03: visible, never silent).
    public internal(set) var nestedOpenErrorMessage: String?

    /// The worktree a sidebar swipe asked to remove, while its first
    /// confirmation is on screen. Its `projectID` is the project ROW id.
    public internal(set) var pendingWorktreeRemoval: SupermuxPendingWorktreeRemoval?

    /// The presented New Worktree sheet's payload, or `nil`.
    var newWorktreePresentation: SupermuxNewWorktreePresentation?

    /// The project ROW whose New Worktree request is fetching its branches.
    public internal(set) var preparingNewWorktreeProjectID: String?

    /// Error surface for a failed New Worktree preparation.
    public internal(set) var newWorktreeErrorMessage: String?

    /// The Mac whose preparation raised ``newWorktreeErrorMessage``, so only
    /// that Mac's session ending drops the alert.
    @ObservationIgnored var newWorktreeErrorPairingID: String?

    /// The project ROW of the most recent removal request, so the force and
    /// failure prompts speak for the worktree the user actually swiped.
    var lastRemovalRequestProjectID: String?

    /// Monotonic token for workspace-opening requests: a slow answer only
    /// navigates if no newer open was requested since.
    @ObservationIgnored var nestedOpenRequestToken = 0

    /// Shared across sessions so custom icons survive a reconnect.
    @ObservationIgnored let iconCache = SupermuxProjectIconCache()

    /// Stamps for every session's generation/epoch, never reused.
    @ObservationIgnored let counter = SupermuxSessionCounter()

    /// Resolves Mac-local workspace ids to the shell's rows, parking until a
    /// fresh workspace's row arrives.
    @ObservationIgnored let navigator: SupermuxWorkspaceNavigator

    /// The open workspaces the shell last reported (project-associated only).
    private var workspaceRows: [SupermuxProjectWorkspaceRowSnapshot] = []

    /// The route the phone's session to each Mac uses, by pairing id (from
    /// `SupermuxPhoneRouteModel`, through the driver).
    private var routesByPairingID: [String: SupermuxLinkRoute] = [:]

    /// The shell's workspace-open closure, by ROW id.
    @ObservationIgnored var selectWorkspaceAction: @MainActor (_ workspaceID: String) -> Void = { _ in }

    /// The shell's workspace-CLOSE closure, or `nil` when unsupported.
    @ObservationIgnored var closeWorkspaceAction: (@MainActor (_ workspaceID: String) -> Void)?

    /// Creates an empty (hidden-section) model.
    /// - Parameters:
    ///   - expansionDefaults: Where per-project expansion persists.
    ///   - navigationTimeout: How long a navigation waits for a freshly
    ///     created workspace's row before reporting it.
    public init(expansionDefaults: UserDefaults = .standard, navigationTimeout: Duration = .seconds(20)) {
        self.expansionDefaults = expansionDefaults
        self.expandedProjectIDs = Set(expansionDefaults.stringArray(forKey: Self.expansionDefaultsKey) ?? [])
        self.mergedDisclosure = expansionDefaults.dictionary(forKey: Self.mergedDisclosureDefaultsKey) as? [String: Bool] ?? [:]
        self.navigator = SupermuxWorkspaceNavigator(timeout: navigationTimeout)
        navigator.select = { [weak self] rowID in
            self?.navigateToWorkspace(rowID)
        }
        navigator.onTimeout = { [weak self] _ in
            self?.nestedOpenErrorMessage = String(
                localized: "supermux.navigation.workspaceNotListed",
                defaultValue: "The workspace opened on your Mac but hasn’t appeared on this iPhone yet. Try again in a moment.",
                bundle: .module
            )
        }
    }

    // MARK: Sessions

    /// The session serving a pairing, if any.
    func session(forPairingID pairingID: String) -> SupermuxMacProjectsSession? {
        sessions[pairingID]
    }

    /// Every session in display order: the shell's Mac order, then any
    /// session it did not list (the single legacy session).
    var orderedSessions: [SupermuxMacProjectsSession] {
        let listed = macOrder.compactMap { sessions[$0] }
        let unlisted = sessions.values
            .filter { !macOrder.contains($0.pairingID) }
            .sorted { $0.pairingID < $1.pairingID }
        return listed + unlisted
    }

    /// The lead session (foreground Mac first): the one section-wide
    /// affordances (collapse seed, Add Project) act on.
    var primarySession: SupermuxMacProjectsSession? {
        orderedSessions.first { $0.store?.showsProjectsSection == true } ?? orderedSessions.first
    }

    /// The session and Mac-local project id behind a project row id. A bare
    /// project id (a caller predating per-Mac keys) resolves to the Mac that
    /// lists it.
    func resolve(_ rowID: String) -> (session: SupermuxMacProjectsSession, projectID: String)? {
        let key = SupermuxProjectKey(rawValue: rowID)
        if let session = sessions[key.pairingID] {
            return (session, key.projectID)
        }
        guard key.pairingID.isEmpty else { return nil }
        let owner = orderedSessions.first { session in
            session.store?.projects.contains { $0.id == key.projectID } == true
        } ?? primarySession
        return owner.map { ($0, key.projectID) }
    }

    /// The lead session's projects store (diagnostics and tests).
    public var store: SupermuxMobileProjectsStore? { primarySession?.store }
    /// The lead session's run store (diagnostics and tests).
    public var runStore: SupermuxMobileRunStore? { primarySession?.runStore }
    /// The lead session's worktree sessions (tests).
    var worktreeSessions: [String: SupermuxMacProjectsSession.WorktreeSession] {
        primarySession?.worktreeSessions ?? [:]
    }
    /// The lead session's generation stamp (tests).
    var sessionGeneration: Int { primarySession?.generation ?? counter.value }
    /// The lead session's epoch: moves when its connection is replaced or ends.
    public var sessionEpoch: Int { primarySession?.epoch ?? counter.value }

    // MARK: Snapshot

    /// The section's current render value. Hidden unless some Mac's session
    /// is live AND advertises `supermux.projects.v1` (UI-02).
    public var snapshot: SupermuxProjectsSectionSnapshot {
        let groups = orderedSessions.compactMap(groupSnapshot(for:))
        guard !groups.isEmpty else { return .hidden }
        let lead = primarySession?.store?.isSectionCollapsed ?? false
        return SupermuxProjectsSectionSnapshot(isCollapsed: collapsedOverride ?? lead, groups: groups)
    }

    private func groupSnapshot(for session: SupermuxMacProjectsSession) -> SupermuxProjectsMacGroupSnapshot? {
        guard let store = session.store, store.showsProjectsSection else { return nil }
        let rows = store.projects.map { project in
            let key = SupermuxProjectKey(pairingID: session.pairingID, projectID: project.id)
            let isExpanded = isExpanded(key)
            // The mac row's green play indicator, matched by Mac-local id.
            let runningWorkspaceID = session.runningWorkspaceID(forProjectID: project.id)
            return SupermuxProjectRowSnapshot(
                project: project,
                openWorkspaces: workspaceRows
                    .filter { $0.projectID == project.id && $0.belongs(toPairingID: session.pairingID) }
                    .map { $0.runningMarked($0.hostsRunningWorkspace(runningWorkspaceID)) },
                worktreeCount: session.worktreeCounts[project.id],
                iconETag: project.iconETag,
                run: session.runState(for: project),
                isExpanded: isExpanded,
                nestedWorktrees: isExpanded ? session.nestedWorktrees(forProjectID: project.id) : .unavailable,
                pairingID: session.pairingID
            )
        }
        return SupermuxProjectsMacGroupSnapshot(
            header: SupermuxProjectsMacHeader(mac: session.mac, route: routesByPairingID[session.pairingID]),
            hasLoaded: store.hasLoaded,
            rows: rows,
            showsPresets: store.showsPresets,
            presets: store.showsPresets ? store.presets : [],
            showsActions: session.runStore?.showsActions ?? false,
            showsWorktreeCreation: session.capabilities?.supportsWorktrees ?? false
        )
    }

    // MARK: Routes

    /// Feeds each Mac's route into the section's headers. Called from the
    /// driver's event handlers, never a view body.
    /// - Parameter routes: The routes by pairing id.
    public func updateRoutes(_ routes: [String: SupermuxLinkRoute]) {
        guard routes != routesByPairingID else { return }
        routesByPairingID = routes
    }

    // MARK: Workspaces

    /// Feeds the shell's current workspace rows and its closures into the
    /// section. Called from the driver's event handlers, never a view body.
    /// - Parameters:
    ///   - rows: The project-associated workspace rows, in shell order.
    ///   - selectWorkspace: Opens a workspace by its UI ROW id.
    ///   - closeWorkspace: Closes a workspace through the shell's own close
    ///     path, or `nil` when unsupported.
    ///   - resolveWorkspace: Maps a Mac-local workspace id to the owning
    ///     Mac's row id, or `nil` while not listed. Without one (single-Mac
    ///     callers) Mac-local ids are selected as-is.
    public func updateWorkspaces(
        _ rows: [SupermuxProjectWorkspaceRowSnapshot],
        selectWorkspace: @escaping @MainActor (_ workspaceID: String) -> Void,
        closeWorkspace: (@MainActor (_ workspaceID: String) -> Void)? = nil,
        resolveWorkspace: SupermuxWorkspaceResolver? = nil
    ) {
        selectWorkspaceAction = selectWorkspace
        closeWorkspaceAction = closeWorkspace
        navigator.resolve = resolveWorkspace
        if workspaceRows != rows {
            workspaceRows = rows
        }
        navigator.retryPending()
    }

    /// The shell's workspace list changed: a parked navigation may now land.
    public func workspaceListDidChange() {
        navigator.retryPending()
    }

    /// The shell's selection changed: a choice made anywhere else drops a
    /// navigation still parked for a slow create.
    /// - Parameter workspaceID: The selected ROW id, or `nil` when cleared.
    public func shellSelectionDidChange(to workspaceID: String?) {
        navigator.shellSelectionDidChange(to: workspaceID)
    }

    // MARK: Section-wide

    /// Toggles the section's collapse state locally at once and persists it
    /// on every connected Mac (the Macs share the desktop header's state).
    public func toggleCollapsed() {
        let visible = orderedSessions.compactMap { session -> SupermuxMobileProjectsStore? in
            guard let store = session.store, store.showsProjectsSection else { return nil }
            return store
        }
        guard let lead = visible.first else { return }
        openSwipeRowID = nil
        let collapsed = !(collapsedOverride ?? lead.isSectionCollapsed)
        collapsedOverride = collapsed
        for store in visible {
            Task { await store.setSectionCollapsed(collapsed) }
        }
    }

    /// Closes the open swipe tray when its row is no longer listed (a search,
    /// a filter, a collapse, a Mac leaving, a worktree opened or removed).
    /// A worktree row is keyed by its path, so without this a worktree
    /// recreated at the same path would come back with Remove revealed.
    /// - Parameter ids: The swipe-tray ids of the rows on screen.
    public func closeSwipeTray(unlessAmong ids: Set<String>) {
        if let open = openSwipeRowID, !ids.contains(open) {
            openSwipeRowID = nil
        }
    }

    /// Fetches a project's custom icon PNG through its Mac's session.
    /// - Parameter projectID: The project ROW id.
    public func iconPNGData(forProjectID projectID: String) async -> Data? {
        guard let resolved = resolve(projectID) else { return nil }
        return await resolved.session.iconPNGData(forProjectID: resolved.projectID)
    }

    /// Builds a worktrees store for one project on its own Mac, or `nil`
    /// while disconnected or without `supermux.worktrees.v1`.
    /// - Parameter projectID: The project ROW id.
    public func makeWorktreesStore(forProjectID projectID: String) -> SupermuxMobileWorktreesStore? {
        guard let resolved = resolve(projectID) else { return nil }
        return resolved.session.makeWorktreesStore(forProjectID: resolved.projectID)
    }
}
