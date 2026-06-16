import AppKit
import SupermuxKit
import SwiftUI

/// One card in the workspace switcher strip: a faithful "mini terminal" of the
/// workspace's live viewport text (or a metadata fallback when there's no terminal
/// content), with the workspace name and its branch shown directly beneath it —
/// always visible, for every workspace — and highlighted when selected.
///
/// The preview is TEXT, not a screenshot: background workspaces stop rendering, so
/// their GPU surface is stale, but libghostty keeps the text grid current.
///
/// Driven entirely by value inputs — never an observable store — so the strip
/// stays cheap to diff (snapshot-boundary rule).
struct SupermuxWorkspaceSwitcherCard: View {
    let item: SupermuxWorkspaceSwitcherItem
    let isSelected: Bool
    /// The owning project's resolved avatar image (custom/auto-detected logo),
    /// supplied from the view-owned icon store; `nil` falls back to the project's
    /// SF Symbol or letter via ``SupermuxProjectAvatarView``.
    let projectIcon: NSImage?
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
            if item.previewLines.isEmpty {
                fallbackContent
            } else {
                terminalPreview
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
        .overlay(alignment: .topLeading) { projectBadge.padding(4) }
        .overlay(alignment: .topTrailing) { activityBadge.padding(4) }
        .shadow(color: Color.black.opacity(isSelected ? 0.3 : 0), radius: isSelected ? 7 : 0, y: 3)
        .contentShape(Rectangle())
    }

    /// The workspace's agent-activity status in the top-right corner — the amber
    /// spinner (working), red dot (needs input), or green dot (ready) the rest of
    /// the app uses — so you can tell at a glance what each workspace is doing.
    /// Nothing is shown when idle. On a subtle dark backing for legibility.
    @ViewBuilder
    private var activityBadge: some View {
        if item.activity.isVisible {
            SupermuxAgentActivityIndicator(activity: item.activity, size: 9)
                .padding(4)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 2, y: 1)
        }
    }

    /// The owning project's avatar in the card's top-left corner, on a subtle dark
    /// backing so it stays legible over the terminal preview. Reuses the app's
    /// canonical ``SupermuxProjectAvatarView`` (logo image, else SF Symbol, else
    /// letter — tinted with the project color). Hidden for standalone workspaces.
    @ViewBuilder
    private var projectBadge: some View {
        if let project = item.project {
            SupermuxProjectAvatarView(project: project, detectedIcon: projectIcon, size: 16)
                .padding(2)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 2, y: 1)
        }
    }

    /// A miniature terminal: the workspace's recent viewport lines in a small
    /// monospaced font on a dark panel, anchored to the bottom (prompt-last) with a
    /// soft top fade on the text so it reads as a shrunken terminal, not a text
    /// receipt.
    private var terminalPreview: some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.10)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(item.previewLines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 7, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .mask(
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.32)
                )
            )
        }
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
