import CryptoKit
import Foundation
import os

/// A project-shipped `config.json` declaring its worktree setup/teardown
/// scripts, run command, and custom actions.
///
/// Supermux reads it from `.supermux/config.json` (fork-native) or, for drop-in
/// compatibility with superset / piggycode repos, `.superset/config.json` at the
/// project root. Every field is optional so a partial file still loads; missing
/// arrays decode to empty.
///
/// ```json
/// {
///   "setup": ["bun install\ncp \"$SUPERSET_ROOT_PATH/.env\" .env"],
///   "teardown": ["./.superset/teardown.sh"],
///   "run": ["bun run dev"],
///   "actions": [{ "id": "…", "name": "Open GitHub", "command": "open …", "icon": "deploy" }]
/// }
/// ```
public struct SupermuxProjectConfig: Codable, Sendable, Equatable {
    /// Shell snippets run in a fresh worktree right after it is created.
    public var setup: [String]
    /// Shell snippets run in a worktree right before it is removed.
    public var teardown: [String]
    /// Shell commands for the project's run action (⌘G start/stop).
    public var run: [String]
    /// Named custom actions launchable from the project.
    public var actions: [Action]

    /// A custom action declared in `config.json`.
    public struct Action: Codable, Sendable, Equatable {
        /// Stable identity (a UUID string); a fresh one is synthesized when absent or unparsable.
        public var id: String?
        /// User-visible label.
        public var name: String
        /// Shell command to run.
        public var command: String
        /// Icon name — a superset glyph keyword (e.g. `bolt`, `build`, `deploy`) or an SF Symbol.
        public var icon: String?

        public init(id: String? = nil, name: String, command: String, icon: String? = nil) {
            self.id = id
            self.name = name
            self.command = command
            self.icon = icon
        }
    }

    public init(
        setup: [String] = [],
        teardown: [String] = [],
        run: [String] = [],
        actions: [Action] = []
    ) {
        self.setup = setup
        self.teardown = teardown
        self.run = run
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case setup, teardown, run, actions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        setup = try container.decodeIfPresent([String].self, forKey: .setup) ?? []
        teardown = try container.decodeIfPresent([String].self, forKey: .teardown) ?? []
        run = try container.decodeIfPresent([String].self, forKey: .run) ?? []
        actions = try container.decodeIfPresent([Action].self, forKey: .actions) ?? []
    }
}

