import AppKit
import Bonsplit
import Combine
import Foundation
import SupermuxKit

/// Shows which tabs are working: each terminal and Claude harness tab's
/// built-in Bonsplit spinner (`isLoading`, drawn in the tab's icon slot)
/// follows its own panel's agent activity — on while that agent is running or
/// waiting on its background work, off otherwise.
///
/// Only terminal and Claude harness tabs are touched; nothing upstream writes
/// `isLoading` for either. A browser tab's spinner is its page load and a
/// Cloud VM placeholder's is its boot, both owned by upstream.
///
/// Driven by ``SupermuxWorkspaceLifecycleRelay``, which fires on every agent
/// lifecycle change and on every change of a device mirror's overlay; each
/// ``SupermuxDeviceStatusProjector`` pass also syncs every mirror, so a mirror
/// tab projected after its overlay arrived spins at once. The
/// changed workspaces are synced together on the next main-actor turn (after
/// the mutation that fired the relay has finished), walking each one's panels
/// once; Bonsplit's `updateTab` writes only a value that changed. A tab that
/// upstream rebuilds (respawn, session restore) gets its spinner back on the
/// next lifecycle event. A workspace moved to another window is synced with
/// its Dock (``workspaceMoved(_:)``). Dock tabs are synced per panel
/// (``syncDock(_:panelId:)``) when their lifecycle changes
/// (`dock-tab-agent-working`) and when a tab moves into the Dock
/// (`dock-tab-agent-working-attach`).
///
/// A working tab whose window is off screen (fully covered, minimized, the
/// app hidden, Remote Host Mode) holds its spinner off: Bonsplit's spinner is
/// a Core Animation rotation (held to 15 frames a second by
/// ``SupermuxTabSpinnerFrameRate``) that keeps running in a window nobody
/// sees. Every main window's visibility change re-syncs that window's
/// workspaces and Docks on the next main-actor turn, so the spinner is back
/// as soon as the window shows again.
@MainActor
final class SupermuxTabActivitySync {
    static let shared = SupermuxTabActivitySync()

    private var cancellable: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var pendingWorkspaceIDs: Set<UUID> = []
    private var pendingWindowIDs: Set<UUID> = []
    private var isFlushScheduled = false
    /// Working tabs whose spinner is held off because their window is off
    /// screen. The debug socket reports them as spinning, so E2E drivers see
    /// the working state whether or not the test app's window is in view. An
    /// entry for a tab closed or moved away while held off stays behind (a
    /// move creates a new tab); it is a few bytes and tab ids are never
    /// reused.
    private var heldOffScreenTabIDs: Set<TabID> = []
    /// Tabs this type set spinning, with their controller, so the spinner
    /// frame-rate sweep keeps going while one of them can be remounted.
    private var spinningTabs: [TabID: SpinningTab] = [:]
    private struct SpinningTab { weak var controller: BonsplitController? }

