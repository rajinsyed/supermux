import AppKit
import Combine
import CmuxFoundation
import CmuxSettings
import CmuxSidebar
import Foundation
import SupermuxKit
import SwiftUI

/// Composition point for supermux features inside the cmux app target.
///
/// Supermux deliberately deviates from the repo's no-static-state rule here:
/// constructing the runtime at the AppDelegate composition root would require
/// touching heavily-churned upstream files, and minimizing the upstream merge
/// surface is supermux's prime directive (see SUPERMUX.md). This enum is the
/// single sanctioned global for supermux state; everything behind it uses
/// constructor injection.
@MainActor
enum SupermuxComposition {
    /// App-wide AI gateway client. Reads the Vercel AI Gateway key from the same
    /// secure `0600` file the Settings card writes (under the cmux state
    /// directory), so a key pasted in Settings is picked up without rebuilding
    /// the client.
    static let aiClient: any SupermuxAICompleting = {
        let store = SecretFileStore(
            // CmuxStateDirectory is re-exported by both CmuxSettings and
            // CmuxSocketControl after upstream's package consolidation, so qualify
            // it to the defining module to avoid an ambiguous-use error.
            baseDirectory: CmuxSettings.CmuxStateDirectory.url(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        )
        let key = SecretFileKey(id: SupermuxAIConfig.secretKeyID, fileName: SupermuxAIConfig.secretFileName)
        return SupermuxAIGatewayClient(apiKeyProvider: {
            guard let value = try? await store.value(for: key), !value.isEmpty else { return nil }
            return value
        })
    }()

    /// AI branch-name suggester for the new-worktree flow.
    static let aiBranchNamer: any SupermuxAIBranchNaming = SupermuxAIBranchNamer(client: aiClient)

    /// AI commit-message generator for the Changes panel.
    static let aiCommitMessenger: any SupermuxAICommitMessaging = SupermuxAICommitMessenger(client: aiClient)

    /// App-wide projects model, shared by every window's sidebar.
    static let projectsModel: SupermuxProjectsModel = {
        let store = SupermuxProjectStore(fileURL: SupermuxPaths.defaultProjectsFileURL)
        let service = SupermuxGitWorktreeService(runner: CommandRunner())
        return SupermuxProjectsModel(store: store, worktreeService: service, branchNamer: aiBranchNamer)
    }()

    /// App-wide run-action coordinator behind the ⌘G shortcut.
    static let runCoordinator = SupermuxRunCoordinator(projectsModel: projectsModel)

    /// Tracks which workspaces were explicitly opened from a project, so only
    /// those (plus worktrees, matched by directory) nest under a project —
    /// workspaces created via cmux's normal flow stay standalone even when
    /// their directory happens to sit inside a registered project. Backed by the
    /// projects model so the link survives a restart by directory (a project's
    /// main workspace sits at the root and has no worktree-dir signal).
    static let workspaceAssociations = SupermuxWorkspaceAssociationStore(persistence: projectsModel)

    /// App-wide PR model for *unopened* worktree badges, injected into every
    /// window's Projects section so one poll pass and one repo cache serve all
    /// sidebars (the model is multi-window-safe: client-scoped union tracking
    /// plus a generation guard). Must be a stable instance — the section seeds
    /// its `@State` from it on first mount.
    static let worktreePullRequestModel = SupermuxWorktreePullRequestModel()
}

/// The view mounted inside the cmux sidebar (see the `sidebar-projects-section`
/// touchpoint in `ContentView.swift`). Bridges the window's environment to the
/// package-owned projects section.
struct SupermuxProjectsMount: View {
    @EnvironmentObject private var tabManager: TabManager

    /// Live sidebar font scale (cmux's `sidebar-font-size`), injected into the
    /// Projects section so project rows and nested workspaces grow/shrink with
    /// the same setting as the flat workspace list.
    @StateObject private var fontScaleStore = SupermuxSidebarFontScaleStore()

    /// Owns the per-workspace observation subscription (git branch, working
    /// directory, status, agent lifecycle, in-place title renames) so a late
    /// field change re-reads the nested snapshots. Its lifetime is kept out of
    /// `body` to avoid a render→resubscribe→replay→invalidate spin — see
    /// ``SupermuxWorkspaceObservation``.
    @StateObject private var observation = SupermuxWorkspaceObservation()

