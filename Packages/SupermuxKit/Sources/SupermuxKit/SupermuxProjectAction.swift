public import Foundation

/// A named, launchable command attached to a project.
///
/// Covers both piggycode "custom app actions" (e.g. "Open in Editor" →
/// `cursor .`) and "terminal presets" (e.g. "Dev server" → `npm run dev`):
/// each is a label plus a shell command run in a fresh workspace terminal at
/// the project (or worktree) directory. The run action behind ⌘G stays
/// separate — it is the project's primary start/stop command.
public struct SupermuxProjectAction: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity, preserved across edits and app restarts.
    public let id: UUID
    /// User-visible label shown in menus.
    public var name: String
    /// Shell command executed when the action is launched.
    public var command: String
    /// SF Symbol shown next to the action, or `nil` for a default glyph.
    public var iconSymbol: String?

    /// Creates an action.
    /// - Parameters:
    ///   - id: Stable identity; defaults to a fresh UUID.
    ///   - name: Display label.
    ///   - command: Shell command to run.
    ///   - iconSymbol: Optional SF Symbol name.
    public init(id: UUID = UUID(), name: String, command: String, iconSymbol: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.iconSymbol = iconSymbol
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, iconSymbol
    }

    /// Decodes an action, synthesizing a fresh ``id`` when an older record
    /// omits it and defaulting `iconSymbol` to `nil`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        iconSymbol = try container.decodeIfPresent(String.self, forKey: .iconSymbol)
    }

    /// Whether the action has a non-empty name and command (safe to launch).
    public var isLaunchable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The SF Symbol to display, falling back to a neutral default.
    public var resolvedIconSymbol: String {
        let trimmed = iconSymbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "bolt" : trimmed
    }
}
