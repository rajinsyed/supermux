import AppKit
import SupermuxKit
import SwiftUI

/// One card in the workspace switcher strip: a small preview thumbnail with the
/// workspace name and its branch shown directly beneath it — always visible, for
/// every workspace — and highlighted when selected.
///
/// Driven entirely by value inputs — never an observable store — so the strip
/// stays cheap to diff (snapshot-boundary rule).
struct SupermuxWorkspaceSwitcherCard: View {
    let item: SupermuxWorkspaceSwitcherItem
    let isSelected: Bool
    let preview: NSImage?
    let onTap: () -> Void

    private var accent: Color {
        SupermuxWorkspaceSwitcherStyle.color(fromHex: item.accentColorHex) ?? Color.accentColor
    }

    var body: some View {
        // A Button (not onTapGesture) so a click while ⌘ is held still commits.
        // Hover highlighting is driven by an AppKit tracking overlay on the row
        // (see `SupermuxPointerTrackingStrip`), not per-card `.onHover`.
        Button(action: onTap) {
            VStack(spacing: SupermuxWorkspaceSwitcherStyle.cardLabelGap) {
                thumbnail
                    .opacity(isSelected ? 1 : 0.55)
                label
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: isSelected)
    }

    /// The workspace name (primary) over its branch/subtitle (secondary), centered
    /// in a fixed-height box so every card aligns and the strip never jitters.
    private var label: some View {
        VStack(spacing: 1) {
            Text(item.title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .opacity(isSelected ? 1 : 0.7)
                .lineLimit(1)
                .truncationMode(.middle)
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .opacity(isSelected ? 1 : 0.7)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .multilineTextAlignment(.center)
        .frame(
            width: SupermuxWorkspaceSwitcherStyle.previewSize.width,
            height: SupermuxWorkspaceSwitcherStyle.cardLabelHeight,
            alignment: .top
        )
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SupermuxWorkspaceSwitcherStyle.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))

            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                fallbackContent
            }
        }
        .frame(
            width: SupermuxWorkspaceSwitcherStyle.previewSize.width,
            height: SupermuxWorkspaceSwitcherStyle.previewSize.height
        )
        .clipShape(RoundedRectangle(cornerRadius: SupermuxWorkspaceSwitcherStyle.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SupermuxWorkspaceSwitcherStyle.cardCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? accent : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: Color.black.opacity(isSelected ? 0.3 : 0), radius: isSelected ? 7 : 0, y: 3)
        .contentShape(Rectangle())
    }

    private var fallbackContent: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.85), accent.opacity(0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            avatar
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let symbol = item.iconSymbol, !symbol.isEmpty,
           NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            Image(systemName: symbol)
        } else {
            Text(item.monogram)
        }
    }
}