    // cmux's PR-probe gates (Settings → sidebar), read via @AppStorage so a
    // toggle re-renders the mount and restarts/stops the section's probe loop.
    // Missing keys default to true, matching `SidebarWorkspaceDetailDefaults`'s
    // `boolValue` semantics; the AND mirrors its `pullRequestPollingEnabled`.
    @AppStorage(SidebarWorkspaceDetailDefaults.showPullRequestsKey) private var showPullRequests = true
    @AppStorage(SidebarWorkspaceDetailDefaults.watchGitStatusKey) private var watchGitStatus = true

    var body: some View {
        // Make the body's dependency on the observation token explicit (cmux
        // does the same with `extensionSidebarUpdateToken`): a token bump forces
        // the per-workspace snapshots below to be rebuilt from current state.
        let _ = observation.token
        // Reading tabs/selectedTabId here subscribes this small, eager section
        // to workspace add/remove/select changes (not per-keystroke output), so
        // a project's live workspaces stay nested and in sync underneath it.
        let projects = SupermuxComposition.projectsModel.projects
        let associations = SupermuxComposition.workspaceAssociations
        // This window's memoized project resolution — the same cache instance
        // the flat-list filter uses, so per-workspace NSString path
        // normalization runs once per invalidation, not once per consumer.
        // Its validity preamble reads the store's observable `revision` and
        // durable directory map on every call (cache hits included), which is
        // what re-renders this body on association changes now that the raw
        // `associations.projectId` reads no longer happen here.
        let resolutionCache = SupermuxMainListFilter.resolutionCache(for: tabManager)
        let pullRequestsEnabled = watchGitStatus && showPullRequests
        let openWorkspaces = tabManager.tabs.map { workspace -> SupermuxOpenWorkspace in
            let isSelected = workspace.id == tabManager.selectedTabId
            // Full snapshots (branch/PR/activity, each walking the bonsplit
            // pane tree) only for project-nested rows; the section consumes
            // just the directory of everything else.
            guard let projectId = resolutionCache.projectId(
                forWorkspace: workspace,
                projects: projects,
                associations: associations
            ) else {
                return SupermuxWorkspaceRow.standaloneSnapshot(for: workspace, isSelected: isSelected)
            }
            return SupermuxWorkspaceRow.snapshot(
                for: workspace,
                isSelected: isSelected,
                projectId: projectId,
                isRunning: SupermuxComposition.runCoordinator.isRunning(workspaceId: workspace.id),
                includePullRequest: pullRequestsEnabled
            )
        }
        SupermuxProjectsSectionView(
            model: SupermuxComposition.projectsModel,
            opener: SupermuxTabManagerOpener(tabManager: tabManager),
            openWorkspaces: openWorkspaces,
            onSelectWorkspace: { [weak tabManager] id in
                guard let workspace = tabManager?.tabs.first(where: { $0.id == id }) else { return }
                tabManager?.selectWorkspace(workspace)
            },
            onCloseWorkspace: { [weak tabManager] id in
                guard let workspace = tabManager?.tabs.first(where: { $0.id == id }) else { return }
                _ = tabManager?.closeWorkspaceWithConfirmation(workspace)
            },
            onRenameWorkspace: { [weak tabManager] id, title in
                // Route through cmux's shared rename mutation: an empty/whitespace
                // title clears the custom title and reverts to the process title.
                tabManager?.setCustomTitle(tabId: id, title: title)
            },
            onReorderWorkspace: { [weak tabManager] draggedId, targetId in
                // Reorder the dragged workspace adjacent to the target in cmux's
                // own tab order (the source of the nested list). Direction is
                // taken from their current positions so dropping lands the row
                // just below the target when dragging down, above when up.
                guard let tabManager,
                      let from = tabManager.tabs.firstIndex(where: { $0.id == draggedId }),
                      let to = tabManager.tabs.firstIndex(where: { $0.id == targetId }),
                      from != to else { return }
                if from < to {
                    _ = tabManager.reorderWorkspace(tabId: draggedId, after: targetId, isDragOperation: true)
                } else {
                    _ = tabManager.reorderWorkspace(tabId: draggedId, before: targetId, isDragOperation: true)
                }
            },
            onOpenPullRequest: { [weak tabManager] url, workspaceId in
                // Honor cmux's PR-link routing: open in the cmux browser when
                // the setting is on, else the default browser. A badge on an
                // open workspace's row opens in *that* workspace (selecting it
                // first, mirroring cmux's own sidebar rows); a worktree badge
                // has no workspace and uses the selected one.
                if BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(),
                   let tabManager {
                    if let workspaceId,
                       let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) {
                        tabManager.selectWorkspace(workspace)
                    }
                    let targetId = workspaceId ?? tabManager.selectedTabId
                    if let targetId,
                       tabManager.openBrowser(
                           inWorkspace: targetId,
                           url: url,
                           preferSplitRight: true,
                           insertAtEnd: true
                       ) != nil {
                        return
                    }
                }
                _ = NSWorkspace.shared.open(url)
            },
            // Honor cmux's own PR-probe gates: with polling off, the section
            // clears worktree badges and never touches GitHub.
            pullRequestPolling: SupermuxPullRequestPollingPolicy(isEnabled: pullRequestsEnabled),
            // One app-wide PR model: every window's sidebar shares one poll
            // pass and one repo cache instead of probing per window.
            pullRequestModel: SupermuxComposition.worktreePullRequestModel,
            // One app-wide logo cache, shared with the workspace switcher.
            iconStore: SupermuxComposition.projectIconStore
        )
        // Subscribe once on appear and re-subscribe only when the set of open
        // workspaces changes; `register` eagerly seeds the switcher's MRU order.
        .onAppear {
            observation.observe(tabs: tabManager.tabs)
            SupermuxComposition.workspaceSwitcher.register(tabManager: tabManager)
        }
        .onChange(of: tabManager.tabs.map(\.id)) {
            observation.observe(tabs: tabManager.tabs)
        }
        .environment(\.supermuxSidebarFontScale, fontScaleStore.fontScale)
        // Publish this section's height so the sidebar shrinks the empty area
        // below the rows by it (else the content overflows and the empty space
        // scrolls — see SupermuxProjectsSectionHeightPreferenceKey + cmux #3241).
        .supermuxReportsProjectsSectionHeight()
    }
}

