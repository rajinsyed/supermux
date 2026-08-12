import AppKit
import CmuxCommandPalette
import Foundation
import SwiftUI

/// The single action path that opens a native Claude harness panel.
///
/// Every entry point (command palette, File menu, and any future `+`-menu or
/// CLI route) funnels through ``open(tabManager:preferredWindow:)`` — the fork's
/// shared-behavior rule. Duplicating the "find a pane, create the surface,
/// focus it" logic per surface is exactly how two entry points end up disagreeing
/// about which pane they open into.
///
/// lint:allow namespace-type — one shared action, no state. (lint:allow)
@MainActor
enum SupermuxClaudeHarnessLauncher {
    static let paletteCommandID = "palette.supermuxNewClaudeHarness"

    /// Opens a Claude harness surface in the focused workspace.
    /// - Returns: `false` when there is no workspace or pane to open into, so
    ///   callers can beep rather than fail silently.
    @discardableResult
    static func open(tabManager: TabManager) -> Bool {
        guard let workspace = tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
            return false
        }
        let panel = workspace.newAgentSessionSurface(
            inPane: paneId,
            providerID: .claude,
            // The renderer kind is inert on this path: the fork's panel fence
            // branches on the provider and never loads the webview HTML. It is
            // still persisted by upstream, so a value that decodes on an
            // upstream build is the safe choice.
            rendererKind: .react,
            workingDirectory: workspace.currentDirectory,
            focus: true
        )
        return panel != nil
    }
}

extension CommandPaletteCommandContribution {
    /// The palette entry for a native Claude Code session.
    static var supermuxNewClaudeHarness: Self {
        Self(
            commandId: SupermuxClaudeHarnessLauncher.paletteCommandID,
            title: { _ in
                String(
                    localized: "supermux.harness.command.new.title",
                    defaultValue: "New Claude Code Session"
                )
            },
            subtitle: { _ in
                String(
                    localized: "supermux.harness.command.new.subtitle",
                    defaultValue: "Native Claude Code panel"
                )
            },
            keywords: ["claude", "code", "agent", "session", "harness", "new"]
        )
    }
}

extension CommandPaletteHandlerRegistry {
    /// Registers the palette handler for the native Claude harness.
    @MainActor
    mutating func registerSupermuxClaudeHarness(tabManager: TabManager) {
        register(commandId: SupermuxClaudeHarnessLauncher.paletteCommandID) {
            if !SupermuxClaudeHarnessLauncher.open(tabManager: tabManager) {
                NSSound.beep()
            }
        }
    }
}