    /// Starts following the relay and main-window visibility; later calls do
    /// nothing.
    func start() {
        guard cancellable == nil else { return }
        cancellable = SupermuxWorkspaceLifecycleRelay.lifecycleDidChange.sink { [weak self] workspaceID in
            self?.schedule(workspaceID: workspaceID)
        }
        // AppKit can post these during window teardown outside the main
        // actor's executor (see GhosttyTerminalView's occlusion observer), so
        // each hops with a Task rather than assuming isolation.
        let center = NotificationCenter.default
        let windowNotifications = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in windowNotifications {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                Task { @MainActor [weak self] in self?.schedule(window: window) }
            })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleAllWindows() }
            })
        }
    }

    // MARK: - Coalescing

    private func schedule(workspaceID: UUID) {
        pendingWorkspaceIDs.insert(workspaceID)
        scheduleFlush()
    }

    /// Only main windows hold workspaces; every other window (Settings,
    /// popovers, panels) is ignored.
    private func schedule(window: NSWindow) {
        guard let windowID = AppDelegate.shared?.mainWindowId(from: window) else { return }
        pendingWindowIDs.insert(windowID)
        scheduleFlush()
    }

    private func scheduleAllWindows() {
        guard let app = AppDelegate.shared else { return }
        for window in app.mainWindowsForVisibilityController() {
            schedule(window: window)
        }
    }

    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        Task { [weak self] in self?.flush() }
    }

    private func flush() {
        isFlushScheduled = false
        let windowIDs = pendingWindowIDs
        let workspaceIDs = pendingWorkspaceIDs
        pendingWindowIDs = []
        pendingWorkspaceIDs = []
        for windowID in windowIDs {
            syncWindow(windowID)
        }
        for workspaceID in workspaceIDs {
            guard let workspace = Workspace.liveWorkspace(id: workspaceID) else { continue }
            sync(workspace)
        }
    }

    // MARK: - Syncing

    /// Sets every terminal and Claude harness tab of `workspace` to its
    /// panel's working state.
    func sync(_ workspace: Workspace) {
        let windowOnScreen = Self.windowOnScreen(ownerID: workspace.id)
        for (panelID, panel) in workspace.panels where panel.panelType == .terminal || panel.panelType == .claudeHarness {
            guard let tab = workspace.surfaceIdFromPanelId(panelID) else { continue }
            let activity = SupermuxWorkspaceActivityResolver.activity(forPanel: panelID, in: workspace)
            setWorking(activity == .working, tab: tab, in: workspace.bonsplitController, windowOnScreen: windowOnScreen)
        }
    }

    /// Sets a Dock terminal tab to its panel's working state (the Dock keeps
    /// its own agent lifecycle per panel and never fires the relay). Claude
    /// harness panels never enter the Dock.
    static func syncDock(_ store: DockSplitStore, panelId: UUID) {
        guard store.panels[panelId]?.panelType == .terminal,
              let tab = store.surfaceId(forPanelId: panelId) else { return }
        let states = store.agentRuntimeByPanelId[panelId]?.agentLifecycleStates ?? [:]
        let activity = SupermuxWorkspaceActivityResolver.activity(fromStatesByPanelId: [panelId: states])
        shared.setWorking(
            activity == .working,
            tab: tab,
            in: store.bonsplitController,
            windowOnScreen: windowOnScreen(ownerID: store.workspaceId)
        )
    }

    /// Re-syncs every workspace of a main window, their Docks and the
    /// window's own Dock (its visibility changed). Never creates a Dock.
    private func syncWindow(_ windowID: UUID) {
        guard let app = AppDelegate.shared, let tabManager = app.tabManagerFor(windowId: windowID) else { return }
        for workspace in tabManager.tabs {
            sync(workspace)
            if let dock = workspace._dockSplit { Self.syncDockTabs(dock) }
        }
        if let dock = app.existingWindowDock(forWindowId: windowID) { Self.syncDockTabs(dock) }
    }

    private static func syncDockTabs(_ store: DockSplitStore) {
        for panelId in store.panels.keys {
            syncDock(store, panelId: panelId)
        }
    }

    /// The one place a tab's working state is written. Bonsplit draws it as
    /// its own loading spinner in the tab's text colour; a fork tint (the
    /// sidebar's amber) would be applied here once Bonsplit can take one.
    /// `windowOnScreen` matters only for a working tab: off screen its
    /// spinner is held off until the window shows again.
    func setWorking(_ isWorking: Bool, tab: TabID, in controller: BonsplitController, windowOnScreen: Bool) {
        if isWorking && !windowOnScreen {
            heldOffScreenTabIDs.insert(tab)
        } else {
            heldOffScreenTabIDs.remove(tab)
        }
        let spins = isWorking && windowOnScreen
        if spins {
            spinningTabs[tab] = SpinningTab(controller: controller)
            SupermuxTabSpinnerFrameRate.capSoon()
        } else {
            spinningTabs[tab] = nil
        }
        controller.updateTab(tab, isLoading: spins)
    }

    /// A workspace moved into this window from another (`tab-activity-workspace-moved`):
    /// its tabs and its Dock's follow their new window's visibility, synced
    /// on the next main-actor turn once the move has finished.
    func workspaceMoved(_ workspace: Workspace) {
        Task { @MainActor [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.sync(workspace)
            if let dock = workspace._dockSplit { Self.syncDockTabs(dock) }
        }
    }

    /// Whether any tab this type set spinning still spins, mounted or not
    /// (a workspace you left is unmounted and remounts when you come back).
    /// Forgets tabs that were closed or stopped spinning.
    func hasSpinningTab() -> Bool {
        spinningTabs = spinningTabs.filter { id, entry in entry.controller?.tab(id)?.isLoading == true }
        return !spinningTabs.isEmpty
    }

    /// Whether `tab`, shown in the window of `ownerID` (a workspace, or a
    /// Dock's owner), is working with its spinner held off because that
    /// window is off screen (read by the debug socket). A hold left on a tab
    /// whose window is back on screen reads false, so a spinner that never
    /// came back shows as not spinning.
    func isHeldOffScreen(_ tab: TabID, ownerID: UUID) -> Bool {
        heldOffScreenTabIDs.contains(tab) && !Self.windowOnScreen(ownerID: ownerID)
    }

    // MARK: - Window visibility

    /// Whether the main window showing a workspace, or a Dock owned by a
    /// workspace or a window (`ownerID`), is on screen. A window that cannot
    /// be resolved (mid-replacement, not registered yet) counts as on screen,
    /// so the spinner shows as it always did.
    ///
    /// Only state ``start()`` hears change is read. Alpha is not: a window
    /// soft-hidden by the titlebar dismiss (alpha 0, still ordered in) comes
    /// back with no notification, so it keeps its spinner as before.
    private static func windowOnScreen(ownerID: UUID) -> Bool {
        guard let app = AppDelegate.shared,
              let window = app.mainWindowContainingWorkspace(ownerID) ?? app.windowForMainWindowId(ownerID) else {
            return true
        }
        return SupermuxWindowVisibility.windowIsOnScreen(window)
    }
}

