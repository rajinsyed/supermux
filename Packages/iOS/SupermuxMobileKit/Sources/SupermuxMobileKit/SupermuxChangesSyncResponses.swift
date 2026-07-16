public import Foundation
public import SupermuxMobileCore

/// Typed result values for the `mobile.supermux.changes.*` commit/sync/
/// history methods (m3-f2's wire shapes). Every field is optional so old
/// peers tolerate additions.

/// Result of `mobile.supermux.changes.commit`: `{sha}`.
public struct SupermuxChangesCommitResponse: Codable, Sendable, Equatable {
    /// The new HEAD commit's full sha.
    public var sha: String?

    /// Creates the response (used by tests and fakes).
    /// - Parameter sha: Optional full commit sha.
    public init(sha: String? = nil) {
        self.sha = sha
    }
}

/// Result of `mobile.supermux.changes.generate_commit_message`: `{message}`.
public struct SupermuxChangesGeneratedMessageResponse: Codable, Sendable, Equatable {
    /// The Mac-generated commit message.
    public var message: String?

    /// Creates the response (used by tests and fakes).
    /// - Parameter message: Optional generated message.
    public init(message: String? = nil) {
        self.message = message
    }
}

/// Result of `changes.push`/`changes.pull`/`changes.stash`/`stash_pop`:
/// `{ok, log_lines, log_truncated?}`.
///
/// `log_lines` is raw git output (stdout then stderr, capped Mac-side at 100
/// lines / 500 chars per line); `log_truncated` travels only when the cap
/// hit, as a boolean flag so no marker text needs localization.
public struct SupermuxChangesSyncResponse: Codable, Sendable, Equatable {
    /// Whether the operation succeeded (failures arrive as RPC errors, so
    /// this is `true` on the happy path).
    public var ok: Bool?
    /// Raw git output lines for the result sheet.
    public var logLines: [String]?
    /// Present (`true`) only when the Mac capped the log.
    public var logTruncated: Bool?

    /// Creates the response (used by tests and fakes).
    /// - Parameters:
    ///   - ok: Optional success flag.
    ///   - logLines: Optional raw git output lines.
    ///   - logTruncated: Optional truncation flag.
    public init(ok: Bool? = nil, logLines: [String]? = nil, logTruncated: Bool? = nil) {
        self.ok = ok
        self.logLines = logLines
        self.logTruncated = logTruncated
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case logLines = "log_lines"
        case logTruncated = "log_truncated"
    }
}

/// Result of `mobile.supermux.changes.history`:
/// `{commits, incoming, next_cursor?}`.
public struct SupermuxChangesHistoryResponse: Codable, Sendable, Equatable {
    /// The page's local commits, newest first.
    public var commits: [SupermuxCommitDTO]?
    /// Upstream commits not yet pulled (`HEAD..@{upstream}`); rides the
    /// FIRST page only.
    public var incoming: [SupermuxCommitDTO]?
    /// Pass back verbatim to fetch the next page; absent on the last page.
    public var nextCursor: String?

    /// Creates the response (used by tests and fakes).
    /// - Parameters:
    ///   - commits: Optional local commits.
    ///   - incoming: Optional incoming commits.
    ///   - nextCursor: Optional pagination cursor.
    public init(
        commits: [SupermuxCommitDTO]? = nil,
        incoming: [SupermuxCommitDTO]? = nil,
        nextCursor: String? = nil
    ) {
        self.commits = commits
        self.incoming = incoming
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case commits
        case incoming
        case nextCursor = "next_cursor"
    }
}

/// Which network-bound sync operation a log entry came from.
public enum SupermuxChangesSyncOperation: Sendable, Equatable {
    /// `changes.push`.
    case push
    /// `changes.pull`.
    case pull
}

/// One completed push/pull's log, ready for the result sheet: raw git output
/// lines plus the Mac-side truncation flag. Identity is per-run so repeated
/// pushes re-present the sheet.
public struct SupermuxChangesSyncLogEntry: Identifiable, Sendable, Equatable {
    /// Per-run identity (drives `sheet(item:)`).
    public let id: UUID
    /// The operation that produced the log.
    public let operation: SupermuxChangesSyncOperation
    /// Raw git output lines (may be empty).
    public let lines: [String]
    /// Whether the Mac capped the log.
    public let truncated: Bool

    /// Creates a log entry.
    /// - Parameters:
    ///   - operation: The operation that produced the log.
    ///   - lines: Raw git output lines.
    ///   - truncated: Whether the Mac capped the log.
    ///   - id: Per-run identity; defaults to a fresh UUID.
    public init(
        operation: SupermuxChangesSyncOperation,
        lines: [String],
        truncated: Bool,
        id: UUID = UUID()
    ) {
        self.id = id
        self.operation = operation
        self.lines = lines
        self.truncated = truncated
    }
}
