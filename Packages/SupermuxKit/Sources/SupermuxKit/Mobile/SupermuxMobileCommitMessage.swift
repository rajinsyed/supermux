import Foundation

/// The outcome of one mobile commit-message generation.
public enum SupermuxMobileCommitMessageOutcome: Equatable, Sendable {
    /// No AI Gateway key is configured — the handler's `ai_unavailable` error.
    case unavailable
    /// The repository has no uncommitted changes to describe.
    case nothingToDescribe
    /// The key is configured but the gateway request failed or returned an
    /// empty reply (never surfaced as a silent empty message).
    case failed
    /// The generated commit message.
    case generated(String)
}

/// The mac-side core of the mobile `changes.generate_commit_message` RPC
/// (mirrors ``SupermuxMobileBranchSuggestion`` for the AI seam).
///
/// Runs entirely mac-side through the composition's
/// ``SupermuxAICommitMessaging`` — the key and model never travel in any
/// request, result, or DTO. The message is produced from the same
/// *non-mutating* capture the desktop AI-commit flow uses
/// (``SupermuxGitChangesService/uncommittedDiff(repoPath:)``), so generating
/// never touches the index; the phone reviews the message and commits
/// explicitly via `changes.commit`.
public enum SupermuxMobileCommitMessage {
    /// Generates a commit message for the repository's uncommitted changes.
    /// - Parameters:
    ///   - repoPath: Repository directory (the workspace's directory).
    ///   - service: The shared git changes engine.
    ///   - messenger: The composition's AI commit-message generator.
    /// - Returns: The deterministic outcome; see
    ///   ``SupermuxMobileCommitMessageOutcome``.
    public static func generate(
        repoPath: String,
        service: SupermuxGitChangesService,
        messenger: any SupermuxAICommitMessaging
    ) async -> SupermuxMobileCommitMessageOutcome {
        guard await messenger.isConfigured() else { return .unavailable }
        let diff = await service.uncommittedDiff(repoPath: repoPath)
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .nothingToDescribe
        }
        guard let message = await messenger.generateMessage(forDiff: diff) else {
            return .failed
        }
        return .generated(message)
    }
}
