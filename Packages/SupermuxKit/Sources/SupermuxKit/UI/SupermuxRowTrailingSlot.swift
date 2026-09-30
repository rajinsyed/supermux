import SwiftUI

/// The fixed-width slot at the right edge of every row nested under a
/// project: an open workspace's amber working spinner (the close button while
/// hovered), a worktree row's hover "open" arrow. Every row reserves it,
/// whatever it shows, so device chips and badges line up down the list.
struct SupermuxRowTrailingSlot<Content: View>: View {
    let fontScale: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: 14 * fontScale, alignment: .center)
    }
}
