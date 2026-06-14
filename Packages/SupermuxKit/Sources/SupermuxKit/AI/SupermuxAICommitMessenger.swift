import Foundation

/// Writes a commit message from a staged git diff.
public protocol SupermuxAICommitMessaging: Sendable {
    /// Whether AI commit messages are usable (a key is configured).
    func isConfigured() async -> Bool

    /// Generates a commit message for `diff`, or `nil` when AI is unavailable,
    /// the diff is empty, or the request fails.
    func generateMessage(forDiff diff: String) async -> String?
}

/// Feature service behind "auto-generate the commit message".
///
/// Sends the staged diff to a lightweight model and asks for a Conventional
/// Commits-style message. The diff is clipped to a sane size so a huge change
/// set never blows the request up, and the model's reply is stripped of any
/// stray code fences. Any failure returns `nil` so the caller can surface a
/// friendly message instead of committing garbage.
public struct SupermuxAICommitMessenger: SupermuxAICommitMessaging {
    private let client: any SupermuxAICompleting
    private let modelProvider: @Sendable () -> String

    /// Largest diff (in characters) sent to the model; longer diffs are clipped.
    static let maxDiffCharacters = 12000

    /// Creates the messenger.
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

    public func generateMessage(forDiff diff: String) async -> String? {
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, await client.isConfigured() else { return nil }
        do {
            let raw = try await client.complete(
                model: modelProvider(),
                system: Self.systemPrompt,
                user: Self.clip(trimmed),
                maxOutputTokens: 400
            )
            let cleaned = Self.cleanup(raw)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }

    /// Clips an over-long diff, appending a marker so the model knows it is partial.
    static func clip(_ diff: String) -> String {
        guard diff.count > maxDiffCharacters else { return diff }
        return String(diff.prefix(maxDiffCharacters)) + "\n\n[diff truncated]"
    }

    /// Removes a wrapping ```code fence``` the model may add around the message.
    static func cleanup(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private static let systemPrompt = """
    You are an expert at writing clear, concise git commit messages following \
    Conventional Commits. Given a staged git diff, reply with ONLY the commit \
    message: a single subject line in the imperative mood, at most 72 \
    characters, optionally prefixed with a type such as feat, fix, chore, docs, \
    refactor, or test. When the change is non-trivial, add a blank line and a \
    short body explaining what changed and why. Do not wrap the message in code \
    fences or quotes, and do not add any preamble.
    """
}
