public import Foundation

/// The result core of `mobile.supermux.worktree.suggest_branch`: an AI-named
/// branch when a namer is wired, configured, and succeeds; otherwise a
/// friendly random name (``SupermuxBranchName/randomName()`` over
/// `SupermuxFriendlyWords`). Never an error — suggestion is an enhancement,
/// exactly like the desktop new-worktree sheet's fallback chain.
///
/// The wire payload is exactly `{branch_name, source}`; no configuration or
/// key material can travel because the type simply has no other fields.
public struct SupermuxMobileBranchSuggestion: Sendable, Equatable {
    /// Where the suggested name came from (the wire `source` raw values).
    public enum Source: String, Sendable, Equatable {
        /// The AI branch namer produced the name.
        case ai
        /// The friendly-words random generator produced the name.
        case random
    }

    /// The suggested git-safe branch name.
    public let branchName: String
    /// Which generator produced ``branchName``.
    public let source: Source

    /// Creates a suggestion.
    /// - Parameters:
    ///   - branchName: The suggested branch name.
    ///   - source: Which generator produced it.
    public init(branchName: String, source: Source) {
        self.branchName = branchName
        self.source = source
    }

    /// Suggests a branch name for a workspace description.
    ///
    /// The AI path runs only when `namer` is provided AND the trimmed
    /// `workspaceName` is non-empty; the namer itself degrades to `nil` when
    /// no key is configured, the request fails, or the reply sanitizes to
    /// nothing — every one of those falls back to a random friendly name.
    /// - Parameters:
    ///   - workspaceName: Free-form workspace name from the phone, if any.
    ///   - namer: The AI branch namer, or `nil` when none is wired.
    ///   - naming: Branch naming policy for the random fallback.
    /// - Returns: A suggestion; never throws, never empty.
    public static func suggest(
        workspaceName: String?,
        namer: (any SupermuxAIBranchNaming)?,
        naming: SupermuxBranchName = SupermuxBranchName()
    ) async -> SupermuxMobileBranchSuggestion {
        if let namer,
           let name = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           let suggestion = await namer.suggestBranchName(forWorkspaceName: name) {
            return SupermuxMobileBranchSuggestion(branchName: suggestion, source: .ai)
        }
        return SupermuxMobileBranchSuggestion(branchName: naming.randomName(), source: .random)
    }

    /// The RPC result payload: exactly `{branch_name, source}`.
    public var wirePayload: [String: Any] {
        [
            "branch_name": branchName,
            "source": source.rawValue,
        ]
    }
}
