import AppKit
import Foundation
import SwiftUI

/// Live sidebar font scale for the supermux Projects section.
///
/// cmux's flat workspace list scales its rows by the `sidebar-font-size` setting
/// (``SidebarTabItemFontScale``); the Projects section reuses the *same* scale so
/// bumping the sidebar font size enlarges projects and their nested workspaces
/// too, instead of leaving them stuck at a fixed size. Mirrors cmux's
/// `SidebarTabItemSettingsStore` font handling: the size is read off the main
/// thread and refreshed whenever the Ghostty config reloads (the broadcast a
/// settings change emits).
@MainActor
final class SupermuxSidebarFontScaleStore: ObservableObject {
    /// Multiplier injected into the Projects section via
    /// `EnvironmentValues.supermuxSidebarFontScale`. `1` at the default size.
    @Published private(set) var fontScale: CGFloat

    private var loadTask: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?

    init() {
        fontScale = SidebarTabItemFontScale.scale(for: GhosttyConfig.defaultSidebarFontSize)
        refresh()
        configObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    deinit {
        loadTask?.cancel()
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    /// Reloads the sidebar font size off-main (config parsing is file I/O) and
    /// republishes the scale only when it actually changed.
    private func refresh() {
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            let size = await Task.detached(priority: .utility) {
                GhosttyConfig.load().sidebarFontSize
            }.value
            guard let self, !Task.isCancelled else { return }
            let next = SidebarTabItemFontScale.scale(for: size)
            if next != fontScale { fontScale = next }
        }
    }
}
