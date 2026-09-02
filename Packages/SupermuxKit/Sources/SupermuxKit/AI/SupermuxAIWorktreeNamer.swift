import Foundation

/// Names a workspace and its branch from a free-form task prompt.
public protocol SupermuxAIWorktreeNaming: Sendable {
    /// Whether AI naming is usable (a key is configured).
    func isConfigured() async -> Bool

    /// Suggests a workspace title and git-safe branch for `prompt`, or `nil`
    /// when AI is unavailable, the prompt is blank, or the request fails.
    func suggestNames(forPrompt prompt: String) async -> SupermuxPromptNames?
}

/// One lightweight AI call that names both the workspace and the branch from
/// the prompt Claude is about to be started with.
///
/// Asks for a small JSON object so one round trip yields a consistent pair
/// (the branch is derived from the title, not re-summarized separately). The
/// branch is always run through ``SupermuxBranchName/sanitize(_:)``; any
/// failure returns `nil` so the caller falls back to ``SupermuxPromptNaming``.
public struct SupermuxAIWorktreeNamer: SupermuxAIWorktreeNaming {
    private let client: any SupermuxAICompleting
    private let modelProvider: @Sendable () -> String
    private let naming = SupermuxBranchName()

    /// Same rationale as ``SupermuxAIBranchNamer/maxOutputTokens``: reasoning
    /// models spend hidden tokens before the visible JSON.
    static let maxOutputTokens = 2048

    /// Creates the namer.
    /// - Parameters:
    ///   - client: Completion backend.
    ///   - modelProvider: Resolves the model slug per call.
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

    public func suggestNames(forPrompt prompt: String) async -> SupermuxPromptNames? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, await client.isConfigured() else { return nil }
        do {
            let raw = try await client.complete(
                model: modelProvider(),
                system: Self.systemPrompt,
                user: trimmed,
                maxOutputTokens: Self.maxOutputTokens
            )
            return Self.parse(raw, naming: naming)
        } catch {
            return nil
        }
    }

    /// Parses the model's reply. Accepts a bare JSON object or one wrapped in
    /// a code fence; tolerates prose around it (braces included) by taking
    /// the first balanced `{…}` that decodes as an object.
    static func parse(_ raw: String, naming: SupermuxBranchName) -> SupermuxPromptNames? {
        let cleaned = SupermuxAIReplyCleanup.strippingCodeFence(raw)
        guard let object = SupermuxAIJSONObjectExtraction.firstObject(in: cleaned),
              let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        let branchSource = (object["branch"] as? String) ?? title
        guard let branch = naming.sanitize(branchSource) else { return nil }
        return SupermuxPromptNames(workspaceName: title, branchName: branch)
    }

    private static let systemPrompt = """
    You name git worktrees for coding tasks. Given a task prompt (a bug \
    report, a feature request, or an instruction to an AI coding agent), reply \
    with ONLY a JSON object of the form {"title": "...", "branch": "..."} and \
    nothing else.

    "title" is a short workspace name in Title Case, 2 to 5 words, naming the \
    work to be done — not a transcription of the prompt. "branch" is the same \
    idea as a git branch: lowercase kebab-case, 2 to 5 words, no spaces, no \
    slashes, no quotes. When the prompt describes a problem, bug, or broken \
    behavior, name both after the fix and prefix the branch with "fix-". When \
    it describes something new, prefix the branch with "add-". Drop filler \
    words like "please", "when", "i", "the", and "also".

    Examples:
    input "Fix the login redirect bug" -> {"title": "Fix Login Redirect", "branch": "fix-login-redirect"}
    input "when i drag a tab between workspaces the app freezes for a few \
    seconds and sometimes crashes" -> {"title": "Tab Drag Freeze", "branch": "fix-tab-drag-freeze"}
    input "I want a dark mode toggle in the settings page" -> {"title": "Dark Mode Toggle", "branch": "add-dark-mode-toggle"}
    """
}
