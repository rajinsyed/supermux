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

    /// Upper bound on the reply length.
    ///
    /// A branch name is a handful of tokens, but this cap is a safety bound,
    /// not a billed amount — only tokens actually produced are charged.
    /// Reasoning models on the gateway (`openai/gpt-5.6-luna` and friends)
    /// spend completion tokens on hidden reasoning *before* emitting any text,
    /// so a name-sized cap is exhausted by reasoning alone and the gateway
    /// returns empty content with `finish_reason: "length"`. That surfaced as
    /// every AI branch name silently falling back to a random one. The budget
    /// therefore has to clear a realistic reasoning burst, not just the name.
    static let maxOutputTokens = 2048

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
                maxOutputTokens: Self.maxOutputTokens
            )
            // Strip a wrapping code fence before taking the first line: a
            // fenced reply ("```\nfix-login\n```") would otherwise yield
            // "```", sanitize to nil, and silently discard the suggestion.
            let cleaned = SupermuxAIReplyCleanup.strippingCodeFence(raw)
            let firstLine = cleaned.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? cleaned
            return naming.sanitize(firstLine)
        } catch {
            return nil
        }
    }

    /// The naming instructions.
    ///
    /// The workspace field is free-form, and in practice people describe the
    /// *problem* they are about to work on ("the app freezes when I drag a tab
    /// between workspaces") far more often than they phrase an imperative
    /// task. Without direction the model echoes that phrasing into a literal,
    /// unusable slug, so the prompt tells it to name the branch after the fix
    /// and to summarize the subject rather than transcribe the sentence.
    private static let systemPrompt = """
    You generate git branch names. Given a short task, bug report, or \
    workspace description, reply with ONLY one git branch name and nothing \
    else. Use lowercase kebab-case (words separated by single hyphens), 2 to 5 \
    words, no spaces, no slashes, no quotes, and no trailing punctuation.

    Name the branch after the work to be done, not the words the user typed. \
    When the input describes a problem, bug, or broken behavior, name the \
    branch after the fix and prefix it with "fix-". When it describes something \
    new, prefix it with "add-". Summarize the subject of the change; never \
    transcribe the whole sentence, and drop filler words like "when", "i", \
    "the", and "also".

    Examples:
    input "Fix the login redirect bug" -> output "fix-login-redirect"
    input "when i drag a tab between workspaces the app freezes for a few \
    seconds and sometimes crashes" -> output "fix-tab-drag-freeze"
    input "I want a dark mode toggle in the settings page" -> output \
    "add-dark-mode-toggle"
    """
}