/// Owns the merged Combine subscription that drives ``SupermuxProjectsMount``'s
/// per-workspace re-reads, keeping the subscription's lifetime out of `body`.
///
/// Trigger families per workspace:
/// - `$customTitle`, delivered immediately — so renaming a nested workspace
///   via `setCustomTitle` re-titles its row at once, matching cmux's own
///   sidebar. The raw `$title` is deliberately NOT observed: agent TUIs
///   animate the automatic process title at ~10 Hz (cmux #5570), and an
///   earlier raw-`$title` leg re-ran the mount body and rebuilt every
///   workspace snapshot on each animation frame.
/// - The workspace's `sidebarProcessTitleObservation` settle stream — the same
///   model cmux's own rows use for automatic titles (0.5 s settle, 2 s
///   staleness deadline), so a nested row's process title updates at settled
///   cadence instead of animation cadence. Project-owned workspaces are hidden
///   from the flat list, so nothing else consumes their settle stream.
/// - `sidebarObservationPublisher` (`gitBranch`, `currentDirectory`, status,
///   logs, progress, ports — the late-detected branch update), debounced per
///   workspace by upstream's 40ms coalesce interval: this stream bursts at
///   telemetry rate during agent runs, and undebounced each event re-ran the
///   mount body and rebuilt every snapshot. `TabItemView` debounces the very
///   same publisher per row (`workspaceObservationCoalesceInterval`); per-leg
///   (not post-merge) so one busy workspace cannot starve the others' updates.
/// - ``SupermuxWorkspaceLifecycleRelay`` — agent lifecycle mutations fire no
///   cmux sidebar publisher at all, so without it the nested rows' activity
///   indicator went stale on lifecycle-only changes (socket
///   `set_agent_lifecycle`, hibernation, feed attention).
///
/// The merge is folded once more across workspaces (`coalesceLatest`, leading
/// edge synchronous), and every delivery is gated by ``RenderedRowState``: the
/// token bumps only when a field the Projects section actually renders
/// changed. Telemetry that only touches unrendered state (logs, progress,
/// ports, status entries) and lifecycle events that re-assert an unchanged
/// activity (every agent hook re-reports `running` while working) no longer
/// rebuild the section.
///
/// Rebuilding this merge inside `body` and feeding it to `.onReceive` resubscribed
/// every render, and on each new subscription the `@Published` inputs behind
/// `sidebarObservationPublisher` re-send their current values (the `CombineLatest`
/// then emits) — which drove a render→resubscribe→replay→invalidate feedback loop
/// that pegged a CPU core. By owning the subscription here and rebuilding it only
/// when the set of open workspaces changes, steady-state renders never resubscribe.
@MainActor
final class SupermuxWorkspaceObservation: ObservableObject {
    /// Bumped on each observed per-workspace *rendered-field* change; read by
    /// the mount's `body` to re-read the nested workspace snapshots.
    @Published private(set) var token = 0