/// Bonsplit's tab spinner is an uncapped Core Animation rotation: while one
/// is on screen the display composites at its full refresh rate (120 Hz on
/// ProMotion) instead of idling down. A spinner this small looks the same at
/// 15 frames a second, so each running spinner's rotation is re-added with
/// that frame rate (Bonsplit only adds its rotation when none is running, so
/// the capped copy stays). Bonsplit itself is not changed: the spinner is
/// found by its animation key.
///
/// Bonsplit restarts the rotation, uncapped, whenever a spinner's view
/// re-enters a window (switching back to a workspace remounts its tab bar),
/// so while any spinner runs or a working tab could be remounted it is
/// checked again every 2 s; the check stops once no tab spins.
@MainActor
enum SupermuxTabSpinnerFrameRate {
    private static let animationKey = "tabLoadingSpinnerRotation"
    private static let frameRate = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15)
    private static var isQuickPassScheduled = false
    private static var sweep: Task<Void, Never>?

    /// Caps every running tab spinner once SwiftUI has mounted the ones just
    /// turned on (next turn and again shortly after for a late mount), then
    /// keeps the 2 s sweep going.
    static func capSoon() {
        guard !isQuickPassScheduled else { return }
        isQuickPassScheduled = true
        Task { @MainActor in
            capAll()
            try? await Task.sleep(for: .milliseconds(300))
            isQuickPassScheduled = false
            capAll()
            startSweep()
        }
    }

    private static func startSweep() {
        guard sweep == nil else { return }
        sweep = Task { @MainActor in
            repeat {
                try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(500))
            } while capAll() > 0 || SupermuxTabActivitySync.shared.hasSpinningTab()
            sweep = nil
        }
    }

    /// Caps every running tab spinner in a visible window; returns how many run.
    @discardableResult
    private static func capAll() -> Int {
        var running = 0
        for window in NSApp.windows where window.isVisible {
            if let layer = window.contentView?.superview?.layer ?? window.contentView?.layer {
                running += cap(layer)
            }
        }
        return running
    }

    #if DEBUG
    /// Running tab spinners in visible windows, and how many run capped
    /// (`supermux.devices.mirror.tab_indicators` reports it).
    static func debugCounts() -> (running: Int, capped: Int) {
        var running = 0, capped = 0
        func visit(_ layer: CALayer) {
            if let animation = layer.animation(forKey: animationKey) {
                running += 1
                if animation.preferredFrameRateRange.maximum == frameRate.maximum { capped += 1 }
            }
            layer.sublayers?.forEach(visit)
        }
        for window in NSApp.windows where window.isVisible {
            if let layer = window.contentView?.superview?.layer ?? window.contentView?.layer { visit(layer) }
        }
        return (running, capped)
    }
    #endif

    private static func cap(_ layer: CALayer) -> Int {
        var running = 0
        if let animation = layer.animation(forKey: animationKey) {
            running = 1
            if animation.preferredFrameRateRange.maximum != frameRate.maximum,
               let capped = animation.copy() as? CAAnimation {
                capped.preferredFrameRateRange = frameRate
                layer.add(capped, forKey: animationKey)
            }
        }
        for sublayer in layer.sublayers ?? [] { running += cap(sublayer) }
        return running
    }
}
