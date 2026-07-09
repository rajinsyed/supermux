import Foundation

/// Why a user-typed entry name is unusable as a single path component.
/// The UI maps each case to a localized message; the store refuses to put
/// the name on the wire (the Mac re-validates regardless).
public enum SupermuxFileNameIssue: Equatable, Sendable {
    /// Empty, or whitespace only.
    case empty
    /// Contains a `/` (would traverse into a different directory).
    case containsSlash
    /// `.` or `..` (reserved path components).
    case reserved
}

/// Client-side validation for a single-component file/folder name, shared by
/// the file-browser store (wire guard) and the prompt UI (pre-flight),
/// mirroring the desktop `SupermuxFileSystemOperations` naming rules.
public enum SupermuxFileName {
    /// The name with surrounding whitespace trimmed — the exact form that
    /// travels on the wire.
    /// - Parameter name: The user-typed name.
    public static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first problem with the (normalized) name, or `nil` when usable.
    /// - Parameter name: The user-typed name.
    public static func issue(with name: String) -> SupermuxFileNameIssue? {
        let trimmed = normalized(name)
        if trimmed.isEmpty { return .empty }
        if trimmed.contains("/") { return .containsSlash }
        if trimmed == "." || trimmed == ".." { return .reserved }
        return nil
    }
}

/// Thrown by the file-browser store when a name fails ``SupermuxFileName``
/// validation — before any RPC is issued.
public struct SupermuxInvalidFileNameError: Error, Equatable, Sendable {
    /// What is wrong with the name.
    public let issue: SupermuxFileNameIssue
    /// The offending name, as typed.
    public let name: String

    /// Creates the error.
    /// - Parameters:
    ///   - issue: What is wrong with the name.
    ///   - name: The offending name, as typed.
    public init(issue: SupermuxFileNameIssue, name: String) {
        self.issue = issue
        self.name = name
    }
}
