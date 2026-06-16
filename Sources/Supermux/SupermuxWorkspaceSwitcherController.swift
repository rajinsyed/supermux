import AppKit
import Combine
import Observation
import SupermuxKit

extension SupermuxComposition {
    /// App-wide workspace switcher (the Cmd+`-held, app-switcher-style overlay).
    /// Receives every app-local event through one fenced hook in `AppDelegate`'s
    /// shortcut monitor; owns the overlay and per-window MRU order.
    static let workspaceSwitcher = SupermuxWorkspaceSwitcherController()
}

/// Drives the supermux workspace switcher: the macOS app-switcher / Arc-style
/// overlay that opens on Cmd+` (held), cycles workspaces while Cmd stays down,
/// and commits to the highlighted workspace when Cmd is released.
///
/// Like the macOS app switcher, a *quick* tap+release commits immediately and the
/// overlay never appears — it only shows if the modifier is held past a short
/// threshold or a second cycle press arrives. One app-wide instance (owned by
/// ``SupermuxComposition``) receives every event from cmux's existing app-local
/// NSEvent monitor through a single fenced hook in `AppDelegate`. It never mutates
/// `TabManager` except the single `selectWorkspace(_:)` on commit, and does no
/// work on the typing hot path beyond a couple of cheap guards while idle.
@MainActor
@Observable
final class SupermuxWorkspaceSwitcherController {
    /// How long the modifier must be held before the overlay appears. A faster
    /// tap+release switches with no overlay (macOS Cmd-Tab quick-switch feel).
    private static let overlayShowDelay: Duration = .milliseconds(150)

    @ObservationIgnored let overlay = SupermuxWorkspaceSwitcherOverlayController()

    /// MRU workspace ids per window's `TabManager`.
    @ObservationIgnored private var mruByManager: [ObjectIdentifier: [UUID]] = [:]
    /// Persistent selection/tabs subscriptions per `TabManager`.
    @ObservationIgnored private var subscriptions: [ObjectIdentifier: Set<AnyCancellable>] = [:]

    // Active hold-session state.
    @ObservationIgnored private weak var sessionManager: TabManager?
    @ObservationIgnored private weak var hostWindow: NSWindow?
    @ObservationIgnored private var sessionOrder: [UUID] = []
    @ObservationIgnored private var selectedIndex = 0
    @ObservationIgnored private var isCommitting = false
    @ObservationIgnored private var holdModifier: NSEvent.ModifierFlags = .command
    @ObservationIgnored private var showOverlayTask: Task<Void, Never>?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []

    /// A hold session is in progress (modifier down): the controller owns the
    /// keyboard even before the overlay is shown.
    private(set) var isSessionActive = false
    /// The overlay UI is actually on screen.
    private(set) var isOverlayVisible = false

    /// Eagerly tracks a window's `TabManager` so most-recently-used order and
    /// preview warming are populated before the first Cmd+`. Safe to call
    /// repeatedly; subscribes at most once per manager. Call from a per-window
    /// supermux mount (e.g. the sidebar projects section's `onAppear`).
    func register(tabManager: TabManager) {
        subscribeIfNeeded(to: tabManager)
    }

    // MARK: - Event hook (single entry from the AppDelegate monitor)

    /// Gives the switcher first crack at every app-local event. Returns `true`
    /// when the event was consumed (the monitor then swallows it).
    func handleMonitorEvent(_ event: NSEvent, appDelegate: AppDelegate) -> Bool {
        if isSessionActive {
            return handleSessionEvent(event)
        }
        // Idle hot path: only a modified keyDown can open the switcher. The cheap
        // modifier gate keeps normal typing (and ⇧-only keys) free before the
        // configured-chord match runs.
        guard event.type == .keyDown,
              !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        guard !isPresentationBlocked() else { return false }
        let next = KeyboardShortcutSettings.shortcut(for: .supermuxWorkspaceSwitcherNext)
        if next.matches(event: event) {
            return beginSession(backward: false, openingShortcut: next, event: event, appDelegate: appDelegate)
        }
        let previous = KeyboardShortcutSettings.shortcut(for: .supermuxWorkspaceSwitcherPrevious)
        if previous.matches(event: event) {
            return beginSession(backward: true, openingShortcut: previous, event: event, appDelegate: appDelegate)
        }
        return false
    }

