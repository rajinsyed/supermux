import SwiftUI

/// Resolved maximum bubble width (container width times the theme's
/// fraction), measured once at the transcript-list level so rows never
/// need their own GeometryReader.
struct ChatBubbleMaxWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

// SUPERMUX:begin agent-chat-bubble-width-public
// Made public (was internal) so fork-owned rows behind the presentation seam
// can cap their own bubbles at the same resolved width. Without it a fork row
// would need a per-row GeometryReader, which discards ChatContainerWidth's
// first-render fix (width reports 0 on the first pass, so a proportional cap
// would snap from full-width to narrow) and adds layout work to the streaming
// path.
// SUPERMUX:end agent-chat-bubble-width-public
public extension EnvironmentValues {
    /// The maximum width a chat bubble may occupy.
    var chatBubbleMaxWidth: CGFloat {
        get { self[ChatBubbleMaxWidthKey.self] }
        set { self[ChatBubbleMaxWidthKey.self] = newValue }
    }
}
