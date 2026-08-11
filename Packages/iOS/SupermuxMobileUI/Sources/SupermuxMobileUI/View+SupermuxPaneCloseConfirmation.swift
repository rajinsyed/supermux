import Foundation
public import SwiftUI

extension View {
    /// Presents the shared destructive confirmation for every iOS pane-close entry point.
    /// - Parameters:
    ///   - isPresented: Whether the confirmation is visible.
    ///   - confirm: Closes the captured pane target.
    public func supermuxPaneCloseConfirmation(
        isPresented: Binding<Bool>,
        confirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            String(
                localized: "supermux.panes.closeConfirmTitle",
                defaultValue: "Close Pane?",
                bundle: .module
            ),
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(
                String(
                    localized: "supermux.panes.closeConfirmAction",
                    defaultValue: "Close",
                    bundle: .module
                ),
                role: .destructive,
                action: confirm
            )
            .accessibilityIdentifier("MobileClosePaneConfirmButton")
            Button(
                String(
                    localized: "supermux.common.cancel",
                    defaultValue: "Cancel",
                    bundle: .module
                ),
                role: .cancel
            ) {
                isPresented.wrappedValue = false
            }
            .accessibilityIdentifier("MobileClosePaneCancelButton")
        } message: {
            Text(String(
                localized: "supermux.panes.closeConfirmMessage",
                defaultValue: "This will close the pane on your Mac.",
                bundle: .module
            ))
        }
    }
}
