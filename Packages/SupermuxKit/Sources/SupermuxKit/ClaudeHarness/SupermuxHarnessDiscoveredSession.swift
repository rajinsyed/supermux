public import Foundation

/// Summary metadata for one persisted Claude Code session in a working directory.
public struct SupermuxHarnessDiscoveredSession: Equatable, Sendable {
    /// The session identifier derived from the JSONL filename.
    public let sessionID: String
    /// The preferred title using custom title, AI title, summary, then first-prompt precedence.
    public let title: String
    /// The first non-meta user prompt when one is available.
    public let firstPrompt: String?
    /// The JSONL file modification date.
    public let updatedAt: Date
    /// The latest non-empty branch recorded by the session.
    public let gitBranch: String?
    /// The number of non-meta, non-sidechain user and assistant records.
    public let messageCount: Int

    /// Creates persisted session metadata.
    ///
    /// - Parameters:
    ///   - sessionID: The persisted session identifier.
    ///   - title: The resolved display title.
    ///   - firstPrompt: The optional first prompt.
    ///   - updatedAt: The file modification date.
    ///   - gitBranch: The optional recorded branch.
    ///   - messageCount: The visible main-chain message count.
    public init(
        sessionID: String,
        title: String,
        firstPrompt: String?,
        updatedAt: Date,
        gitBranch: String?,
        messageCount: Int
    ) {
        self.sessionID = sessionID
        self.title = title
        self.firstPrompt = firstPrompt
        self.updatedAt = updatedAt
        self.gitBranch = gitBranch
        self.messageCount = messageCount
    }
}
