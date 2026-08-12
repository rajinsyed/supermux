import SwiftUI
import CmuxFoundation

/// The user's prompt, as a trailing-aligned bubble.
struct SupermuxHarnessUserPromptRow: View {
    let rowID: String
    let text: String
    let theme: SupermuxHarnessTheme

    @Environment(\.supermuxHarnessMarkdownCache) private var cache

    var body: some View {
        HStack {
            Spacer(minLength: SupermuxHarnessTokens.spacing12 * 3)
            Text(attributed)
                .textSelection(.enabled)
                .cmuxFont(size: SupermuxHarnessTokens.body)
                .foregroundStyle(theme.text)
                .padding(.horizontal, SupermuxHarnessTokens.spacing10)
                .padding(.vertical, SupermuxHarnessTokens.spacing8)
                .background(
                    RoundedRectangle(
                        cornerRadius: SupermuxHarnessTokens.bubbleRadius, style: .continuous
                    )
                    .fill(theme.accentSoft)
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: SupermuxHarnessTokens.bubbleRadius, style: .continuous
                    )
                    .strokeBorder(theme.border, lineWidth: SupermuxHarnessTokens.hairline)
                )
        }
    }

    private var attributed: AttributedString {
        cache?.attributedText(rowID: rowID, markdown: text) ?? AttributedString(text)
    }
}

/// Assistant prose: markdown blocks plus fenced code blocks.
struct SupermuxHarnessAssistantProseRow: View {
    let rowID: String
    let text: String
    let isStreaming: Bool
    let theme: SupermuxHarnessTheme

    @Environment(\.supermuxHarnessMarkdownCache) private var cache

    var body: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing6) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .text:
                    proseBlocks(for: segment)
                case .code(let language):
                    SupermuxHarnessCodeBlock(
                        code: segment.content, language: language, theme: theme
                    )
                }
            }
            // A breathing caret while the block streams: the only always-on
            // liveness signal in the transcript body (there is no reveal
            // engine, so without it a slow token gap reads as a dead panel).
            if isStreaming {
                SupermuxHarnessStreamingCaret(theme: theme)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func proseBlocks(for segment: SupermuxProseSegment) -> some View {
        let blockID = "\(rowID)-\(segment.index)"
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing4) {
            ForEach(blocks(for: segment, blockID: blockID)) { block in
                SupermuxHarnessTextBlockView(
                    rowID: "\(blockID)-\(block.index)",
                    block: block,
                    theme: theme
                )
            }
        }
    }

    private var segments: [SupermuxProseSegment] {
        cache?.proseSegments(rowID: rowID, text: text)
            ?? SupermuxProseSegmenter().segments(from: text)
    }

    private func blocks(
        for segment: SupermuxProseSegment, blockID: String
    ) -> [SupermuxTextBlock] {
        cache?.textBlocks(rowID: blockID, text: segment.content)
            ?? SupermuxTextBlockParser().blocks(from: segment.content)
    }
}

/// A small pulsing block cursor shown at the tail of a streaming prose row.
/// Static under Reduce Motion (it still marks the streaming position).
struct SupermuxHarnessStreamingCaret: View {
    let theme: SupermuxHarnessTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(theme.accent)
            .frame(width: 7, height: 14)
            .opacity(isDimmed && !reduceMotion ? 0.25 : 0.9)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isDimmed = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// One block-level prose element with its heading/list/quote styling.
struct SupermuxHarnessTextBlockView: View {
    let rowID: String
    let block: SupermuxTextBlock
    let theme: SupermuxHarnessTheme

    @Environment(\.supermuxHarnessMarkdownCache) private var cache

    var body: some View {
        switch block.kind {
        case .rule:
            Rectangle()
                .fill(theme.border)
                .frame(height: SupermuxHarnessTokens.hairline)
                .padding(.vertical, SupermuxHarnessTokens.spacing4)
        case .heading(let level):
            text
                .cmuxFont(
                    size: headingSize(level: level),
                    weight: level <= 2 ? .semibold : .medium
                )
                .foregroundStyle(theme.text)
                .padding(.top, SupermuxHarnessTokens.spacing4)
        case .paragraph:
            text
                .cmuxFont(size: SupermuxHarnessTokens.body)
                .foregroundStyle(theme.text)
        case .quote:
            HStack(alignment: .top, spacing: SupermuxHarnessTokens.spacing6) {
                Rectangle()
                    .fill(theme.border)
                    .frame(width: 2)
                text
                    .cmuxFont(size: SupermuxHarnessTokens.body)
                    .foregroundStyle(theme.softText)
            }
        case .bullet(let indent):
            listRow(marker: "•", indent: indent)
        case .ordered(let marker, let indent):
            listRow(marker: marker, indent: indent)
        }
    }

    private func listRow(marker: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SupermuxHarnessTokens.spacing6) {
            Text(marker)
                .cmuxFont(size: SupermuxHarnessTokens.body, monospacedDigit: true)
                .foregroundStyle(theme.mutedText)
            text
                .cmuxFont(size: SupermuxHarnessTokens.body)
                .foregroundStyle(theme.text)
        }
        .padding(.leading, CGFloat(indent) * SupermuxHarnessTokens.spacing12)
    }

    private var text: Text {
        Text(cache?.attributedText(rowID: rowID, markdown: block.text)
            ?? AttributedString(block.text))
    }

    private func headingSize(level: Int) -> CGFloat {
        switch level {
        case 1: return SupermuxHarnessTokens.title3
        case 2: return SupermuxHarnessTokens.headline
        default: return SupermuxHarnessTokens.body
        }
    }
}

/// A fenced code block, rendered as a screen rather than as bubble text.
struct SupermuxHarnessCodeBlock: View {
    let code: String
    let language: String?
    let theme: SupermuxHarnessTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .cmuxFont(size: SupermuxHarnessTokens.caption2, design: .monospaced)
                    .foregroundStyle(theme.mutedText)
                    .padding(.horizontal, SupermuxHarnessTokens.spacing8)
                    .padding(.top, SupermuxHarnessTokens.spacing4)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .cmuxFont(size: SupermuxHarnessTokens.footnote, design: .monospaced)
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .padding(SupermuxHarnessTokens.spacing8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: SupermuxHarnessTokens.fileBoxRadius, style: .continuous
            )
            .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: SupermuxHarnessTokens.fileBoxRadius, style: .continuous
            )
            .strokeBorder(theme.border, lineWidth: SupermuxHarnessTokens.hairline)
        )
    }
}
