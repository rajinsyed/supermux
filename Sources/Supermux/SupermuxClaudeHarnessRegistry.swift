import AppKit
import CmuxSettings
import Foundation
import SupermuxClaudeHarness
import SupermuxKit

/// Owns one ``SupermuxHarnessViewModel`` per agent-session panel.
///
/// The registry — never a view — owns harness lifetime. `AgentSessionPanelView`
/// renders `Color.clear` whenever `isVisibleInUI` is false, so a `@StateObject`
/// in the mount would terminate a running `claude` process every time the user
/// switched tabs.
///
/// Teardown paths:
/// 1. The panel's `close()` fence (`supermux-claude-harness-lifecycle`,
///    touchpoint #408) — the primary path for every user-driven close.
/// 2. `applicationWillTerminate` (`supermux-claude-harness-terminate` fence in
///    `AppDelegate`) calls `terminateAllForAppShutdown()`: stdin EOF + SIGTERM
///    synchronously for every live child, so a child mid-turn cannot outlive
///    the app on the strength of stdin EOF alone.
///
/// A `surface_closed` event-bus subscription is deliberately **not** used as a
/// safety net: that event also fires on surface *detach* (origin `detach`,
/// `Workspace.swift`), where the panel moves to another workspace and the
/// session must keep running — killing on that event would be a correctness
/// bug, not a net.
@MainActor
final class SupermuxClaudeHarnessRegistry {
    static let shared = SupermuxClaudeHarnessRegistry()

    /// Shared process registry used by both desktop panels and mobile RPCs.
    let sessions = ClaudeSessionRegistry()
    /// Shared persistence store used by both desktop panels and mobile RPCs.
    let store: SupermuxHarnessSessionStore
    private var models: [UUID: SupermuxHarnessViewModel] = [:]

    private init() {
        store = SupermuxHarnessSessionStore(
            baseDirectory: CmuxSettings.CmuxStateDirectory.url(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        )
    }

    /// The existing model for a panel, without creating one.
    ///
    /// Pure read — safe to call from a view `body`. Creation and callback
    /// wiring go through ``ensureModel(panelID:workingDirectory:onDerivedTitle:)``
    /// from `.onAppear`/`.task`, never from render (the fork's no-writes-from-
    /// body rule).
    func existingModel(panelID: UUID) -> SupermuxHarnessViewModel? {
        models[panelID]
    }

    /// Creates (or refreshes the callback of) a panel's model.
    ///
    /// - Parameters:
    ///   - panelID: The panel's transient id (the registry key).
    ///   - workingDirectory: The directory a fresh session should start in.
    ///   - onDerivedTitle: Called once with the title derived from the first
    ///     prompt, so the host can rename the tab.
    @discardableResult
    func ensureModel(
        panelID: UUID,
        workingDirectory: String,
        onDerivedTitle: @escaping (String) -> Void
    ) -> SupermuxHarnessViewModel {
        if let existing = models[panelID] {
            existing.onDerivedTitle = onDerivedTitle
            return existing
        }
        let model = SupermuxHarnessViewModel(
            panelID: panelID,
            workingDirectory: workingDirectory,
            registry: sessions,
            store: store
        )
        model.onDerivedTitle = onDerivedTitle
        models[panelID] = model
        return model
    }

    /// Whether a panel already has a live harness model.
    func hasModel(panelID: UUID) -> Bool {
        models[panelID] != nil
    }

    /// Terminates and forgets one panel's session.
    func close(panelID: UUID) {
        guard let model = models.removeValue(forKey: panelID) else { return }
        Task { await model.shutdown() }
    }

    /// Terminates every session (app shutdown).
    func closeAll() async {
        let live = models.values
        models.removeAll()
        for model in live {
            await model.shutdown()
        }
    }
}
