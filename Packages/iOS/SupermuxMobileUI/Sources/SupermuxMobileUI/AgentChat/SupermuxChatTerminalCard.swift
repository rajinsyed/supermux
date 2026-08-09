public import CmuxAgentChat
public import SwiftUI

/// A shell command and its captured output.
///
/// The header is the command itself in mono — not a humanized paraphrase —
/// because for a command the exact text *is* the information. Output collapses
/// head-and-tail so a 400-line build log still occupies a bounded, predictable
/// row height; the full text lives one tap away.
public struct SupermuxChatTerminalCard: View {
    private let capture: ChatTerminalCapture
    private let rowID: String
    private let outputLines: [String]
    private let onShowDetail: () -> Void

    @Environment(\.supermuxChatTheme) private var theme

    private static let collapseThreshold = 8
    private static let headCount = 5
    private static let tailCount = 2

    /// Creates a terminal card.
    ///
    /// - Parameters:
    ///   - capture: The command-and-output payload.
    ///   - rowID: Stable identity, for UI automation.
    ///   - outputLines: Pre-sanitized output lines (the caller owns caching).
    ///   - onShowDetail: Opens the full output.
    public init(
        capture: ChatTerminalCapture,
        rowID: String,
        outputLines: [String],
        onShowDetail: @escaping () -> Void = {}
    ) {
        self.capture = capture
        self.rowID = rowID
        self.outputLines = outputLines
        self.onShowDetail = onShowDetail
    }

    public var body: some View {
        Button(action: onShowDetail) {
            SupermuxChatCodeSurface {
                header
            } content: {
                if !outputLines.isEmpty {
                    Rectangle()
                        .fill(theme.hairline)
                        .frame(height: 0.5)
                    outputBlock
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SupermuxChatTerminal-\(rowID)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(SupermuxChatActivityRow.detailHint)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(capture.command)
                .font(.supermuxChatMono(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            status
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 20)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(minHeight: 34)
    }

    /// A failure earns a colored badge and its exit code; a success earns
    /// nothing but its duration. Nothing at all while running — the shimmer on
    /// the surrounding transcript already says the turn is live.
    @ViewBuilder
    private var status: some View {
        if !capture.isRunning {
            if let exitCode = capture.exitCode, exitCode != 0 {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                    Text(verbatim: "\(exitCode)")
                        .font(.supermuxChatMono(size: 11))
                }
                .foregroundStyle(theme.failure)
            }
            if let duration = capture.durationSeconds, duration >= 0.1 {
                Text(verbatim: String(format: "%.1fs", duration))
                    .font(.supermuxChatCaption())
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private var outputBlock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if outputLines.count > Self.collapseThreshold {
                    outputText(Array(outputLines.prefix(Self.headCount)))
                    Text(moreLinesLabel(
                        outputLines.count - Self.headCount - Self.tailCount
                    ))
                    .font(.supermuxChatCaption())
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 3)
                    outputText(Array(outputLines.suffix(Self.tailCount)))
                        .opacity(0.55)
                } else {
                    outputText(outputLines)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func outputText(_ lines: [String]) -> some View {
        Text(verbatim: lines.joined(separator: "\n"))
            .font(.supermuxChatMono(size: 11.5))
            .foregroundStyle(.primary.opacity(0.75))
            .lineLimit(nil)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func moreLinesLabel(_ count: Int) -> String {
        String(
            localized: "supermux.chat.moreLines",
            defaultValue: "⋯ \(count) more lines",
            bundle: .module
        )
    }

    private var accessibilityLabel: String {
        if capture.isRunning {
            return String(
                localized: "supermux.chat.terminal.running.accessibility",
                defaultValue: "Command \(capture.command), running",
                bundle: .module
            )
        }
        if let exitCode = capture.exitCode, exitCode != 0 {
            return String(
                localized: "supermux.chat.terminal.failed.accessibility",
                defaultValue: "Command \(capture.command), failed with exit code \(exitCode)",
                bundle: .module
            )
        }
        return String(
            localized: "supermux.chat.terminal.succeeded.accessibility",
            defaultValue: "Command \(capture.command), succeeded",
            bundle: .module
        )
    }
}