/// Reads a project's `config.json` from disk.
///
/// Pure value type with a synchronous `load` so callers run it off the main
/// actor (e.g. `Task.detached`). Looks up the fork-native `.supermux/config.json`
/// first, then the superset-compatible `.superset/config.json`, returning the
/// first that parses — or `nil` when neither exists or both are malformed.
public struct SupermuxProjectConfigLoader: Sendable {
    /// Candidate config locations relative to the project root, in priority order.
    public static let candidateRelativePaths = [
        ".supermux/config.json",
        ".superset/config.json",
    ]

    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "supermux.config")

    public init() {}

    /// Loads the first readable, decodable config under `projectRoot`.
    ///
    /// A present-but-malformed file is logged and skipped (not silently
    /// ignored), so the model can fall back to the next candidate or to the
    /// project's existing values.
    /// - Parameter projectRoot: Absolute project root path.
    /// - Returns: The decoded config, or `nil` when none is present/valid.
    public func load(projectRoot: String) -> SupermuxProjectConfig? {
        let root = (projectRoot as NSString).expandingTildeInPath
        let decoder = JSONDecoder()
        for relative in Self.candidateRelativePaths {
            let path = (root as NSString).appendingPathComponent(relative)
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            do {
                return try decoder.decode(SupermuxProjectConfig.self, from: data)
            } catch {
                Self.logger.warning(
                    "ignoring malformed \(relative, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return nil
    }

    /// The relative path of the first config file that exists under
    /// `projectRoot` (whether or not it parses), for display in the editor.
    /// - Parameter projectRoot: Absolute project root path.
    /// - Returns: e.g. `".superset/config.json"`, or `nil` when none exists.
    public func resolvedRelativePath(projectRoot: String) -> String? {
        let root = (projectRoot as NSString).expandingTildeInPath
        return Self.candidateRelativePaths.first { relative in
            FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(relative))
        }
    }
}

public extension SupermuxProjectConfig {
    /// Maps a superset-style icon keyword to an SF Symbol. Unknown values pass
    /// through unchanged so a config that already uses a valid SF Symbol works,
    /// and `nil`/blank falls through to the action's neutral default.
    static func sfSymbol(forIcon icon: String?) -> String? {
        let trimmed = icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let map: [String: String] = [
            "bolt": "bolt",
            "build": "hammer",
            "deploy": "paperplane",
            "play": "play.fill",
            "stop": "stop.fill",
            "terminal": "terminal",
            "refresh": "arrow.clockwise",
            "update": "arrow.down.circle",
            "git": "arrow.triangle.branch",
            "github": "chevron.left.forward.slash.chevron.right",
            "open": "arrow.up.forward.app",
            "edit": "pencil",
            "test": "checkmark.circle",
            "package": "shippingbox",
            "cloud": "cloud",
        ]
        return map[trimmed.lowercased()] ?? trimmed
    }
}

public extension SupermuxProjectConfig.Action {
    /// Converts a config action into a launchable ``SupermuxProjectAction``.
    ///
    /// Identity is kept stable across re-imports — essential so importing an
    /// unchanged config never churns persistence: a valid UUID `id` is used as
    /// is; any other `id` (a slug) or a missing one derives a deterministic
    /// UUID (from the slug, else from name+command). Returns `nil` when the
    /// action has no usable name + command.
    func toProjectAction() -> SupermuxProjectAction? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedId: UUID
        if let raw = id?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            resolvedId = UUID(uuidString: raw) ?? SupermuxProjectConfig.stableUUID(from: "id:" + raw)
        } else {
            resolvedId = SupermuxProjectConfig.stableUUID(from: trimmedName + "\u{0}" + trimmedCommand)
        }
        let action = SupermuxProjectAction(
            id: resolvedId,
            name: trimmedName,
            command: trimmedCommand,
            iconSymbol: SupermuxProjectConfig.sfSymbol(forIcon: icon)
        )
        return action.isLaunchable ? action : nil
    }
}

public extension SupermuxProject {
    /// Returns a copy with the config-managed fields — setup, teardown, run, and
    /// actions — replaced by `config`. Other fields (name, color, icon, default
    /// branch, worktrees folder) are user-owned and untouched.
    ///
    /// `config.json` is treated as the source of truth for the four fields it
    /// declares, so importing it is a straight overwrite rather than a merge.
    /// - Parameter config: The decoded project config.
    /// - Returns: The project with config-managed fields applied.
    func applying(_ config: SupermuxProjectConfig) -> SupermuxProject {
        var copy = self
        copy.setupCommands = SupermuxProjectConfig.cleaned(config.setup)
        copy.teardownCommands = SupermuxProjectConfig.cleaned(config.teardown)
        copy.runCommands = SupermuxProjectConfig.cleaned(config.run)
        copy.actions = config.actions.compactMap { $0.toProjectAction() }
        return copy
    }
}

extension SupermuxProjectConfig {
    /// Trims whitespace off each entry and drops the empties.
    static func cleaned(_ commands: [String]) -> [String] {
        commands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Derives a stable UUID from a string by formatting an MD5 digest as a
    /// UUID. Deterministic (same input → same UUID) so config actions without a
    /// real UUID keep a fixed identity across re-imports. MD5 is used purely as
    /// a 128-bit hash here, not for security.
    static func stableUUID(from string: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let chars = Array(hex)
        let formatted = [
            String(chars[0..<8]),
            String(chars[8..<12]),
            String(chars[12..<16]),
            String(chars[16..<20]),
            String(chars[20..<32]),
        ].joined(separator: "-")
        return UUID(uuidString: formatted) ?? UUID()
    }
}
