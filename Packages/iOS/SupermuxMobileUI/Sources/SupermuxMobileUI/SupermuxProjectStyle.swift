public import Foundation
public import SwiftUI

/// One selectable accent color in the editors' palette.
public struct SupermuxProjectStyleColor: Identifiable, Equatable, Sendable {
    /// Localized name shown to VoiceOver and in accessibility labels.
    public let name: String
    /// Color as `#RRGGBB` — the exact value that travels in `color_hex`.
    public let hex: String

    public var id: String { hex }
}

/// The editors' style choices, mirroring the desktop pickers: the same
/// 12-color palette as `SupermuxProjectColor.palette` (SupermuxKit is a
/// Mac-only package, so the values are mirrored here and pinned by a test)
/// and a curated SF Symbol grid.
/// lint:allow namespace-type — stateless data table mirroring the desktop palette/symbol pickers (SupermuxKit is Mac-only), pinned by tests; nothing to instantiate.
public enum SupermuxProjectStyle {
    /// The 12-color accent palette, in the desktop's order.
    public static var colorPalette: [SupermuxProjectStyleColor] {
        [
            SupermuxProjectStyleColor(
                name: String(localized: "supermux.projectColor.red", defaultValue: "Red", bundle: .module),
                hex: "#ef4444"
            ),
            SupermuxProjectStyleColor(
                name: String(localized: "supermux.projectColor.orange", defaultValue: "Orange", bundle: .module),
                hex: "#f97316"
            ),
            SupermuxProjectStyleColor(
                name: String(localized: "supermux.projectColor.yellow", defaultValue: "Yellow", bundle: .module),
                hex: "#eab308"
            ),
            SupermuxProjectStyleColor(
                name: String(localized: "supermux.projectColor.lime", defaultValue: "Lime", bundle: .module),
                hex: "#84cc16"
            ),
            SupermuxProjectStyleColor(
                name: String(localized: "supermux.projectColor.green", defaultValue: "Green", bundle: .module),
                hex: "#22c55e"
            ),
            SupermuxProjectStyleColor(
                name: String(localized: "supermux.projectColor.teal", defaultValue: "Teal", bundle: .module),
                hex: "#14b8a6"
            ),
            SupermuxProjectStyleColor(
                name: String(localized: "supermux.projectColor.cyan", defaultValue: "Cyan", bundle: .module),
                hex: "#06b6d4"
            ),
            SupermuxProjectStyleColor(
                name: String(localized: "supermux.projectColor.blue", defaultValue: "Blue", bundle: .module),
                hex: "#3b82f6"
            ),
            SupermuxProjectStyleColor(
                name: String(localized: "supermux.projectColor.indigo", defaultValue: "Indigo", bundle: .module),
                hex: "#6366f1"
            ),
            SupermuxProjectStyleColor(
                name: String(localized: "supermux.projectColor.purple", defaultValue: "Purple", bundle: .module),
                hex: "#a855f7"
            ),
            SupermuxProjectStyleColor(
                name: String(localized: "supermux.projectColor.pink", defaultValue: "Pink", bundle: .module),
                hex: "#ec4899"
            ),
            SupermuxProjectStyleColor(
                name: String(localized: "supermux.projectColor.slate", defaultValue: "Slate", bundle: .module),
                hex: "#64748b"
            ),
        ]
    }

    /// The curated SF Symbol choices for project/preset avatars, roughly the
    /// glyphs projects pick on the desktop (which uses a free-text symbol
    /// field; the phone offers a tappable grid instead).
    public static let iconSymbols: [String] = [
        "folder", "terminal", "chevron.left.forwardslash.chevron.right",
        "curlybraces", "hammer", "wrench.and.screwdriver", "gearshape",
        "shippingbox", "cube", "globe", "server.rack", "desktopcomputer",
        "laptopcomputer", "iphone", "gamecontroller", "book", "doc.text",
        "sparkles", "bolt", "flame", "leaf", "star", "heart", "paperplane",
    ]

    /// The grid choices when the current selection is `symbol`: the curated
    /// list, plus the current symbol appended when it is not curated (e.g.
    /// set from the desktop's free-text field) so it stays visible and
    /// selectable rather than silently deselected.
    /// - Parameter symbol: The currently selected symbol, if any.
    public static func symbolChoices(including symbol: String?) -> [String] {
        guard let symbol, !symbol.isEmpty, !iconSymbols.contains(symbol) else {
            return iconSymbols
        }
        return iconSymbols + [symbol]
    }

    /// Parses `#RRGGBB` into a SwiftUI color; `nil` for malformed input.
    /// - Parameter hex: A `#RRGGBB` string.
    public static func color(fromHex hex: String?) -> Color? {
        guard let rgb = hex.flatMap(SupermuxAvatarRGB.init(hex:)) else { return nil }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// The shared color-palette row: a wrapping grid of the 12 accent swatches
/// plus a "No Color" slot, bound to the draft's `#RRGGBB` value.
struct SupermuxColorPaletteRow: View {
    @Binding var colorHex: String?

    private static let columns = [GridItem(.adaptive(minimum: 36), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "supermux.editor.color", defaultValue: "Color", bundle: .module))
            LazyVGrid(columns: Self.columns, spacing: 8) {
                swatch(
                    hex: nil,
                    label: String(localized: "supermux.editor.noColor", defaultValue: "No Color", bundle: .module)
                )
                ForEach(SupermuxProjectStyle.colorPalette) { entry in
                    swatch(hex: entry.hex, label: entry.name)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func swatch(hex: String?, label: String) -> some View {
        let isSelected = colorHex?.lowercased() == hex?.lowercased()
        return Button {
            colorHex = hex
        } label: {
            ZStack {
                if let fill = SupermuxProjectStyle.color(fromHex: hex) {
                    Circle().fill(fill)
                } else {
                    Image(systemName: "circle.slash")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .overlay {
                if isSelected {
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: 2)
                        .padding(-4)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The shared SF-symbol picker row: a wrapping grid of the curated glyphs
/// plus a "no symbol" slot (letter avatar / neutral chip), bound to the
/// draft's symbol name.
struct SupermuxIconSymbolPickerRow: View {
    @Binding var iconSymbol: String?

    private static let columns = [GridItem(.adaptive(minimum: 40), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "supermux.editor.icon", defaultValue: "Icon", bundle: .module))
            LazyVGrid(columns: Self.columns, spacing: 8) {
                slot(symbol: nil)
                ForEach(SupermuxProjectStyle.symbolChoices(including: iconSymbol), id: \.self) { symbol in
                    slot(symbol: symbol)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func slot(symbol: String?) -> some View {
        let isSelected = iconSymbol == symbol
        return Button {
            iconSymbol = symbol
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(isSelected ? 0.25 : 0.08))
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                } else {
                    Image(systemName: "textformat")
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol
            ?? String(localized: "supermux.editor.noIcon", defaultValue: "No icon (letter avatar)", bundle: .module))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
