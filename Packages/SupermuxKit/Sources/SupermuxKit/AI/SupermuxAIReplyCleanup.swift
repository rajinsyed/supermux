import Foundation

/// Strips a wrapping markdown code fence from a model reply.
///
/// Models occasionally fence their answer despite being told not to, in every
/// shape: a classic multi-line fence, a fence with a language tag, content on
/// the opening fence line, or the whole reply on one line
/// (```` ```fix: x``` ````). Shared by ``SupermuxAICommitMessenger`` and
/// ``SupermuxAIBranchNamer`` so both survive all of them.
enum SupermuxAIReplyCleanup {

    /// Returns `raw` with a wrapping code fence removed, trimmed of
    /// surrounding whitespace. Text that does not start with a fence is
    /// returned unchanged (trimmed). The content is preserved wherever the
    /// fence puts it — a single-line fenced reply keeps its message.
    static func strippingCodeFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        // Drop the opening backtick run, recording its length so the closing
        // side strips exactly the matching fence — never content backticks.
        var openLen = 0
        while text.hasPrefix("`") { text.removeFirst(); openLen += 1 }
        // Drop a language tag occupying the rest of the opening line ("text",
        // "swift" — trailing whitespace tolerated; models emit "```text \n").
        // A first line with interior spaces or punctuation is real content
        // that happened to sit on the fence line ("```fix: x") and is kept.
        if let newline = text.firstIndex(where: \.isNewline) {
            let header = text[..<newline].trimmingCharacters(in: .whitespaces)
            if !header.isEmpty, header.allSatisfy(Self.isLanguageTagCharacter) {
                text = String(text[text.index(after: newline)...])
            }
        }
        // Drop the closing fence — on its own line or glued to the content's
        // last line — by removing exactly the opening run's length, and only
        // when the trailing run is at least that long. A shorter trailing run
        // is content (an inline-code backtick, or a truncated reply that never
        // closed its fence) and is kept intact.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingRun = text.reversed().prefix(while: { $0 == "`" }).count
        if openLen > 0, trailingRun >= openLen {
            text.removeLast(openLen)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLanguageTagCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
            || character == "-" || character == "_" || character == "+"
    }
}
