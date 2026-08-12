public import CmuxAgentChatUI
public import SwiftUI

/// Assistant prose, rendered as markdown.
///
/// Reuses upstream's renderer stack — ``ChatProseSegmenter`` for code fences,
/// ``ChatTextBlockParser`` for block structure, and ``ChatMarkdownRenderer``
/// for cached inline parsing. `SupermuxMobileUI` already depends on
/// `CmuxAgentChatUI` (for Focus Mode), so this is reuse of a tested renderer
/// rather than a second markdown implementation to keep in sync — and the
/// cache matters: parsing markdown on every lazy-row rematerialization is
/// exactly what makes a streaming transcript stutter.
public struct SupermuxClaudeMarkdownText: View {
    private let messageID: String
    private let markdown: String

    @Environment(\.chatMarkdownRenderer) private var renderer

    private static let segmenter = ChatProseSegmenter()
    private static let blockParser = ChatTextBlockParser()

    /// Creates markdown prose.
    /// - Parameters:
    ///   - messageID: Stable identity, used as the render cache key.
    ///   - markdown: The markdown source.
    public init(messageID: String, markdown: String) {
        self.messageID = messageID
        self.markdown = markdown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.segmenter.segments(from: markdown)) { segment in
                switch segment.kind {
                case .code(let language):
                    codeBlock(segment.content, language: language, index: segment.index)
                case .text:
                    textSegment(segment.content, index: segment.index)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func textSegment(_ content: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.blockParser.blocks(from: content)) { block in
                blockView(block, key: "\(messageID)-\(index)-\(block.index)")
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatTextBlock, key: String) -> some View {
        switch block.kind {
        case .rule:
            Divider()
        case .heading(let level):
            inline(block.text, key: key)
                .font(.system(size: headingSize(level), weight: .semibold))
        case .paragraph:
            inline(block.text, key: key)
                .font(SupermuxClaudeStyle.body())
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 3)
                inline(block.text, key: key)
                    .font(SupermuxClaudeStyle.body())
                    .foregroundStyle(.secondary)
            }
        case .bullet(let indent):
            listRow(marker: "•", indent: indent, text: block.text, key: key)
        case .ordered(let marker, let indent):
            listRow(marker: marker, indent: indent, text: block.text, key: key)
        }
    }

    private func listRow(marker: String, indent: Int, text: String, key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(SupermuxClaudeStyle.body())
                .foregroundStyle(.secondary)
            inline(text, key: key)
                .font(SupermuxClaudeStyle.body())
        }
        .padding(.leading, CGFloat(indent) * 14)
    }

    /// Inline markdown, through the environment's cache when one is present.
    /// Without a cache the parse still happens — a missing environment value
    /// must degrade to slower, never to raw `**markers**` on screen.
    private func inline(_ text: String, key: String) -> Text {
        guard let renderer else {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            options.failurePolicy = .returnPartiallyParsedIfPossible
            let parsed = (try? AttributedString(markdown: text, options: options))
                ?? AttributedString(text)
            return Text(parsed)
        }
        return Text(renderer.render(messageID: key, markdown: text))
    }

    private func codeBlock(_ code: String, language: String?, index: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(SupermuxClaudeStyle.mono())
                .textSelection(.enabled)
                .padding(10)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(
            cornerRadius: SupermuxClaudeStyle.cardCornerRadius,
            style: .continuous
        ))
        .accessibilityLabel(language.map { "\($0) code" } ?? "code")
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 22
        case 2: 19
        case 3: 17
        default: SupermuxClaudeStyle.bodyPointSize
        }
    }
}
