import Foundation
public import SwiftUI

/// Capability-gated pane creation mounted inside the workspace surface picker.
public struct SupermuxPaneMenuControls: View {
    private let canCreateSimulator: Bool
    private let createSimulator: () -> Void

    /// Creates the menu control.
    /// - Parameters:
    ///   - canCreateSimulator: Whether a native Mac Simulator pane can be created.
    ///   - createSimulator: Creates and activates a Simulator pane.
    public init(
        canCreateSimulator: Bool,
        createSimulator: @escaping () -> Void
    ) {
        self.canCreateSimulator = canCreateSimulator
        self.createSimulator = createSimulator
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
    }
}