    /// Upstream's `workspaceObservationCoalesceInterval` (`TabItemView`),
    /// mirrored so nested rows and flat rows coalesce telemetry bursts alike.
    private static let coalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(40)

    private var observedIds: Set<UUID> = []
    private var observedTabs: [Workspace] = []
    private var cancellable: AnyCancellable?
    private var settledTitleTasks: [Task<Void, Never>] = []
    private var lastRendered: [RenderedRowState] = []

    /// The per-workspace fields ``SupermuxWorkspaceRow`` snapshots actually
    /// render (title, directory, branch, activity, PR badge). The volatile
    /// automatic process title is represented by the settle model's
    /// `changeGeneration` instead of its raw value, so telemetry-triggered
    /// checks don't see mid-animation title frames as changes.
    private struct RenderedRowState: Equatable {
        let id: UUID
        let customTitle: String?
        let settledTitleGeneration: UInt64
        let directory: String
        let branch: String?
        let activity: SupermuxWorkspaceActivity
        let pullRequest: SupermuxPullRequest?
    }

    private static func renderedState(for workspace: Workspace) -> RenderedRowState {
        RenderedRowState(
            id: workspace.id,
            customTitle: workspace.customTitle,
            settledTitleGeneration: workspace.sidebarProcessTitleObservation.changeGeneration,
            directory: workspace.currentDirectory,
            branch: workspace.supermuxSidebarBranch,
            activity: SupermuxWorkspaceActivityResolver.activity(for: workspace),
            pullRequest: workspace.sidebarPullRequestsInDisplayOrder().first
                .flatMap(SupermuxPullRequest.init(sidebarState:))
        )
    }

    deinit {
        settledTitleTasks.forEach { $0.cancel() }
    }

    /// (Re)subscribes to the workspaces' sidebar-observation streams, but only
    /// when the set of open workspaces actually changes — so steady-state renders
    /// (and pure reorders, which keep the same set) never rebuild the
    /// subscription. Delivery is always deferred past `@Published`'s `willSet`
    /// (via `.receive(on:)` on the immediate leg and the `RunLoop.main`
    /// debounce scheduler on the coalesced legs) so the next body re-read sees
    /// the committed value.
    func observe(tabs: [Workspace]) {
        let ids = Set(tabs.map(\.id))
        guard ids != observedIds else { return }
        observedIds = ids
        observedTabs = tabs
        // Seed without bumping: a set change re-ran the mount body already.
        lastRendered = tabs.map(Self.renderedState(for:))
        settledTitleTasks.forEach { $0.cancel() }
        settledTitleTasks = []
        guard !tabs.isEmpty else {
            cancellable = nil
            return
        }

        let customTitleLegs = tabs.map { workspace in
            workspace.$customTitle.removeDuplicates().map { _ in () }
                .receive(on: RunLoop.main)
                .eraseToAnyPublisher()
        }
        let observationLegs = tabs.map { workspace in
            workspace.sidebarObservationPublisher
                .debounce(for: Self.coalesceInterval, scheduler: RunLoop.main)
                .eraseToAnyPublisher()
        }
        let lifecycleLeg = SupermuxWorkspaceLifecycleRelay.lifecycleDidChange
            .filter { ids.contains($0) }
            .map { _ in () }
            .debounce(for: Self.coalesceInterval, scheduler: RunLoop.main)
            .eraseToAnyPublisher()

        cancellable = Publishers.MergeMany(customTitleLegs + observationLegs + [lifecycleLeg])
            .coalesceLatest(for: Self.coalesceInterval, scheduler: RunLoop.main)
            .sink { [weak self] in self?.bumpIfRenderedStateChanged() }

        // Automatic process titles at settled cadence (cmux's own row model);
        // its publication bumps `changeGeneration`, which the rendered-state
        // comparison picks up.
        for workspace in tabs {
            let changes = workspace.sidebarProcessTitleObservation.changes()
            settledTitleTasks.append(Task { @MainActor [weak self] in
                for await _ in changes {
                    if Task.isCancelled { break }
                    guard let self else { break }
                    self.bumpIfRenderedStateChanged()
                }
            })
        }
    }

