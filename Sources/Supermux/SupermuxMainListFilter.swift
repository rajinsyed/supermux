import Foundation
import SupermuxKit

/// Filters which workspaces cmux's flat sidebar list should render, and hands
/// out the per-window resolution cache behind it.
///
/// Workspaces that belong to a registered project are shown nested under that
/// project in the Projects section (piggycode-style), so they are hidden from
/// the flat list to avoid duplication. A workspace belongs to a project only
/// when it was explicitly opened from it (``SupermuxWorkspaceAssociationStore``)
/// or physically lives in the project's worktrees dir — never merely because
/// its directory sits inside a project root. This is what lets the user create
/// standalone workspaces (cmux's ⌘T/+) without them being swallowed by a
/// project whose directory they happened to inherit.
///
/// This is purely a display filter — `TabManager.tabs` is untouched, so
/// selection, ⌘-number navigation, and workspace lifecycle still operate on the
/// full set. Workspaces that already belong to a cmux workspace group, or any
/// workspace when no projects are registered, are never filtered.
@MainActor
enum SupermuxMainListFilter {
    /// One ``SupermuxProjectResolutionCache`` per window, keyed by the window's
    /// `TabManager`. The cache's staleness pruning trims entries to the
    /// caller's live workspace ids, so a single app-wide instance would let two
    /// windows (each passing its *own* tab list) permanently evict each other's
    /// entries every pass. Weak keys: a cache dies with its window's manager.
    private static let caches =
        NSMapTable<TabManager, SupermuxProjectResolutionCache>.weakToStrongObjects()

    /// The window-scoped resolution cache for `tabManager`, created on first
    /// use. Shared by the flat-list filter and ``SupermuxProjectsMount`` so
    /// each workspace's project resolution is computed once per invalidation,
    /// not once per consumer.
    static func resolutionCache(for tabManager: TabManager) -> SupermuxProjectResolutionCache {
        if let cache = caches.object(forKey: tabManager) { return cache }
        let cache = SupermuxProjectResolutionCache()
        caches.setObject(cache, forKey: tabManager)
        return cache
    }

    /// Returns the workspaces to render in cmux's flat list, with
    /// project-owned (ungrouped) workspaces removed.
    /// - Parameters:
    ///   - tabs: All workspaces from `TabManager.tabs`.
    ///   - tabManager: The calling window's manager, selecting its cache.
    static func tabsForMainList(_ tabs: [Workspace], tabManager: TabManager) -> [Workspace] {
        // The AppKit NSTableView sidebar experiment (Debug opt-in only on the
        // fork — see the `appkit-sidebar-default-off` touchpoint in
        // FeatureFlags.swift) renders none of the fork's sidebar surfaces: no Projects
        // section, no hidden-row-aware menus, no activity indicator. Hiding
        // rows there would strand project workspaces with no sidebar
        // representation at all and let its full-list NSMenu actions close or
        // reorder around rows the user can't see. In that mode nothing is
        // hidden, so every consumer (render context, menu enablement, the
        // shared Move Up/Down stepping) degrades to stock cmux behavior.
        guard !CmuxFeatureFlags.shared.isAppKitSidebarListEnabled else { return tabs }
        return resolutionCache(for: tabManager).filter(
            tabs,
            projects: SupermuxComposition.projectsModel.projects,
            associations: SupermuxComposition.workspaceAssociations
        )
    }

    /// The ids hidden from the flat list because a project owns them, derived
    /// from an already-computed ``tabsForMainList(_:tabManager:)`` result so
    /// render passes that need both don't filter twice.
    static func projectHiddenWorkspaceIds(
        _ tabs: [Workspace], mainListTabs: [Workspace]
    ) -> Set<UUID> {
        guard mainListTabs.count != tabs.count else { return [] }
        return Set(tabs.map(\.id)).subtracting(mainListTabs.map(\.id))
    }

    /// Convenience for call sites that need only the hidden set (event
    /// handlers, context-menu builders); runs the filter through the window's
    /// cache first.
    static func projectHiddenWorkspaceIds(
        _ tabs: [Workspace], tabManager: TabManager
    ) -> Set<UUID> {
        projectHiddenWorkspaceIds(tabs, mainListTabs: tabsForMainList(tabs, tabManager: tabManager))
    }
}