    private func handleSessionEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            if !event.modifierFlags.contains(holdModifier) {
                commit()
            }
            return false
        case .keyUp:
            return true
        case .keyDown:
            if KeyboardShortcutSettings.shortcut(for: .supermuxWorkspaceSwitcherPrevious).matches(event: event) {
                advance(backward: true)
                return true
            }
            if KeyboardShortcutSettings.shortcut(for: .supermuxWorkspaceSwitcherNext).matches(event: event) {
                advance(backward: false)
                return true
            }
            switch event.keyCode {
            case 53: cancel()                       // Escape
            case 36, 76: commit()                   // Return / Enter
            case 123, 126: advance(backward: true)  // Left / Up
            case 124, 125: advance(backward: false) // Right / Down
            default: break
            }
            return true // own all keys while the session is active
        default:
            return false
        }
    }

    // MARK: - Session lifecycle

    private func beginSession(
        backward: Bool,
        openingShortcut: StoredShortcut,
        event: NSEvent,
        appDelegate: AppDelegate
    ) -> Bool {
        // Pair the command-target manager with its OWN window, so the overlay
        // never mounts in one window while switching another window's manager
        // (e.g. when Settings or a non-main window is key).
        guard let manager = appDelegate.activeTabManagerForCommands(preferredWindow: event.window),
              let window = manager.window, window.contentView != nil else {
            return false
        }
        subscribeIfNeeded(to: manager)

        let tabsOrder = manager.tabs.map(\.id)
        guard !tabsOrder.isEmpty else { return false }
        let order = SupermuxWorkspaceSwitcherOrder.sessionOrder(
            currentId: manager.selectedTabId,
            mru: mruByManager[ObjectIdentifier(manager)] ?? [],
            tabsOrder: tabsOrder
        )
        guard order.count > 1 else { return false } // nothing to switch to

        sessionManager = manager
        hostWindow = window
        sessionOrder = order
        selectedIndex = SupermuxWorkspaceSwitcherOrder.initialSelection(count: order.count, backward: backward)
        holdModifier = primaryHoldModifier(for: openingShortcut)
        isSessionActive = true
        installLifecycleObservers(window: window)

        // Defer the overlay: a quick tap+release commits before this fires, so
        // the switcher never flashes for a fast back-and-forth toggle.
        showOverlayTask = Task { [weak self] in
            try? await Task.sleep(for: Self.overlayShowDelay)
            guard !Task.isCancelled else { return }
            self?.showOverlayIfNeeded()
        }
        return true
    }

    /// The modifier the user must keep held for the chord that *opened* this
    /// session; releasing it commits. Falls back to ⌘ for an unmodified binding.
    private func primaryHoldModifier(for shortcut: StoredShortcut) -> NSEvent.ModifierFlags {
        if shortcut.command { return .command }
        if shortcut.control { return .control }
        if shortcut.option { return .option }
        return .command
    }

    private func showOverlayIfNeeded() {
        guard isSessionActive, !isOverlayVisible, let manager = sessionManager, let window = hostWindow else { return }
        let items = buildItems(order: sessionOrder, manager: manager)
        // Keep the commit source (`sessionOrder`) 1:1 with what's actually shown: a
        // workspace closed between begin and show would otherwise desync the visual
        // index from the id committed on release / click.
        sessionOrder = items.map(\.id)
        guard sessionOrder.count > 1 else { cancel(); return }
        selectedIndex = min(selectedIndex, sessionOrder.count - 1)
        showOverlayTask?.cancel()
        showOverlayTask = nil
        overlay.viewState.items = items
        overlay.viewState.selectedIndex = selectedIndex
        overlay.viewState.onSelectIndex = { [weak self] index in self?.selectAndCommit(index: index) }
        overlay.viewState.onPointerOverCard = { [weak self] index in self?.pointerSelect(index: index) }
        overlay.viewState.onCancel = { [weak self] in self?.cancel() }
        overlay.show(in: window)
        isOverlayVisible = true
    }

    private func advance(backward: Bool) {
        guard isSessionActive, !sessionOrder.isEmpty else { return }
        selectedIndex = SupermuxWorkspaceSwitcherOrder.advance(
            selectedIndex, count: sessionOrder.count, backward: backward
        )
        // A deliberate cycle press means the user is browsing — show the overlay
        // now (cancels the hold timer) instead of waiting out the delay.
        if isOverlayVisible {
            overlay.viewState.selectedIndex = selectedIndex
        } else {
            showOverlayIfNeeded()
        }
    }

    private func selectAndCommit(index: Int) {
        guard isSessionActive, sessionOrder.indices.contains(index) else { return }
        selectedIndex = index
        if isOverlayVisible { overlay.viewState.selectedIndex = index }
        commit()
    }

    /// Real pointer movement placed the cursor over `index`: move the highlight
    /// there without committing, like hovering in the macOS app switcher. Releasing
    /// the held modifier then commits to it. Driven only by actual movement (see
    /// `SupermuxPointerTrackingStrip`), so it never disturbs the keyboard-chosen
    /// card on appear or while the strip scrolls under a stationary cursor.
    private func pointerSelect(index: Int) {
        guard isSessionActive, sessionOrder.indices.contains(index), selectedIndex != index else { return }
        selectedIndex = index
        if isOverlayVisible { overlay.viewState.selectedIndex = index }
    }

    private func commit() {
        guard isSessionActive, !isCommitting else { return }
        isCommitting = true
        let targetId = sessionOrder.indices.contains(selectedIndex) ? sessionOrder[selectedIndex] : nil
        let manager = sessionManager
        endSession()
        // Validate on commit: a workspace closed mid-session is silently skipped.
        if let targetId, let manager, let workspace = manager.tabs.first(where: { $0.id == targetId }) {
            manager.selectWorkspace(workspace)
        }
        isCommitting = false
    }

    private func cancel() {
        guard isSessionActive else { return }
        endSession()
    }

    private func endSession() {
        showOverlayTask?.cancel()
        showOverlayTask = nil
        if isOverlayVisible { overlay.hide() }
        isOverlayVisible = false
        isSessionActive = false
        sessionOrder = []
        sessionManager = nil
        hostWindow = nil
        removeLifecycleObservers()
    }

    // MARK: - MRU tracking

    private func subscribeIfNeeded(to manager: TabManager) {
        let key = ObjectIdentifier(manager)
        guard subscriptions[key] == nil else { return }
        var cancellables = Set<AnyCancellable>()
        manager.selectedTabIdPublisher
            .sink { [weak self, weak manager] selectedId in
                guard let self, let manager else { return }
                self.handleSelectionChange(selectedId, manager: manager)
            }
            .store(in: &cancellables)
        manager.tabsPublisher
            .sink { [weak self, weak manager] tabs in
                guard let self, let manager else { return }
                let key = ObjectIdentifier(manager)
                self.mruByManager[key] = SupermuxWorkspaceSwitcherOrder.pruned(
                    self.mruByManager[key] ?? [], keeping: Set(tabs.map(\.id))
                )
            }
            .store(in: &cancellables)
        subscriptions[key] = cancellables
    }

    private func handleSelectionChange(_ selectedId: UUID?, manager: TabManager) {
        if let selectedId {
            let key = ObjectIdentifier(manager)
            mruByManager[key] = SupermuxWorkspaceSwitcherOrder.promote(selectedId, in: mruByManager[key] ?? [])
        }
        // An external selection change (not our own commit) invalidates the
        // frozen session — cancel rather than show a stale strip.
        if isSessionActive, !isCommitting, manager === sessionManager {
            cancel()
        }
    }

    // MARK: - Lifecycle helpers

    private func isPresentationBlocked() -> Bool {
        if NSApp.modalWindow != nil { return true }
        if let sheet = NSApp.keyWindow?.attachedSheet, sheet.isVisible { return true }
        return false
    }

    /// Cancels the session if the user leaves it without releasing the modifier:
    /// the app deactivates (Cmd-Tab away), or the host window closes / loses key
    /// (clicked another window). Without these, a missed ⌘-release could leave
    /// the switcher stuck owning the keyboard.
    private func installLifecycleObservers(window: NSWindow) {
        removeLifecycleObservers()
        let center = NotificationCenter.default
        resignObserver = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            let observer = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
            windowObservers.append(observer)
        }
    }

    private func removeLifecycleObservers() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }
}