    private func bumpIfRenderedStateChanged() {
        let current = observedTabs.map(Self.renderedState(for:))
        guard current != lastRendered else { return }
        lastRendered = current
        token &+= 1
    }
}

/// Lazily builds ``SupermuxChangesMount``'s model exactly once per mount
/// lifetime. An `@State` default expression is evaluated on every parent
/// render (SwiftUI discards the result after first install), which allocated a
/// throwaway `@Observable` model + git-service actor + `CommandRunner` per
/// frame during sidebar resize drags; `@StateObject`'s autoclosure runs only
/// at install. The box publishes nothing, so it never invalidates the mount.
@MainActor
private final class SupermuxChangesModelBox: ObservableObject {
    let model = SupermuxChangesModel(
        service: SupermuxGitChangesService(runner: CommandRunner()),
        commitGenerator: SupermuxComposition.aiCommitMessenger
    )
}

/// The git Changes panel mounted as the right sidebar's `changes` mode (see
/// the `right-sidebar-changes-mode-*` touchpoints). Each mount owns its model
/// so separate windows track their own active workspace independently.
struct SupermuxChangesMount: View {
    let workspaceDirectory: String?
    /// Whether the right sidebar is on-screen. Forwarded to the panel so its
    /// FS-watcher-driven git observation, background auto-fetch, and commit key
    /// equivalents all pause while hidden (the sidebar keeps this content
    /// mounted after its first show).
    var isVisible: Bool = true

    @EnvironmentObject private var tabManager: TabManager
    // Re-render when the user rebinds a shortcut (the configured commit chords
    // are read from `KeyboardShortcutSettings`, which is not itself observable).
    @ObservedObject private var shortcutObserver = KeyboardShortcutSettingsObserver.shared
    @StateObject private var box = SupermuxChangesModelBox()

    var body: some View {
        let _ = shortcutObserver.revision
        SupermuxChangesPanelView(
            model: box.model,
            isVisible: isVisible,
            commitShortcut: Self.keyboardShortcut(for: .supermuxCommit),
            commitAcceleratorShortcut: Self.keyboardShortcut(for: .supermuxCommitAccelerator),
            commitShortcutHint: KeyboardShortcutSettings.shortcut(for: .supermuxCommit).displayString,
            onOpenDiff: { [weak tabManager] in
                guard let tabManager,
                      let appDelegate = NSApp.delegate as? AppDelegate else { return }
                _ = appDelegate.openDiffViewerForFocusedWorkspace(for: tabManager)
            }
        )
        .onAppear { box.model.setDirectory(workspaceDirectory) }
        .onChange(of: workspaceDirectory) { _, newDirectory in
            box.model.setDirectory(newDirectory)
        }
    }

    /// Resolves a configured shortcut into a SwiftUI ``KeyboardShortcut`` the
    /// panel can apply directly; `nil` when the action is unbound or a chord
    /// (the panel then carries no key equivalent for it).
    private static func keyboardShortcut(for action: KeyboardShortcutSettings.Action) -> KeyboardShortcut? {
        let stored = KeyboardShortcutSettings.shortcut(for: action)
        guard let keyEquivalent = stored.keyEquivalent else { return nil }
        return KeyboardShortcut(keyEquivalent, modifiers: stored.eventModifiers)
    }
}