/// Memoizes the per-workspace "which project owns this?" resolution consumed
/// by ``SupermuxMainListFilter`` (flat-list hiding) and
/// ``SupermuxProjectsMount`` (nested-row grouping).
///
/// The resolution (`SupermuxWorkspaceAssociationStore.projectId`) normalizes
/// the workspace directory plus every project's worktrees dir with NSString
/// path APIs — O(tabs × projects) bridge allocations — and both consumers run
/// inside SwiftUI bodies that re-evaluate on every `TabManager` change,
/// unread-state change, and cwd notification. Steady-state renders must
/// therefore hit a cache instead of re-normalizing everything. One instance
/// serves one window (see ``SupermuxMainListFilter/resolutionCache(for:)``).
///
/// Invalidation:
/// - each workspace's entry is keyed by its raw `currentDirectory` string, so
///   a cwd change recomputes just that workspace;
/// - a `projects` change flushes everything (compared cheaply — the unchanged
///   COW buffer short-circuits `==`);
/// - association-store mutations (associate / markStandalone / forget / prune,
///   and the durable directory links routed through them) flush via the
///   store's observable ``SupermuxWorkspaceAssociationStore/revision``;
/// - durable directory-map changes that *bypass* the store (the projects
///   model's sibling-build `adopt()` fold-in, `performLoad`'s actor-hop
///   completion) flush via a by-value compare of
///   ``SupermuxWorkspaceAssociationStore/durableDirectoryAssociations``,
///   which `revision` cannot see.
///
/// The revision and durable-map reads happen unconditionally on EVERY call —
/// including full cache hits — because they double as the callers' SwiftUI
/// re-render dependency: both are Observation-tracked, so a body that resolves
/// through this cache re-renders when associations change even without a
/// paired `TabManager` publish (e.g. opening the already-selected workspace
/// from a project row associates it but no-ops the selection).
@MainActor
final class SupermuxProjectResolutionCache {
    private var entryByWorkspaceId: [UUID: (directory: String, projectId: UUID?)] = [:]
    private var cachedProjects: [SupermuxProject] = []
    /// The durable directory→project map the entries were computed against.
    private var cachedDurable: [String: UUID] = [:]
    /// The association-store revision the cache entries were computed at.
    private var validatedRevision = -1

    /// Returns `tabs` minus the ungrouped workspaces a project owns.
    func filter(
        _ tabs: [Workspace],
        projects: [SupermuxProject],
        associations: SupermuxWorkspaceAssociationStore
    ) -> [Workspace] {
        validate(projects: projects, associations: associations)
        guard !projects.isEmpty else {
            if !entryByWorkspaceId.isEmpty { entryByWorkspaceId = [:] }
            return tabs
        }
        // Once closed workspaces outnumber live ones, collect the live ids and
        // drop the stale entries after the pass.
        var liveIds: Set<UUID>? = entryByWorkspaceId.count > tabs.count ? [] : nil
        var visible: [Workspace] = []
        visible.reserveCapacity(tabs.count)
        for workspace in tabs {
            // Every live workspace counts as live — including cmux-grouped
            // ones, whose entries the Projects mount populates — so pruning
            // never evicts a sibling consumer's still-valid entries.
            liveIds?.insert(workspace.id)
            // Leave cmux-grouped workspaces alone; only hide loose workspaces
            // that a project owns (explicit association or a worktree dir).
            if workspace.groupId != nil {
                visible.append(workspace)
                continue
            }
            if resolvedProjectId(for: workspace, projects: projects, associations: associations) == nil {
                visible.append(workspace)
            }
        }
        if let liveIds {
            entryByWorkspaceId = entryByWorkspaceId.filter { liveIds.contains($0.key) }
        }
        return visible
    }

    /// The project owning `workspace`, or `nil` when it is standalone —
    /// memoized under the same validity keys as ``filter(_:projects:associations:)``
    /// (the flat list hides a workspace exactly when this returns non-`nil`).
    func projectId(
        forWorkspace workspace: Workspace,
        projects: [SupermuxProject],
        associations: SupermuxWorkspaceAssociationStore
    ) -> UUID? {
        validate(projects: projects, associations: associations)
        guard !projects.isEmpty else { return nil }
        return resolvedProjectId(for: workspace, projects: projects, associations: associations)
    }

    /// Flushes the memo when any validity key changed. Performs the observable
    /// `revision` and `durableDirectoryAssociations` reads unconditionally —
    /// they are the callers' re-render dependency (see the type doc); a
    /// hit-path shortcut around them would silently freeze the sidebar and the
    /// Projects mount on association changes.
    private func validate(
        projects: [SupermuxProject],
        associations: SupermuxWorkspaceAssociationStore
    ) {
        let revision = associations.revision
        let durable = associations.durableDirectoryAssociations
        if revision != validatedRevision || projects != cachedProjects || durable != cachedDurable {
            entryByWorkspaceId = [:]
            validatedRevision = revision
            cachedProjects = projects
            cachedDurable = durable
        }
    }

    private func resolvedProjectId(
        for workspace: Workspace,
        projects: [SupermuxProject],
        associations: SupermuxWorkspaceAssociationStore
    ) -> UUID? {
        let directory = workspace.currentDirectory
        if let entry = entryByWorkspaceId[workspace.id], entry.directory == directory {
            return entry.projectId
        }
        let projectId = associations.projectId(
            forWorkspace: workspace.id, directory: directory, in: projects
        )
        entryByWorkspaceId[workspace.id] = (directory, projectId)
        return projectId
    }
}
