#if canImport(UIKit)
import Foundation
public import UIKit

/// Capability-gated pane creation mounted inside the workspace surface picker.
///
/// The picker is a native `UIMenu` built only when UIKit presents it, so this
/// contributes an immutable inline section rather than a SwiftUI view.
@MainActor
public struct SupermuxPaneMenuControls {
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

    /// The inline "New Simulator" section, or `nil` when the connected Mac
    /// cannot create a Simulator pane.
    public func makeMenuElement() -> UIMenuElement? {
        guard canCreateSimulator else { return nil }
        let identifier = "MobileNewSimulatorMenuItem"
        let createSimulator = createSimulator
        let action = UIAction(
            title: String(
                localized: "supermux.panes.newSimulator",
                defaultValue: "New Simulator",
                bundle: .module
            ),
            image: UIImage(systemName: "iphone"),
            identifier: UIAction.Identifier(identifier)
        ) { _ in createSimulator() }
        action.accessibilityIdentifier = identifier
        return UIMenu(options: .displayInline, children: [action])
    }
}
#endif
