import SwiftUI

/// The long-press menu every row in the phone's Projects sidebar goes through.
///
/// A single seam rather than a bare `.contextMenu` at each call site, because
/// this section is not an ordinary SwiftUI list: it is one `UIHostingConfiguration`
/// cell inside the shell's `UITableView` (touchpoint #148). Whether a menu
/// installed down here survives that host's own gesture stack is a property of
/// the host, not of the row — so it is decided once, in one place, and every
/// row inherits the answer.
///
/// Rows also expose their menu entries as `accessibilityAction`s, which is what
/// actually makes them reachable to VoiceOver: a context menu is a pointer/touch
/// affordance and assistive technology never opens one.
extension View {
    /// Attaches a row's long-press menu.
    /// - Parameter menuItems: The menu's buttons, in presentation order.
    func supermuxSidebarContextMenu(
        @ViewBuilder menuItems: @escaping () -> some View
    ) -> some View {
        contextMenu(menuItems: menuItems)
    }
}
