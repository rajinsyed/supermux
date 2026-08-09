import SwiftUI

/// Keeps usage-popover content intrinsic-sized until it reaches a scrollable height cap.
struct SupermuxUsagePopoverScrollContainer<Content: View>: View {
    private let width: CGFloat
    private let maximumHeight: CGFloat
    private let content: Content

    init(
        width: CGFloat,
        maximumHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.maximumHeight = maximumHeight
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .frame(width: width)
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}
