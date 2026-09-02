public import Foundation

/// Persists the user's Claude launch commands and the last model/effort used
/// with each, for the "start Claude in a new worktree" flow.
///
/// A *command* is whatever the user types in their shell to start Claude —
/// the real binary (`claude`), an alias (`cc` → `claude --dangerously-skip-
/// permissions`), or a wrapper script (`ccx`, which points Claude at a proxy
/// with a different model catalog). Commands run through the interactive
/// login shell (see ``SupermuxCommandLaunch``), so aliases and functions
/// resolve exactly as they do at the prompt.
///
/// Isolation: a stateless value over an immutable `UserDefaults` reference,
/// whose API is documented thread-safe.
public struct SupermuxAgentLauncherSettings: Sendable {
    static let commandsKey = "supermux.agentLauncher.commands"
    static let selectedCommandKey = "supermux.agentLauncher.selectedCommand"
    static let lastModelKeyPrefix = "supermux.agentLauncher.lastModel."
    static let lastEffortKeyPrefix = "supermux.agentLauncher.lastEffort."

    /// The command list a fresh install starts with.
    public static let defaultCommands = ["claude"]

    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates the settings over a defaults suite.
    /// - Parameter defaults: The suite to persist into (injectable for tests).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The configured commands, in display order; never empty.
    public var commands: [String] {
        let stored = defaults.stringArray(forKey: Self.commandsKey) ?? []
        let normalized = Self.normalized(stored)
        return normalized.isEmpty ? Self.defaultCommands : normalized
    }

    /// Replaces the command list. Blank entries and duplicates are dropped;
    /// an empty result resets to ``defaultCommands``. The selection is kept
    /// when it survives, otherwise it moves to the first command.
    public func setCommands(_ commands: [String]) {
        let normalized = Self.normalized(commands)
        if normalized.isEmpty {
            defaults.removeObject(forKey: Self.commandsKey)
        } else {
            defaults.set(normalized, forKey: Self.commandsKey)
        }
        // Compare the STORED pick, not `selectedCommand` (which has already
        // fallen back to the first command), so a removed selection is
        // forgotten instead of resurfacing when the command is re-added.
        if let stored = defaults.string(forKey: Self.selectedCommandKey),
           !self.commands.contains(stored) {
            defaults.removeObject(forKey: Self.selectedCommandKey)
        }
    }

    /// The command new launches default to: the remembered pick when it is
    /// still configured, else the first command.
    public var selectedCommand: String {
        let commands = self.commands
        if let stored = defaults.string(forKey: Self.selectedCommandKey),
           commands.contains(stored) {
            return stored
        }
        return commands[0]
    }

    /// Remembers the command to default to next time. Unknown commands are
    /// ignored so the selection can never point outside ``commands``.
    public func setSelectedCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commands.contains(trimmed) else { return }
        defaults.set(trimmed, forKey: Self.selectedCommandKey)
    }

    /// The model and effort last launched with `command`, when recorded.
    ///
    /// Kept per command on purpose: `ccx` exposes a different catalog than
    /// `claude`, so one shared "last model" would name a selector the other
    /// binary rejects.
    public func lastChoice(for command: String) -> (model: String?, effort: String?) {
        let model = defaults.string(forKey: Self.lastModelKeyPrefix + command)
        let effort = defaults.string(forKey: Self.lastEffortKeyPrefix + command)
        return (model?.isEmpty == false ? model : nil, effort?.isEmpty == false ? effort : nil)
    }

    /// Records the model/effort a launch actually used with `command`. A
    /// `nil` value clears the corresponding memory (the CLI default was used).
    public func recordChoice(command: String, model: String?, effort: String?) {
        set(model, forKey: Self.lastModelKeyPrefix + command)
        set(effort, forKey: Self.lastEffortKeyPrefix + command)
    }

    private func set(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Trims, drops blanks, and removes duplicates while preserving order.
    static func normalized(_ commands: [String]) -> [String] {
        var seen: Set<String> = []
        return commands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
