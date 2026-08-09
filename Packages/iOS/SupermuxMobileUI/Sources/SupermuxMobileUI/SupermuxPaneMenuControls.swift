import Foundation
public import SwiftUI

/// Capability-gated pane actions mounted inside the workspace surface picker.
public struct SupermuxPaneMenuControls: View {
    private let canCreateSimulator: Bool
    private let canClosePane: Bool
    private let createSimulator: () -> Void
    private let closePane: () -> Void

    /// Creates the menu controls.
    /// - Parameters:
    ///   - canCreateSimulator: Whether a native Mac Simulator pane can be created.
    ///   - canClosePane: Whether the currently visible pane can be closed.
    ///   - createSimulator: Creates and activates a Simulator pane.
    ///   - closePane: Requests confirmation for the current pane close.
    public init(
        canCreateSimulator: Bool,
        canClosePane: Bool,
        createSimulator: @escaping () -> Void,
        closePane: @escaping () -> Void
    ) {
        self.canCreateSimulator = canCreateSimulator
        self.canClosePane = canClosePane
        self.createSimulator = createSimulator
        self.closePane = closePane
    }

    public var body: some View {
        if canCreateSimulator {
            Section {
                Button(action: createSimulator) {
                    Label(
                        String(
                            localized: "supermux.panes.newSimulator",
                            defaultValue: "New Simulator",
                            bundle: .module
                        ),
                        systemImage: "iphone"
                    )
                }
                .accessibilityIdentifier("MobileNewSimulatorMenuItem")
            }
        }

        if canClosePane {
            Section {
                Button(role: .destructive, action: closePane) {
                    Label(
                        String(
                            localized: "supermux.panes.close",
                            defaultValue: "Close Pane",
                            bundle: .module
                        ),
                        systemImage: "xmark.rectangle"
                    )
                }
                .accessibilityIdentifier("MobileClosePaneMenuItem")
            }
        }
    }
}
