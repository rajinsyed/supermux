import SwiftUI

/// A nested sidebar row's status pills and progress bar, under its title: the
/// compact form of the lines a flat row draws for `cmux set-status` and
/// `cmux set-progress`. At most three pills show; the tooltip lists all.
struct SupermuxRowStatusLines: View {
    let pills: [SupermuxRowStatusPill]
    let progress: SupermuxRowProgress?
    let fontScale: CGFloat

    private static let visiblePillLimit = 3

    var body: some View {
        if !pills.isEmpty || progress != nil {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(pills.prefix(Self.visiblePillLimit)) { pill in
                    SupermuxRowStatusPillLine(pill: pill, fontScale: fontScale)
                }
                if let progress {
                    SupermuxRowProgressBar(progress: progress, fontScale: fontScale)
                }
            }
            .padding(.top, 1)
            .help(pills.map(\.text).joined(separator: "\n"))
        }
    }
}

/// One pill: its icon and text, in its color when it has one.
private struct SupermuxRowStatusPillLine: View {
    let pill: SupermuxRowStatusPill
    let fontScale: CGFloat

    var body: some View {
        HStack(spacing: 3 * fontScale) {
            icon
            text
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 9.5 * fontScale))
        .foregroundStyle(SupermuxProjectColor.color(fromHex: pill.colorHex) ?? .secondary)
    }

    @ViewBuilder
    private var icon: some View {
        let raw = pill.icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.hasPrefix("emoji:"), raw.count > 6 {
            Text(String(raw.dropFirst(6))).font(.system(size: 8.5 * fontScale))
        } else if raw.hasPrefix("text:"), raw.count > 5 {
            Text(String(raw.dropFirst(5))).font(.system(size: 7.5 * fontScale, weight: .semibold))
        } else if !raw.isEmpty {
            Image(systemName: raw.hasPrefix("sf:") ? String(raw.dropFirst(3)) : raw)
                .font(.system(size: 7.5 * fontScale, weight: .medium))
        }
    }

    private var text: Text {
        if pill.isMarkdown,
           let attributed = try? AttributedString(
               markdown: pill.text,
               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            return Text(attributed)
        }
        return Text(pill.text)
    }
}

/// The thin progress bar, with its label under it.
private struct SupermuxRowProgressBar: View {
    let progress: SupermuxRowProgress
    let fontScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(Color.accentColor)
                    .scaleEffect(x: CGFloat(max(0, min(progress.value, 1))), y: 1, anchor: .leading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: max(2, 2.5 * fontScale))
            if let label = progress.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 8.5 * fontScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
