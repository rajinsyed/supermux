import SwiftUI
import CmuxFoundation
import SupermuxClaudeHarness

/// A unified diff produced by an Edit/Write/MultiEdit tool call.
///
/// Layout ported from remodex's `UnifiedDiffView`: per-hunk sections with a
/// numbered gutter, full-row tints, and collapsible hunks. Long lines scroll
/// inside the card so the transcript column never widens.
struct SupermuxHarnessDiffCard: View {
    let diff: SupermuxHarnessDiff
    let filePath: String?
    let theme: SupermuxHarnessTheme

    @State private var collapsedHunkIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(diff.hunks.enumerated()), id: \.element.id) { index, hunk in
                if index > 0 {
                    Rectangle()
                        .fill(theme.border)
                        .frame(height: SupermuxHarnessTokens.hairline)
                }
                hunkSection(hunk)
            }
        }
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
        .clipShape(
            RoundedRectangle(
                cornerRadius: SupermuxHarnessTokens.fileBoxRadius, style: .continuous
            )
        )
    }

    private var header: some View {
        HStack(spacing: SupermuxHarnessTokens.spacing6) {
            if let filePath {
                Text((filePath as NSString).lastPathComponent)
                    .cmuxFont(size: SupermuxHarnessTokens.footnote, weight: .medium, design: .monospaced)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: SupermuxHarnessTokens.spacing4)
            Text("+\(diff.additions)")
                .cmuxFont(size: SupermuxHarnessTokens.caption, monospacedDigit: true)
                .foregroundStyle(SupermuxHarnessDiffPalette.additionForeground(isDark: theme.isDark))
            Text("−\(diff.deletions)")
                .cmuxFont(size: SupermuxHarnessTokens.caption, monospacedDigit: true)
                .foregroundStyle(SupermuxHarnessDiffPalette.deletionForeground(isDark: theme.isDark))
        }
        .padding(.horizontal, SupermuxHarnessTokens.spacing8)
        .padding(.vertical, SupermuxHarnessTokens.spacing6)
    }

    @ViewBuilder
    private func hunkSection(_ hunk: SupermuxHarnessDiff.Hunk) -> some View {
        let isCollapsed = collapsedHunkIDs.contains(hunk.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : SupermuxHarnessTokens.disclosure) {
                    if isCollapsed {
                        collapsedHunkIDs.remove(hunk.id)
                    } else {
                        collapsedHunkIDs.insert(hunk.id)
                    }
                }
            } label: {
                HStack(spacing: SupermuxHarnessTokens.spacing4) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: SupermuxHarnessTokens.caption2))
                    Text(rangeLabel(hunk))
                        .cmuxFont(size: SupermuxHarnessTokens.caption2, monospacedDigit: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.mutedText)
                .padding(.horizontal, SupermuxHarnessTokens.spacing8)
                .padding(.vertical, SupermuxHarnessTokens.spacing4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                // Rows wrap rather than scroll (remodex's `.fixedSize` choice):
                // one horizontal scroller per hunk would let hunks pan
                // independently and lose column alignment with each other.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hunk.lines) { line in
                        diffRow(line, gutterWidth: gutterWidth(hunk))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Single-column gutter (remodex's deliberate collapse of old/new columns:
    /// two columns render as a redundant "1 1 / 2 2 / 3 3" ladder). Additions
    /// show the new number, deletions the old, context whichever exists.
    private func diffRow(
        _ line: SupermuxHarnessDiff.Line, gutterWidth: CGFloat
    ) -> some View {
        let palette = palette(for: line.kind)
        return HStack(alignment: .top, spacing: 0) {
            Text(gutterLabel(for: line))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, SupermuxHarnessTokens.spacing4)
                .background(palette.gutterBackground)
                .foregroundStyle(palette.gutterForeground)
            Text(marker(for: line.kind) + line.text)
                .padding(.leading, SupermuxHarnessTokens.spacing4)
                .foregroundStyle(theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cmuxFont(size: SupermuxHarnessTokens.caption, design: .monospaced, monospacedDigit: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.rowBackground)
    }

    private func gutterLabel(for line: SupermuxHarnessDiff.Line) -> String {
        switch line.kind {
        case .addition:
            return line.newNumber.map(String.init) ?? "+"
        case .deletion:
            return line.oldNumber.map(String.init) ?? "-"
        case .context:
            if let new = line.newNumber { return String(new) }
            if let old = line.oldNumber { return String(old) }
            return ""
        }
    }

    private func palette(
        for kind: SupermuxHarnessDiff.Line.Kind
    ) -> SupermuxHarnessDiffPalette.RowPalette {
        switch kind {
        case .addition: return SupermuxHarnessDiffPalette.addition(isDark: theme.isDark)
        case .deletion: return SupermuxHarnessDiffPalette.deletion(isDark: theme.isDark)
        case .context: return SupermuxHarnessDiffPalette.context(theme: theme)
        }
    }

    private func marker(for kind: SupermuxHarnessDiff.Line.Kind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }

    /// Sized off the widest line number so the two gutters stay aligned.
    private func gutterWidth(_ hunk: SupermuxHarnessDiff.Hunk) -> CGFloat {
        let widest = hunk.lines.reduce(1) { partial, line in
            max(partial, max(line.oldNumber ?? 0, line.newNumber ?? 0))
        }
        let digits = max(2, String(widest).count)
        return CGFloat(digits) * 7 + SupermuxHarnessTokens.spacing6
    }

    private func rangeLabel(_ hunk: SupermuxHarnessDiff.Hunk) -> String {
        let numbers = hunk.lines.compactMap(\.newNumber)
        guard let first = numbers.first, let last = numbers.last else {
            return String(
                localized: "supermux.harness.diff.patch",
                defaultValue: "Patch"
            )
        }
        if first == last {
            return String(
                format: String(
                    localized: "supermux.harness.diff.line",
                    defaultValue: "Line %lld"
                ),
                Int64(first)
            )
        }
        return String(
            format: String(
                localized: "supermux.harness.diff.lines",
                defaultValue: "Lines %lld–%lld"
            ),
            Int64(first),
            Int64(last)
        )
    }
}