/// The terminal presets bar mounted above each workspace's terminal area (see
/// the `presets-bar` touchpoint in `WorkspaceContentView.swift`). Bridges the
/// workspace to the package-owned ``SupermuxPresetsBarView``: clicking a preset
/// opens its command in a fresh terminal tab in the focused pane, and the Run
/// button toggles this workspace's project run command (the ⌘G action).
struct SupermuxPresetsBarMount: View {
    /// Deliberately *not* `@ObservedObject`: `body` reads only the immutable
    /// `workspace.id`, and the closures capture the workspace weakly and read
    /// its state at click time — observing it re-rendered the bar on every
    /// unrelated `@Published` churn (panel titles, directories, ports…).
    /// Run ↔ Stop stays live via the `@Observable` run coordinator read in
    /// `body`; shortcut rebinds via `shortcutObserver.revision`. If a future
    /// edit needs mutable workspace state in `body`, pass it in as a value.
    let workspace: Workspace
    @ObservedObject private var shortcutObserver = KeyboardShortcutSettingsObserver.shared

    // Minimal mode is chrome-free, so the bar hides itself. The mode is read
    // HERE, not by the `presets-bar` fence in `WorkspaceContentView`: upstream
    // moved its own minimal-mode read out of that view body and into
    // `WorkspaceContentMinimalModeSafeAreaModifier`, and
    // `WorkspaceContentViewVisibilityTests` asserts a mode toggle re-evaluates
    // neither `ContentView` nor `WorkspaceContentView` bodies. Gating inside
    // the mount keeps that contract — a toggle invalidates only this subview —
    // and the mount itself stays permanently in the tree, so the workspace
    // content keeps one structural identity across mode switches.
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        if isMinimalMode {
            EmptyView()
        } else {
            presetsBar
        }
    }

    @ViewBuilder
    private var presetsBar: some View {
        // Subscribes the bar to live run-state changes (Run ↔ Stop) and shortcut
        // rebinds; preset edits invalidate inside the bar view, not here.
        let _ = shortcutObserver.revision
        let runCoordinator = SupermuxComposition.runCoordinator
        SupermuxPresetsBarView(
            model: SupermuxComposition.projectsModel,
            isRunning: runCoordinator.isRunning(workspaceId: workspace.id),
            // Unbound yields the empty string, which hides the hint pill (the
            // bar's documented contract) instead of rendering "Run None".
            runShortcutHint: KeyboardShortcutSettings.shortcutIfBound(for: .supermuxToggleRun)?.displayString ?? "",
            onLaunch: { [weak workspace] preset in
                guard let workspace, preset.isLaunchable else { return }
                guard let paneId = workspace.bonsplitController.focusedPaneId
                    ?? workspace.bonsplitController.allPaneIds.first else { return }
                // Run the preset through the interactive shell (see
                // SupermuxCommandLaunch): resolves shell aliases/functions and
                // keeps the tab open after the command exits.
                _ = workspace.newTerminalSurface(
                    inPane: paneId,
                    focus: true,
                    workingDirectory: workspace.currentDirectory,
                    initialInput: SupermuxCommandLaunch.shellInput(for: preset.command)
                )
            },
            onToggleRun: { [weak workspace] in
                guard let workspace else { return }
                _ = SupermuxComposition.runCoordinator.toggleRun(workspace: workspace)
            }
        )
        // The bar deliberately does not observe the workspace, so a closed run
        // surface would leave the Stop button stale: reconcile from the panel
        // membership stream instead (fires on add/remove only, never typing).
        // The handler mutates run state only when the run surface is actually
        // gone, which then invalidates the bar via the @Observable coordinator.
        // `panelsPublisher` emits at `willSet` timing; `.receive(on:)` defers
        // delivery past the commit (this file's SupermuxWorkspaceObservation
        // idiom) so reconcile reads the committed panels — synchronous
        // delivery both mutated observable state mid-view-update and saw the
        // pre-close dictionary, no-oping on the exact event it exists for.
        .onReceive(workspace.panelsPublisher.receive(on: RunLoop.main)) { [weak workspace] _ in
            guard let workspace else { return }
            SupermuxComposition.runCoordinator.reconcile(workspace: workspace)
        }
    }
}
