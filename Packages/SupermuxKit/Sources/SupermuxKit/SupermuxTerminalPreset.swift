public import Foundation

/// A one-click launcher shown in the supermux terminal presets bar.
///
/// Mirrors piggycode's terminal presets: a named shell command (typically an
/// AI coding agent like `claude` or `codex`) that, when clicked, opens a fresh
/// terminal tab in the focused pane and runs the command there. Presets are
/// global — the same set appears in every workspace's bar — and are persisted
/// alongside projects in ``SupermuxProjectsFile``.
///
/// This is intentionally separate from ``SupermuxProjectAction`` (per-project,
/// opens a new *workspace*) so the two can evolve independently.
public struct SupermuxTerminalPreset: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity, preserved across edits and app restarts.
    public let id: UUID
    /// User-visible label shown on the bar chip (e.g. "claude").
    public var name: String
    /// Shell command run in a new terminal tab when the chip is clicked.
    public var command: String
    /// SF Symbol shown on the chip, or `nil` for a neutral default.
    public var iconSymbol: String?
    /// Accent color as `#RRGGBB`, or `nil` for the neutral chip style.
    public var colorHex: String?

    /// Creates a preset.
    /// - Parameters:
    ///   - id: Stable identity; defaults to a fresh UUID.
    ///   - name: Display label.
    ///   - command: Shell command to run in a new terminal tab.
    ///   - iconSymbol: Optional SF Symbol name.
    ///   - colorHex: Optional `#RRGGBB` accent.
    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        iconSymbol: String? = nil,
        colorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.iconSymbol = iconSymbol
        self.colorHex = colorHex
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, iconSymbol, colorHex
    }

    /// Decodes a preset, synthesizing a fresh ``id`` when an older record omits
    /// it and defaulting the optional fields to `nil`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        iconSymbol = try container.decodeIfPresent(String.self, forKey: .iconSymbol)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
    }

    /// Whether the preset has a non-empty name and command (safe to launch).
    public var isLaunchable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The SF Symbol to display, falling back to a neutral terminal glyph.
    public var resolvedIconSymbol: String {
        let trimmed = iconSymbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "terminal" : trimmed
    }

    /// The presets seeded on first launch, mirroring the common agent set.
    ///
    /// These are plain defaults: the user renames, recolors, reorders, removes,
    /// or adds presets freely, and the customized set is what persists.
    public static let defaults: [SupermuxTerminalPreset] = [
        SupermuxTerminalPreset(name: "claude", command: "claude", iconSymbol: "sparkle", colorHex: "#f97316"),
        SupermuxTerminalPreset(name: "codex", command: "codex", iconSymbol: "chevron.left.forward.slash.chevron.right", colorHex: "#64748b"),
        SupermuxTerminalPreset(name: "gemini", command: "gemini", iconSymbol: "sparkles", colorHex: "#3b82f6"),
        SupermuxTerminalPreset(name: "droid", command: "droid", iconSymbol: "wrench.and.screwdriver", colorHex: "#14b8a6"),
        SupermuxTerminalPreset(name: "cursor", command: "cursor-agent", iconSymbol: "cursorarrow", colorHex: "#a855f7"),
    ]
}
