import SwiftUI

/// Scrolls the right sidebar's mode tabs sideways when even their narrowest
/// layout (the selected tab's label, the other tabs' icons) is wider than the
/// bar, as it is at the fork's 200 pt minimum with every tab shown. Without it
/// the tabs overflow the bar, clipping both ends and pushing the close button
/// out of the window.
struct SupermuxModeBarOverflow: ViewModifier {
    func body(content: Content) -> some View {
        ViewThatFits(in: .horizontal) {
            content
            ScrollView(.horizontal, showsIndicators: false) { content }
        }
    }
}
