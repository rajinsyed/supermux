public import Foundation

/// Reads persisted Claude main-session metadata and replay history.
///
/// App controllers depend on this seam so the composition root can inject one
/// shared ``SupermuxHarnessSessionRepository`` while tests provide isolated
/// implementations.
public protocol SupermuxHarnessSessionReading: Sendable {
    /// Lists persisted sessions for one working directory, newest first.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The working directory whose Claude project aliases are probed.
    ///   - limit: Optional maximum result count. Values at or below zero return an empty list.
    /// - Returns: Deduplicated session metadata sorted by modification date.
    /// - Throws: A filesystem or file-reading error for a discovered session file.
    func listSessions(
        for workingDirectoryURL: URL,
        limit: Int?
    ) async throws -> [SupermuxHarnessDiscoveredSession]

    /// Loads one persisted session's selected main-chain history.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The working directory whose Claude project aliases are probed.
    ///   - sessionID: The persisted session filename without `.jsonl`.
    ///   - recordLimit: Optional maximum number of newest visible records to return.
    /// - Returns: Root-to-leaf protocol-shaped events and a truncation flag.
    /// - Throws: ``SupermuxHarnessSessionDiscoveryError`` or a file-reading error.
    func loadHistory(
        for workingDirectoryURL: URL,
        sessionID: String,
        recordLimit: Int?
    ) async throws -> SupermuxHarnessHistoryPage

    /// Returns the current persisted title for one session.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The working directory whose Claude project aliases are probed.
    ///   - sessionID: The persisted session filename without `.jsonl`.
    /// - Returns: The resolved title, or `nil` when unavailable or untitled.
    func sessionTitle(
        for workingDirectoryURL: URL,
        sessionID: String
    ) async -> String?
}
