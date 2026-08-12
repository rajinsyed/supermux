import SwiftUI
import CmuxFoundation

/// The scrolling transcript.
///
/// `ScrollView` + `LazyVStack`, never `List`: a `List` inserts its own row
/// chrome, animates insertions it should not, and cannot express the
/// bottom-anchored streaming behavior this needs.
///
/// Scroll anchoring is genuinely version-split. On macOS 15+ the dual
/// `defaultScrollAnchor(_:for:)` form plus `onScrollGeometryChange` gives the
/// correct behavior — stick to the bottom while the user is at the bottom, hold
/// position while they are reading further up. Those APIs do not exist on
/// macOS 14 (the deployment floor), so the fallback drives a `ScrollViewReader`
/// and — critically — only scrolls while `isFollowing`. Always scrolling to the
/// tail is the "steals scroll from a reading user" bug in the existing chat
/// transcript; it is deliberately not copied.
struct SupermuxHarnessTranscript: View {
    let rows: [SupermuxHarnessRow]
    let sessionKey: String
    let theme: SupermuxHarnessTheme

    /// Whether the view is pinned to the tail (streaming follows the output).
    @State private var isFollowing = true

    private static let bottomAnchorID = "supermux.harness.transcript.bottom"
    private static let scrollSpaceID = "supermux.harness.transcript.scroll"

    var body: some View {
        if #available(macOS 15.0, *) {
            modernScrollView
        } else {
            legacyScrollView
        }
    }

    // MARK: - macOS 15+

    @available(macOS 15.0, *)
    private var modernScrollView: some View {
        ScrollView {
            content
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(isFollowing ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // "At the bottom" with a small slack so a half-pixel of overscroll
            // or a mid-flight layout pass does not drop out of follow mode.
            geometry.contentOffset.y + geometry.containerSize.height
                >= geometry.contentSize.height - 24
        } action: { _, isAtBottom in
            guard isFollowing != isAtBottom else { return }
            isFollowing = isAtBottom
        }
        .id(sessionKey)
    }

    // MARK: - macOS 14

    /// The fallback tracks "am I at the bottom?" through a preference key (the
    /// only geometry channel macOS 14 offers): scrolling away from the tail
    /// drops follow mode instead of stealing the position back, and returning
    /// to the tail re-engages it. The scroll trigger observes the *last row's
    /// content*, not `rows.count`, so a streaming delta that grows an existing
    /// row still follows.
    private var legacyScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchorID)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: SupermuxHarnessBottomDistanceKey.self,
                                value: geometry.frame(
                                    in: .named(Self.scrollSpaceID)
                                ).minY
                            )
                        }
                    )
            }
            .coordinateSpace(name: Self.scrollSpaceID)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SupermuxHarnessViewportHeightKey.self,
                        value: geometry.size.height
                    )
                }
            )
            .onPreferenceChange(SupermuxHarnessBottomDistanceKey.self) { bottomY in
                bottomMarkerY = bottomY
                updateFollowing()
            }
            .onPreferenceChange(SupermuxHarnessViewportHeightKey.self) { height in
                viewportHeight = height
                updateFollowing()
            }
            .onChange(of: rows.last) { _, _ in
                guard isFollowing else { return }
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
        .id(sessionKey)
    }

    /// Bottom-marker position of the legacy scroll view, in scroll space.
    @State private var bottomMarkerY: CGFloat = 0
    /// Viewport height of the legacy scroll view.
    @State private var viewportHeight: CGFloat = 0

    private func updateFollowing() {
        guard viewportHeight > 0 else { return }
        // Same 24pt slack as the modern branch, so a half-pixel of overscroll
        // or a mid-flight layout pass does not drop out of follow mode.
        let isAtBottom = bottomMarkerY <= viewportHeight + 24
        guard isFollowing != isAtBottom else { return }
        isFollowing = isAtBottom
    }

    // MARK: - Shared content

    private var content: some View {
        LazyVStack(alignment: .leading, spacing: SupermuxHarnessTokens.rowSpacing) {
            ForEach(rows) { row in
                SupermuxHarnessRowView(row: row, theme: theme)
                    // Streaming rows can be transiently wider than the column
                    // while a long unbroken token is laid out; clamping here
                    // keeps the whole transcript from jittering horizontally.
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: SupermuxHarnessTokens.transcriptMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SupermuxHarnessTokens.spacing12)
        .padding(.vertical, SupermuxHarnessTokens.spacing10)
    }
}

extension View {
    /// Marks a short label as *rigid*: it always renders at its ideal width on
    /// one line, and never absorbs the compression a sibling causes.
    ///
    /// Every transcript row is an `HStack` of a fixed label ("Ran command") and
    /// an unbounded value (a 200-character shell command). Left alone, SwiftUI
    /// splits the width between them, and once the label's share falls below one
    /// glyph it wraps *letter by letter* into a one-character column — which is
    /// both the "R\na\nn\n…" text and the ~180pt row height that reads as a
    /// dashed line and huge gaps in the transcript. Making the label rigid moves
    /// it to the front of the layout queue, so the *value* is what truncates.
    ///
    /// Pair it with `.lineLimit(1)` + `.truncationMode(.middle)` on the value,
    /// and never give the value `layoutPriority` — a higher priority there
    /// re-inverts the order and starves the label again.
    func supermuxHarnessRigidLabel() -> some View {
        lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
}

/// Bottom-marker minY in the legacy scroll view's coordinate space.
private struct SupermuxHarnessBottomDistanceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Viewport height of the legacy scroll view.
private struct SupermuxHarnessViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Dispatches one row to its renderer.
///
/// Every case takes immutable values only — no view below the `LazyVStack`
/// boundary holds a reference to the observable session model (the fork's
/// snapshot-boundary rule; violating it reintroduces the 100% CPU spin).
struct SupermuxHarnessRowView: View {
    let row: SupermuxHarnessRow
    let theme: SupermuxHarnessTheme

    var body: some View {
        switch row.kind {
        case .userPrompt(let text):
            SupermuxHarnessUserPromptRow(rowID: row.id, text: text, theme: theme)
        case .assistantProse(let text, let isStreaming):
            SupermuxHarnessAssistantProseRow(
                rowID: row.id, text: text, isStreaming: isStreaming, theme: theme
            )
        case .thinking(let text, let isStreaming):
            SupermuxHarnessThinkingRow(
                rowID: row.id, text: text, isStreaming: isStreaming, theme: theme
            )
        case .toolCall(let call):
            SupermuxHarnessToolCard(call: call, theme: theme)
        case .result(let summary):
            SupermuxHarnessResultRow(summary: summary, theme: theme)
        case .notice(let notice):
            SupermuxHarnessNoticeRow(notice: notice, theme: theme)
        }
    }
}
