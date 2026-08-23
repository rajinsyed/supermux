import AppKit
import CmuxCommandPalette
import Foundation

extension CommandPaletteCommandContribution {
    static var newClaudeHarnessPane: Self {
        Self(
            commandId: "palette.newClaudeHarnessPane",
            title: { _ in
                String(localized: "supermux.harness.command.newPane.title", defaultValue: "New Claude Pane")
            },
            subtitle: { _ in
                String(localized: "supermux.harness.command.newPane.subtitle", defaultValue: "Claude Code")
            },
            keywords: ["new", "claude", "harness", "agent", "chat", "code", "pane"]
        )
    }
}

extension CommandPaletteHandlerRegistry {
    @MainActor
    mutating func registerNewClaudeHarnessPane(tabManager: TabManager, windowId: UUID) {
        register(commandId: "palette.newClaudeHarnessPane") {
            guard let appDelegate = AppDelegate.shared,
                  appDelegate.executeConfiguredCmuxAction(
                    id: CmuxSurfaceTabBarBuiltInAction.newClaudeHarness.configID,
                    tabManager: tabManager,
                    preferredWindow: appDelegate.mainWindow(for: windowId)
                  ) else {
                NSSound.beep()
                return
            }
        }
    }
}

extension cmuxApp {
    func performNewClaudeHarnessPaneFromMenu() {
        guard let appDelegate = AppDelegate.shared,
              appDelegate.executeConfiguredCmuxAction(
                id: CmuxSurfaceTabBarBuiltInAction.newClaudeHarness.configID,
                tabManager: activeTabManager,
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
              ) else {
            NSSound.beep()
            return
        }
    }
}

extension AppDelegate {
    func performConfiguredNewClaudeHarnessAction(
        context: MainWindowContext,
        onExecuted: (() -> Void)?
    ) -> Bool {
        guard let workspace = context.tabManager.selectedWorkspace,
              let pane = workspace.bonsplitController.focusedPaneId,
              workspace.newSupermuxHarnessSurface(inPane: pane, focus: true) != nil else {
            return false
        }
        onExecuted?()
        return true
    }

    func performNewClaudeHarnessShortcutAction(event: NSEvent) -> Bool {
        guard let manager = activeTabManagerForCommands(preferredWindow: event.window),
              let context = mainWindowContext(for: manager) else {
            return false
        }
        return performConfiguredNewClaudeHarnessAction(context: context, onExecuted: nil)
    }
}
