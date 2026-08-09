import Foundation

/// Maps a Claude Code tool invocation to its leading glyph.
///
/// One uniform stroke glyph per tool *family* rather than a distinct icon per
/// tool: the eye should group "these were all file reads" at a glance, and a
/// zoo of icons defeats that. Matching is on the tool's machine name, most
/// specific first, so compound names (`TodoWrite`, `WebSearch`, `MultiEdit`,
/// `NotebookEdit`) resolve before their generic parts (`write`, `search`,
/// `edit`).
public extension SupermuxChatActivityPhrase {
    /// SF Symbol for a tool, keyed off its machine name.
    ///
    /// - Parameter toolName: The tool's name as the agent reported it.
    /// - Returns: An SF Symbol name.
    static func symbolName(forToolName toolName: String) -> String {
        let squished = toolName
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined()
        guard !squished.isEmpty else { return fallbackSymbolName }

        // MCP tools keep one glyph regardless of the verb they wrap, so a
        // server's whole toolset reads as one family.
        if squished.hasPrefix("mcp") {
            return squished.contains("github") ? "shippingbox" : "puzzlepiece.extension"
        }

        for rule in rules where squished.contains(rule.needle) {
            return rule.symbolName
        }
        return fallbackSymbolName
    }

    private static var fallbackSymbolName: String { "hammer" }

    /// First substring match wins; ordered most-specific first.
    private static let rules: [(needle: String, symbolName: String)] = [
        // Plans / task lists
        ("todowrite", "checklist"),
        ("exitplanmode", "checklist"),
        ("todo", "checklist"),
        ("plan", "checklist"),
        // Web
        ("websearch", "globe"),
        ("webfetch", "link"),
        ("fetch", "link"),
        // Edits / writes
        ("multiedit", "pencil"),
        ("notebookedit", "pencil"),
        ("applypatch", "pencil"),
        ("patch", "pencil"),
        ("edit", "pencil"),
        ("write", "pencil"),
        ("create", "pencil"),
        // Shell. Ordered above the read family because `KillShell` contains
        // "ls" and `BashOutput` contains "output" — a shell tool that fell
        // through to the search glyph would silently mis-group.
        ("bashoutput", "terminal"),
        ("killshell", "terminal"),
        ("bash", "terminal"),
        ("shell", "terminal"),
        ("command", "terminal"),
        ("exec", "terminal"),
        ("terminal", "terminal"),
        // Reads / search
        ("notebookread", "magnifyingglass"),
        ("read", "magnifyingglass"),
        ("grep", "magnifyingglass"),
        ("glob", "magnifyingglass"),
        ("search", "magnifyingglass"),
        ("find", "magnifyingglass"),
        ("list", "magnifyingglass"),
        ("ls", "magnifyingglass"),
        // Source control
        ("github", "shippingbox"),
        ("git", "arrow.triangle.branch"),
        // Agents / sub-tasks
        ("subagent", "sparkles"),
        ("agent", "sparkles"),
        ("task", "sparkles"),
        ("skill", "puzzlepiece.extension"),
    ]
}
