import Foundation

/// The executable identity used to start Claude Code for one session.
///
/// The launcher is resolved once at session creation and persisted; resume
/// always reuses the same record (never silently falls back to plain claude).
public struct ClaudeLauncher: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case claude
        case ccx
        case custom
    }

    public let kind: Kind
    /// The canonical absolute executable path.
    public let executablePath: String
    public let displayName: String

    public init(kind: Kind, executablePath: String, displayName: String) {
        self.kind = kind
        self.executablePath = executablePath
        self.displayName = displayName
    }

    /// Whether the harness itself must pass `--dangerously-skip-permissions`.
    ///
    /// Permissions are always skipped in this harness. Plain claude and custom
    /// launchers get the flag from us; ccx already injects it, so passing it
    /// again is redundant and kept out of the argument list.
    public var addsSkipPermissionsFlag: Bool {
        switch kind {
        case .claude, .custom: return true
        case .ccx: return false
        }
    }
}
