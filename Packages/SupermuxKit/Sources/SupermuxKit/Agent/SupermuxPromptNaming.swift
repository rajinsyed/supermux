import Foundation

/// A workspace title and git branch derived from a free-form prompt.
public struct SupermuxPromptNames: Equatable, Sendable {
    /// Short, Title-Case workspace name (e.g. "Fix Login Redirect").
    public var workspaceName: String
    /// Git-safe kebab-case branch (e.g. `fix-login-redirect`).
    public var branchName: String

    /// Creates a name pair.
    public init(workspaceName: String, branchName: String) {
        self.workspaceName = workspaceName
        self.branchName = branchName
    }
}

/// Offline, deterministic naming from a prompt — the fallback (and the live
/// preview) when AI naming is off or fails.
///
/// Takes the prompt's first sentence, drops filler words, keeps the first few
/// meaningful words, and derives a `fix-`/`add-` prefixed branch from the same
/// words so the workspace title and branch always agree. Cheap enough to run
/// on every keystroke for a preview.
public enum SupermuxPromptNaming {
    /// Upper bound on meaningful words kept in the title/branch.
    static let maximumWords = 5

    /// Words carrying no naming signal.
    private static let fillerWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "for",
        "with", "from", "into", "onto", "by", "as", "is", "are", "was", "were", "be",
        "been", "being", "it", "its", "this", "that", "these", "those", "there",
        "i", "me", "my", "we", "our", "you", "your", "they", "them", "their",
        "please", "can", "could", "should", "would", "will", "want", "need", "like",
        "make", "sure", "so", "then", "also", "just", "very", "really", "some",
        "when", "where", "which", "who", "how", "what", "why", "if", "not", "no",
        "do", "does", "did", "have", "has", "had", "get", "got", "let", "us",
        "up", "out", "about", "over", "under", "again", "still", "currently", "between",
    ]

    /// Words that mark the prompt as describing a defect.
    private static let problemWords: Set<String> = [
        "fix", "bug", "broken", "crash", "crashes", "crashing", "fails", "failing",
        "failure", "error", "errors", "wrong", "incorrect", "issue", "regression",
        "freeze", "freezes", "hang", "hangs", "leak", "leaks", "flaky", "slow",
        "repair", "resolve", "debug",
    ]

    /// Words that mark the prompt as describing new work.
    private static let additionWords: Set<String> = [
        "add", "create", "build", "implement", "introduce", "new", "support",
        "feature", "enable", "allow", "want", "wants",
    ]

    /// Derives names from `prompt`, or `nil` when it holds no usable words.
    /// - Parameter prompt: The user's task description.
    public static func names(from prompt: String) -> SupermuxPromptNames? {
        let words = meaningfulWords(in: firstSentence(of: prompt))
        guard !words.isEmpty else { return nil }
        let kept = Array(words.prefix(maximumWords))
        let title = kept.map(titleCased).joined(separator: " ")
        var branchWords = kept.map { $0.lowercased() }
        let allWords = Set(tokens(in: prompt).map { $0.lowercased() })
        let prefix = branchPrefix(for: allWords)
        if let prefix, branchWords.first != prefix {
            branchWords.insert(prefix, at: 0)
        }
        // A prefixed branch keeps at most `maximumWords` total so it stays
        // short; the title keeps the full kept words.
        let branchSource = branchWords.prefix(maximumWords).joined(separator: "-")
        guard let branch = SupermuxBranchName().sanitize(branchSource) else { return nil }
        return SupermuxPromptNames(workspaceName: title, branchName: branch)
    }

    private static func branchPrefix(for words: Set<String>) -> String? {
        if !words.isDisjoint(with: problemWords) { return "fix" }
        if !words.isDisjoint(with: additionWords) { return "add" }
        return nil
    }

    private static func firstSentence(of prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // First line first: people put the headline on line one and details
        // below. Then the first sentence of that line.
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        let terminators: Set<Character> = [".", "!", "?", ";", ":"]
        if let end = firstLine.firstIndex(where: { terminators.contains($0) }),
           firstLine.distance(from: firstLine.startIndex, to: end) >= 12 {
            return String(firstLine[..<end])
        }
        return firstLine
    }

    private static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-_")) }
            .filter { !$0.isEmpty }
    }

    private static func meaningfulWords(in text: String) -> [String] {
        tokens(in: text).filter { !fillerWords.contains($0.lowercased()) }
    }

    private static func titleCased(_ word: String) -> String {
        // Preserve identifiers that already carry casing (e.g. "iOS", "PR",
        // "useEffect"); only capitalize plain lowercase words.
        guard word == word.lowercased() else { return word }
        return word.prefix(1).uppercased() + word.dropFirst()
    }
}
