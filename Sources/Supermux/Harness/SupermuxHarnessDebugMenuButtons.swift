import SwiftUI

#if DEBUG
struct SupermuxHarnessDebugMenuButtons: View {
    var body: some View {
        Button(
            String(
                localized: "supermux.harness.debug.openPane",
                defaultValue: "Open Claude Harness Pane"
            )
        ) {
            Self.openHarnessPane()
        }
    }

    @MainActor
    private static func openHarnessPane() {
        guard let appDelegate = AppDelegate.shared,
              let manager = appDelegate.activeTabManagerForCommands(),
              let workspace = manager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
            return
        }
        _ = workspace.newSupermuxHarnessSurface(
            inPane: paneId,
            workingDirectory: nil,
            focus: true
        )
    }
}
#endif
