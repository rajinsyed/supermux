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
        // Contractions (straight apostrophe; curly is normalized before lookup).
        "don't", "doesn't", "didn't", "can't", "cannot", "won't", "isn't", "aren't",
        "wasn't", "weren't", "it's", "i'm", "i've", "i'd", "we're", "we've", "let's",
        "that's", "there's", "shouldn't", "couldn't", "wouldn't", "hasn't", "haven't",
    ]

    /// Apostrophes kept inside tokens ("don't", "user’s") but never in a branch.
    private static let apostrophes = CharacterSet(charactersIn: "'’")

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
        let headline = tokens(in: firstSentence(of: prompt))
        let words = headline.filter { !isFiller($0) }
        guard !words.isEmpty else { return nil }
        let kept = Array(words.prefix(maximumWords))
        let title = kept.map(titleCased).joined(separator: " ")
        var branchWords = kept.map(branchWord)
        // The task type comes from the headline only, so details that mention
        // an error cannot turn a feature into a `fix-` branch.
        let prefix = branchPrefix(for: Set(headline.map { $0.lowercased() }))
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

    /// Shortest label (before a `:`) that still counts as a sentence of its
    /// own; shorter ones ("Bug: …", "Fix: …") stay part of the headline.
    static let minimumColonLabelLength = 12

    private static func firstSentence(of prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // First line first: people put the headline on line one and details
        // below. Then the first sentence of that line.
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        if let end = sentenceEnd(in: firstLine) {
            return String(firstLine[..<end])
        }
        return firstLine
    }

    /// The index of the punctuation that ends the first sentence: `.`, `!`,
    /// `?`, or `;` followed by whitespace (or the end), so "v2.0" survives; a
    /// `:` only after a label long enough to be a sentence itself.
    private static func sentenceEnd(in line: String) -> String.Index? {
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            let endsAWord = next == line.endIndex || line[next].isWhitespace
            if endsAWord {
                switch character {
                case ".", "!", "?", ";":
                    return index
                case ":" where line.distance(from: line.startIndex, to: index) >= minimumColonLabelLength:
                    return index
                default:
                    break
                }
            }
            index = next
        }
        return nil
    }

    /// Words as typed: letters, digits, and the `-`, `_`, `.`, and apostrophe
    /// characters that glue a word together ("don't", "v2.0", "user’s"),
    /// with that glue trimmed from the edges.
    private static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && !"-_.'’".contains($0) })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-_.'’")) }
            .filter { !$0.isEmpty }
    }

    private static func isFiller(_ word: String) -> Bool {
        fillerWords.contains(word.lowercased().replacingOccurrences(of: "’", with: "'"))
    }

    /// The branch form of a word: lowercase, apostrophes dropped ("user’s" →
    /// "users") so git never sees them.
    private static func branchWord(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { !apostrophes.contains($0) })
    }

    private static func titleCased(_ word: String) -> String {
        // Preserve identifiers that already carry casing (e.g. "iOS", "PR",
        // "useEffect"); only capitalize plain lowercase words.
        guard word == word.lowercased() else { return word }
        return word.prefix(1).uppercased() + word.dropFirst()
    }
}
