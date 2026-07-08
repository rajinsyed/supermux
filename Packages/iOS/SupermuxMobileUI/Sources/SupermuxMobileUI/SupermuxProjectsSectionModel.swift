public import Foundation
import Observation
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

    /// Local collapse toggle. `nil` follows the Mac's `section_collapsed`
    /// seed; a tap overrides it for this session (phone-local, read-only
    /// milestone — nothing is written back to the Mac).
    private var collapsedOverride: Bool?

    /// Shared across sessions so custom icons survive a reconnect without a
    /// re-download (the etag round-trip answers `not_modified`).
    @ObservationIgnored private let iconCache = SupermuxProjectIconCache()

    /// The open workspaces the shell last reported (project-associated only),
    /// joined onto project rows in ``snapshot``. Observable so a workspace
    /// change re-projects the section.
    private var workspaceRows: [SupermuxProjectWorkspaceRowSnapshot] = []

    /// The shell's workspace-open closure, refreshed with every
    /// ``updateWorkspaces(_:selectWorkspace:)`` so it always targets the live
    /// shell. Ignored by observation: closures carry no render state.
    @ObservationIgnored private var selectWorkspaceAction: @MainActor (_ workspaceID: String) -> Void = { _ in }

    /// Creates an empty (hidden-section) model.
    public init() {}

    /// The section's current render value. Hidden unless a session is live
    /// AND the host advertises `supermux.projects.v1` (UI-02).
    public var snapshot: SupermuxProjectsSectionSnapshot {
        guard let store, store.showsProjectsSection else { return .hidden }
        return SupermuxProjectsSectionSnapshot(
            isVisible: true,
            isCollapsed: collapsedOverride ?? store.isSectionCollapsed,
            hasLoaded: store.hasLoaded,
            rows: store.projects.map { project in
                SupermuxProjectRowSnapshot(
                    project: project,
                    openWorkspaces: workspaceRows.filter { $0.projectID == project.id }
                )
            }
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
                self?.selectWorkspaceAction(workspaceID)
            }
        )
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

    /// Toggles the section's collapse state locally.
    public func toggleCollapsed() {
        guard let store, store.showsProjectsSection else { return }
        collapsedOverride = !(collapsedOverride ?? store.isSectionCollapsed)
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
        let store = SupermuxMobileProjectsStore(
            client: client,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: hostCapabilities),
            iconCache: iconCache
        )
        self.store = store
        defer {
            // Only the still-current session clears itself; a replacement
            // session that already installed its store must not be torn down
            // by the old session's exit.
            if self.store === store {
                self.store = nil
            }
        }
        await store.run()
    }

    /// Drops the session immediately (connection went away).
    public func endSession() {
        store = nil
        collapsedOverride = nil
    }
}
