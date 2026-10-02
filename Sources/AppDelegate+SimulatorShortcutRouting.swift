import AppKit

extension cmuxApp {
    func performNewSimulatorPaneFromMenu() {
        guard let appDelegate = AppDelegate.shared,
              appDelegate.executeConfiguredCmuxAction(
                id: CmuxSurfaceTabBarBuiltInAction.newSimulator.configID,
                tabManager: activeTabManager,
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
              ) else {
            NSSound.beep()
            return
        }
    }
}

extension AppDelegate {
    func handleSimulatorShortcutRouting(_ event: NSEvent) -> Bool {
        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil {
            let focusContext = shortcutEventFocusContext(event)
            guard focusContext.simulatorFocused else { return handleSimulatorShortcut(event) }
            guard focusContext.allowsSimulatorShortcutRouting else { return false }
            let shortcutContext = focusContext.shortcutContext
            let chordActions = KeyboardShortcutSettings.Action.simulatorActions.filter { action in
                KeyboardShortcutSettings.effectiveWhenClause(for: action).evaluate(shortcutContext)
            }
            if armConfiguredShortcutChordIfNeeded(event: event, actions: chordActions) {
                return true
            }
        }
        return handleSimulatorShortcut(event)
    }

    func performConfiguredNewSimulatorAction(
        context: MainWindowContext,
        onExecuted: (() -> Void)?
    ) -> Bool {
        // SUPERMUX:begin remote-simulator-new-action
        // In a device mirror the simulator runs on the Mac that owns the
        // workspace, shown here in a viewer tab; never a local one.
        if let workspace = context.tabManager.selectedWorkspace,
           let pane = workspace.bonsplitController.focusedPaneId,
           SupermuxRemoteSimulators.shared.openIfDeviceMirror(workspace, paneId: pane, focus: true) {
            onExecuted?()
            return true
        }
        // SUPERMUX:end remote-simulator-new-action
        guard CmuxFeatureFlags.shared.isSimulatorEnabled,
              let workspace = context.tabManager.selectedWorkspace,
              let pane = workspace.bonsplitController.focusedPaneId,
              workspace.newSimulatorSurface(inPane: pane, focus: true) != nil else {
            return false
        }
        onExecuted?()
        return true
    }

    func isMenuBackedShortcutAction(_ action: KeyboardShortcutSettings.Action) -> Bool {
        action != .showHideAllWindows
            && action != .globalSearch
            && action != .clearScreenKeepScrollback
            && action != .increaseWorkspaceTerminalFontSize
            && action != .decreaseWorkspaceTerminalFontSize
            && action != .resetWorkspaceTerminalFontSize
            && action != .fileExplorerOpenSelection
            && action != .fileExplorerOpenSelectionFinderAlias
            && !KeyboardShortcutSettings.Action.simulatorActions.contains(action)
    }
}
