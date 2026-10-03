import AppKit
import Combine
import SwiftUI

/// The titlebar `+` button's tooltip: upstream's "New workspace (⌘N)", or
/// "New Workspace on <Mac> (⌘N)" while its window's selected workspace makes
/// + create on another Mac (``SupermuxNewWorkspaceTarget/device(_:)``). Since
/// + and ⌘N create on this Mac even with a mirror selected (touchpoint #571),
/// that target is no longer produced and the tooltip is upstream's. Applied by
/// the `new-workspace-target-help` fence in `TitlebarNewWorkspaceSplitButton`.
///
/// Follows the window's selection (the tab manager's change signal) and
/// re-checks on hover, which also covers a focus change inside a workspace.
struct SupermuxNewWorkspaceButtonHelp: ViewModifier {
    let defaultHelp: String
    @StateObject private var model = Model()

    func body(content: Content) -> some View {
        content
            .safeHelp(model.help ?? defaultHelp)
            .background(WindowAccessor { model.attach(to: $0, defaultHelp: defaultHelp) })
            .onHover { hovering in
                if hovering { model.refresh() }
            }
    }

    /// The window-scoped help text; `nil` until a window is known.
    @MainActor
    final class Model: ObservableObject {
        @Published private(set) var help: String?
        private weak var window: NSWindow?
        private var defaultHelp = ""
        private var selectionChanges: AnyCancellable?

        func attach(to window: NSWindow, defaultHelp: String) {
            self.defaultHelp = defaultHelp
            guard window !== self.window else { return refresh() }
            self.window = window
            selectionChanges = tabManager?.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            refresh()
        }

        func refresh() {
            guard window != nil else { return }
            let next = SupermuxNewWorkspaceTarget.plusButtonHelp(in: tabManager, default: defaultHelp)
            if next != help { help = next }
        }

        private var tabManager: TabManager? {
            AppDelegate.shared?.contextForMainWindow(window)?.tabManager
        }
    }
}

extension View {
    /// The `+` button's help, naming the other Mac while + creates there.
    func supermuxNewWorkspaceButtonHelp(_ defaultHelp: String) -> some View {
        modifier(SupermuxNewWorkspaceButtonHelp(defaultHelp: defaultHelp))
    }
}
