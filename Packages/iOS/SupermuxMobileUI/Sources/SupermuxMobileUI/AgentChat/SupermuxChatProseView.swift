public import CmuxAgentChat
public import CmuxAgentChatUI
public import SwiftUI

/// Agent prose: full-bleed markdown text with no bubble.
///
/// The single biggest departure from the old surface. Agent output is the
/// *document* the user came to read, so it gets the full column width and the
/// page background; wrapping it in a tinted bubble both wastes ~25% of the
/// width and implies a chat-app symmetry that does not exist — the two sides
/// of this conversation are not the same kind of thing.
///
/// Block structure (headings, lists, quotes, rules) and fenced code come from
/// upstream's cached segmenter/parser, so streaming stays cheap.
public struct SupermuxChatProseView: View {
    private let prose: ChatProse
    private let messageID: String
    private let onShowCodeDetail: (String, Int) -> Void
    private let onCopied: () -> Void

    @Environment(\.supermuxChatTheme) private var theme
    @Environment(\.chatContentCache) private var contentCache
    @Environment(\.chatMarkdownRenderer) private var renderer

    /// How many lines of a fenced code block render inline.
    private static let codeLineCap = 12

    /// Creates a prose view.
    ///
    /// - Parameters:
    ///   - prose: The text payload.
    ///   - messageID: Owning message identity, for caches and detail routing.
    ///   - onShowCodeDetail: Opens a fenced block's full text.
    ///   - onCopied: Reports a completed copy.
    public init(
        prose: ChatProse,
        messageID: String,
        onShowCodeDetail: @escaping (String, Int) -> Void = { _, _ in },
        onCopied: @escaping () -> Void = {}
    ) {
        self.prose = prose
        self.messageID = messageID
        self.onShowCodeDetail = onShowCodeDetail
        self.onCopied = onCopied
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments) { segment in
                segmentView(segment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(action: copy) {
                Label(SupermuxChatUserBubble.copyTitle, systemImage: "doc.on.doc")
            }
        }
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = prose.text
        onCopied()
        #endif
    }

    private var segments: [ChatProseSegment] {
        contentCache?.proseSegments(messageID: messageID, text: prose.text)
            ?? ChatProseSegmenter().segments(from: prose.text)
    }

    @ViewBuilder
    private func segmentView(_ segment: ChatProseSegment) -> some View {
        switch segment.kind {
        case .text:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(blocks(for: segment)) { block in
                    blockView(block, segmentIndex: segment.index)
                }
            }
        case .code(let language):
            codeBlock(segment: segment, language: language)
        }
    }

    private func blocks(for segment: ChatProseSegment) -> [ChatTextBlock] {
        contentCache?.textBlocks(
            messageID: "\(messageID)#\(segment.index)",
            text: segment.content
        ) ?? ChatTextBlockParser().blocks(from: segment.content)
    }

    @ViewBuilder
    private func blockView(_ block: ChatTextBlock, segmentIndex: Int) -> some View {
        let inline = renderer?.render(
            messageID: "\(messageID)#\(segmentIndex)#\(block.index)",
            markdown: block.text
        ) ?? AttributedString(block.text)

        switch block.kind {
        case .heading(let level):
            Text(inline)
                .font(.supermuxChatHeading(level: level))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.top, block.index == 0 ? 0 : 4)
        case .paragraph:
            Text(inline)
                .font(.supermuxChatBody())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        case .bullet(let indent):
            listRow(marker: "•", inline: inline, indent: indent)
        case .ordered(let marker, let indent):
            listRow(marker: marker, inline: inline, indent: indent)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(theme.hairline)
                    .frame(width: 3)
                Text(inline)
                    .font(.supermuxChatBody())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
        }
    }

    private func listRow(marker: String, inline: AttributedString, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.supermuxChatBody())
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .trailing)
            Text(inline)
                .font(.supermuxChatBody())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(min(indent, 4)) * 14)
    }

    private func codeBlock(segment: ChatProseSegment, language: String?) -> some View {
        let lines = segment.content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let visible = lines.count > Self.codeLineCap
            ? lines.prefix(Self.codeLineCap).joined(separator: "\n")
            : segment.content

        return Button {
            onShowCodeDetail(messageID, segment.index)
        } label: {
            SupermuxChatCodeSurface {
                SupermuxChatCodeSurfaceHeader(title: languageTitle(language)) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                }
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(verbatim: visible.isEmpty ? " " : visible)
                            .font(.supermuxChatMono(size: 12))
                            .foregroundStyle(.primary.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                    if lines.count > Self.codeLineCap {
                        Text(moreLinesLabel(lines.count - Self.codeLineCap))
                            .font(.supermuxChatCaption())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SupermuxChatCodeBlock-\(messageID)-\(segment.index)")
        .accessibilityLabel(codeAccessibilityLabel(language))
        .accessibilityHint(SupermuxChatActivityRow.detailHint)
    }

    private func languageTitle(_ language: String?) -> String {
        guard let language, !language.isEmpty else {
            return String(
                localized: "supermux.chat.code",
                defaultValue: "Code",
                bundle: .module
            )
        }
        return language.uppercased()
    }

    private func codeAccessibilityLabel(_ language: String?) -> String {
        let base = String(
            localized: "supermux.chat.code.accessibility",
            defaultValue: "Code block",
            bundle: .module
        )
        guard let language, !language.isEmpty else { return base }
        return "\(language) \(base)"
    }

    private func moreLinesLabel(_ count: Int) -> String {
        String(
            localized: "supermux.chat.moreLines",
            defaultValue: "⋯ \(count) more lines",
            bundle: .module
        )
    }
}
