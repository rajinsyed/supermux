public import CmuxAgentChat
public import SwiftUI

/// A file change: a "File changes" header with counts, then the diff.
///
/// The header stays readable even when the diff is absent or truncated, so a
/// `Write` with no computable diff still renders as a real, tappable row
/// rather than a bare line of text.
public struct SupermuxChatFileEditCard: View {
    private let edit: ChatFileEdit
    private let rowID: String
    private let diffLines: [String]
    private let onShowDetail: () -> Void

    @Environment(\.supermuxChatTheme) private var theme

    /// How many diff lines render inline before the card defers to the sheet.
    private static let collapsedLineCap = 10

    /// Creates a file-edit card.
    ///
    /// - Parameters:
    ///   - edit: The file modification payload.
    ///   - rowID: Stable identity, for UI automation.
    ///   - diffLines: Pre-split diff lines (the caller owns caching).
    ///   - onShowDetail: Opens the full diff.
    public init(
        edit: ChatFileEdit,
        rowID: String,
        diffLines: [String],
        onShowDetail: @escaping () -> Void = {}
    ) {
        self.edit = edit
        self.rowID = rowID
        self.diffLines = diffLines
        self.onShowDetail = onShowDetail
    }

    public var body: some View {
        Button(action: onShowDetail) {
            SupermuxChatCodeSurface {
                SupermuxChatCodeSurfaceHeader(title: fileName) {
                    SupermuxChatDiffCounts(
                        additions: edit.additions,
                        deletions: edit.deletions
                    )
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                }
            } content: {
                if !visibleLines.isEmpty {
                    Rectangle()
                        .fill(theme.hairline)
                        .frame(height: 0.5)
                    diffBlock
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SupermuxChatFileEdit-\(rowID)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(SupermuxChatActivityRow.detailHint)
    }

    /// The last two path components: enough to identify the file, short
    /// enough to fit beside the counts on a phone.
    private var fileName: String {
        let components = edit.filePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 2 else { return edit.filePath }
        return components.suffix(2).joined(separator: "/")
    }

    private var visibleLines: [String] {
        Array(diffLines.prefix(Self.collapsedLineCap))
    }

    private var diffBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                        diffLine(line)
                    }
                }
                .padding(.vertical, 6)
            }
            if diffLines.count > Self.collapsedLineCap {
                Text(moreLinesLabel(diffLines.count - Self.collapsedLineCap))
                    .font(.supermuxChatCaption())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    private func diffLine(_ line: String) -> some View {
        Text(verbatim: line.isEmpty ? " " : line)
            .font(.supermuxChatMono(size: 11.5))
            .foregroundStyle(foreground(for: line))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(for: line))
            // VoiceOver cannot see the +/− tint, so name the change kind.
            .accessibilityLabel(diffLineAccessibilityLabel(line))
    }

    private func foreground(for line: String) -> Color {
        if line.hasPrefix("@@") { return .secondary }
        if line.hasPrefix("+") { return theme.diffAdded }
        if line.hasPrefix("-") { return theme.diffRemoved }
        return .primary.opacity(0.75)
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("@@") { return .clear }
        if line.hasPrefix("+") { return theme.diffAdded.opacity(0.10) }
        if line.hasPrefix("-") { return theme.diffRemoved.opacity(0.10) }
        return .clear
    }

    private func diffLineAccessibilityLabel(_ line: String) -> String {
        if line.hasPrefix("+") {
            return String(
                localized: "supermux.chat.diff.added.accessibility",
                defaultValue: "Added: \(String(line.dropFirst()))",
                bundle: .module
            )
        }
        if line.hasPrefix("-") {
            return String(
                localized: "supermux.chat.diff.removed.accessibility",
                defaultValue: "Removed: \(String(line.dropFirst()))",
                bundle: .module
            )
        }
        return line
    }

    private func moreLinesLabel(_ count: Int) -> String {
        String(
            localized: "supermux.chat.moreLines",
            defaultValue: "⋯ \(count) more lines",
            bundle: .module
        )
    }

    private var accessibilityLabel: String {
        var parts = ["\(operationLabel) \(edit.filePath)"]
        if let additions = edit.additions, additions > 0 {
            parts.append(String(
                localized: "supermux.chat.diff.additions.accessibility",
                defaultValue: "\(additions) added",
                bundle: .module
            ))
        }
        if let deletions = edit.deletions, deletions > 0 {
            parts.append(String(
                localized: "supermux.chat.diff.deletions.accessibility",
                defaultValue: "\(deletions) removed",
                bundle: .module
            ))
        }
        return parts.joined(separator: ", ")
    }

    private var operationLabel: String {
        switch edit.operation {
        case .edit:
            return String(
                localized: "supermux.chat.fileEdit.edit",
                defaultValue: "Edited",
                bundle: .module
            )
        case .write:
            return String(
                localized: "supermux.chat.fileEdit.write",
                defaultValue: "Wrote",
                bundle: .module
            )
        case .delete:
            return String(
                localized: "supermux.chat.fileEdit.delete",
                defaultValue: "Deleted",
                bundle: .module
            )
        }
    }
}
