import Testing

@testable import SupermuxMobileUI

/// The activity line is the transcript's most common row, and its whole job is
/// to read like a sentence. These pin the two things that make it do that:
/// tense that tracks state, and targets short enough to fit one phone line.
@Suite("Supermux chat activity phrasing")
struct SupermuxChatActivityPhraseTests {
    @Test("Tense tracks whether the tool is still running")
    func tenseTracksRunningState() {
        let running = SupermuxChatActivityPhrase.phrase(
            toolName: "Read",
            summary: "Read Sources/App.swift",
            isRunning: true
        )
        let finished = SupermuxChatActivityPhrase.phrase(
            toolName: "Read",
            summary: "Read Sources/App.swift",
            isRunning: false
        )
        #expect(running.verb == "Reading")
        #expect(finished.verb == "Read")
    }

    @Test("The tool name is stripped so the row never says 'Read Read …'")
    func toolNamePrefixIsStripped() {
        let phrase = SupermuxChatActivityPhrase.phrase(
            toolName: "Read",
            summary: "Read Sources/App.swift",
            isRunning: false
        )
        #expect(phrase.target == "Sources/App.swift")
    }

    @Test("A summary carrying only the tool name leaves the verb standing alone")
    func bareSummaryYieldsEmptyTarget() {
        let phrase = SupermuxChatActivityPhrase.phrase(
            toolName: "TodoWrite",
            summary: "TodoWrite",
            isRunning: false
        )
        #expect(phrase.target.isEmpty)
        #expect(phrase.verb == "Updated plan")
    }

    @Test("Long absolute paths shorten to their last two components")
    func longPathsAreShortened() {
        let shortened = SupermuxChatActivityPhrase.shortenedPaths(
            in: "/Users/someone/Documents/project/Sources/App/Entry.swift"
        )
        #expect(shortened == "App/Entry.swift")
    }

    @Test("Short paths are left exactly as they are")
    func shortPathsAreUntouched() {
        #expect(SupermuxChatActivityPhrase.shortenedPaths(in: "a/b.swift") == "a/b.swift")
    }

    @Test("Only the first line of a multi-line summary reaches the row")
    func targetIsSingleLine() {
        let phrase = SupermuxChatActivityPhrase.phrase(
            toolName: "Bash",
            summary: "Bash npm test\nsecond line\nthird line",
            isRunning: false
        )
        #expect(phrase.target == "npm test")
    }

    @Test("Compound tool names resolve before their generic parts")
    func compoundNamesWinOverSubstrings() {
        // "TodoWrite" contains "write"; "WebSearch" contains "search".
        #expect(SupermuxChatActivityPhrase.family(forToolName: "TodoWrite") == .plan)
        #expect(SupermuxChatActivityPhrase.family(forToolName: "WebSearch") == .searchWeb)
        #expect(SupermuxChatActivityPhrase.family(forToolName: "MultiEdit") == .edit)
        #expect(SupermuxChatActivityPhrase.family(forToolName: "NotebookRead") == .read)
        // "KillShell" contains "ls"; "BashOutput" contains "output".
        #expect(SupermuxChatActivityPhrase.family(forToolName: "KillShell") == .run)
        #expect(SupermuxChatActivityPhrase.family(forToolName: "BashOutput") == .run)
    }

    @Test("Every MCP tool reads as one family regardless of the verb it wraps")
    func mcpToolsCollapseToOneFamily() {
        #expect(SupermuxChatActivityPhrase.family(forToolName: "mcp__server__write") == .genericTool)
        #expect(SupermuxChatActivityPhrase.family(forToolName: "mcp__github__search") == .genericTool)
    }
}

/// Glyphs group tools by family; a wrong mapping quietly destroys the "these
/// were all file reads" scan that the icon column exists to provide.
@Suite("Supermux chat tool glyphs")
struct SupermuxChatToolGlyphTests {
    @Test("Each Claude Code tool maps to its family glyph")
    func toolsMapToFamilyGlyphs() {
        let expected: [String: String] = [
            "Read": "magnifyingglass",
            "Grep": "magnifyingglass",
            "Glob": "magnifyingglass",
            "Edit": "pencil",
            "Write": "pencil",
            "MultiEdit": "pencil",
            "NotebookEdit": "pencil",
            "Bash": "terminal",
            "BashOutput": "terminal",
            "KillShell": "terminal",
            "TodoWrite": "checklist",
            "ExitPlanMode": "checklist",
            "WebSearch": "globe",
            "WebFetch": "link",
            "Task": "sparkles",
        ]
        for (tool, symbol) in expected {
            #expect(
                SupermuxChatActivityPhrase.symbolName(forToolName: tool) == symbol,
                "\(tool) should map to \(symbol)"
            )
        }
    }

    @Test("MCP tools share one glyph, with GitHub servers distinguished")
    func mcpToolsShareAGlyph() {
        #expect(
            SupermuxChatActivityPhrase.symbolName(forToolName: "mcp__linear__create_issue")
                == "puzzlepiece.extension"
        )
        #expect(
            SupermuxChatActivityPhrase.symbolName(forToolName: "mcp__github__pr")
                == "shippingbox"
        )
    }

    @Test("An unknown tool still gets a glyph rather than an empty column")
    func unknownToolsFallBack() {
        #expect(SupermuxChatActivityPhrase.symbolName(forToolName: "Zzzz") == "hammer")
        #expect(SupermuxChatActivityPhrase.symbolName(forToolName: "") == "hammer")
    }
}
