import Foundation

/// Suggests a git branch name from a free-form workspace description.
public protocol SupermuxAIBranchNaming: Sendable {
    /// Whether AI naming is usable (a key is configured).
    func isConfigured() async -> Bool

    /// Suggests a sanitized, git-safe branch name for `name`, or `nil` when AI
    /// is unavailable, the input is blank, or the request fails.
    func suggestBranchName(forWorkspaceName name: String) async -> String?
}

/// Feature service behind "name the branch from the workspace name with AI".
///
/// Asks a lightweight model for a single kebab-case branch name and runs it
/// through ``SupermuxBranchName/sanitize(_:)`` so the result is always
/// git-safe. Any failure returns `nil`, letting the caller fall back to the
/// existing random-name behavior — AI naming is an enhancement, never a gate.
public struct SupermuxAIBranchNamer: SupermuxAIBranchNaming {
    private let client: any SupermuxAICompleting
    private let modelProvider: @Sendable () -> String
    private let naming = SupermuxBranchName()

    /// Creates the namer.
    /// - Parameters:
    ///   - client: Completion backend.
    ///   - modelProvider: Resolves the model slug per call; defaults to
    ///     ``SupermuxAIConfig/currentModel(defaults:)``.
    public init(
        client: any SupermuxAICompleting,
        modelProvider: @escaping @Sendable () -> String = { SupermuxAIConfig.currentModel() }
    ) {
        self.client = client
        self.modelProvider = modelProvider
    }

    public func isConfigured() async -> Bool {
        await client.isConfigured()
    }

    public func suggestBranchName(forWorkspaceName name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, await client.isConfigured() else { return nil }
        do {
            let raw = try await client.complete(
                model: modelProvider(),
                system: Self.systemPrompt,
                user: trimmed,
                maxOutputTokens: 24
            )
            let firstLine = raw.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? raw
            return naming.sanitize(firstLine)
        } catch {
            return nil
        }
    }

    private static let systemPrompt = """
    You generate git branch names. Given a short task or workspace description, \
    reply with ONLY one git branch name and nothing else. Use lowercase \
    kebab-case (words separated by single hyphens), 2 to 5 words, no spaces, no \
    slashes, no quotes, and no trailing punctuation. \
    Example: input "Fix the login redirect bug" -> output "fix-login-redirect".
    """
}
