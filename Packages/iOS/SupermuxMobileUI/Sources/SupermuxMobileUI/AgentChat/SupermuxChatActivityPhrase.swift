import Foundation

/// A tool invocation rendered as a short, readable activity line.
///
/// The verb carries tense — "Reading" while in flight, "Read" once finished —
/// so a running row needs no spinner or status text to read as running. The
/// target is the shortest thing that still identifies the work: a file's last
/// path components, a search pattern, a git subcommand.
public struct SupermuxChatActivityPhrase: Equatable, Sendable {
    /// The leading verb, tensed for the invocation's state.
    public let verb: String

    /// What the verb acted on. Empty when the verb says it all.
    public let target: String

    /// Creates a phrase.
    public init(verb: String, target: String) {
        self.verb = verb
        self.target = target
    }
}

/// Turns a Claude Code tool invocation into a ``SupermuxChatActivityPhrase``.
///
/// The parser upstream already builds a one-line `summary` (e.g. `Read
/// src/main.swift`), but it is machine-shaped: tool name first, full paths,
/// present tense regardless of state. This re-phrases it for reading.
public extension SupermuxChatActivityPhrase {
    /// A verb family, chosen by tool name.
    ///
    /// Kept as a case rather than a pair of strings so the localized text
    /// stays in one `switch` with literal keys, which is what the string
    /// catalog's extractor can see.
    enum Family: Sendable, Equatable {
        case plan
        case searchWeb
        case fetch
        case edit
        case write
        case read
        case search
        case find
        case list
        case delegate
        case run
        case genericTool
    }

    /// Builds the phrase for a tool invocation.
    ///
    /// - Parameters:
    ///   - toolName: The tool's machine name (`Read`, `Bash`, `mcp__x__y`).
    ///   - summary: The parser's one-line summary, used for the target.
    ///   - isRunning: Whether the invocation is still in flight.
    /// - Returns: The phrase to render.
    static func phrase(
        toolName: String,
        summary: String,
        isRunning: Bool
    ) -> SupermuxChatActivityPhrase {
        SupermuxChatActivityPhrase(
            verb: verb(family: family(forToolName: toolName), isRunning: isRunning),
            target: target(toolName: toolName, summary: summary)
        )
    }

    // MARK: - Family

    static func family(forToolName toolName: String) -> Family {
        let squished = toolName
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined()
        guard !squished.isEmpty else { return .genericTool }
        if squished.hasPrefix("mcp") { return .genericTool }
        for rule in familyRules where squished.contains(rule.needle) {
            return rule.family
        }
        return .genericTool
    }

    /// Most-specific first, so `TodoWrite` never matches `write`. The shell
    /// family also sits above the read family: `KillShell` contains "ls" and
    /// would otherwise be phrased as a directory listing.
    private static let familyRules: [(needle: String, family: Family)] = [
        ("todowrite", .plan),
        ("exitplanmode", .plan),
        ("websearch", .searchWeb),
        ("webfetch", .fetch),
        ("fetch", .fetch),
        ("bashoutput", .run),
        ("killshell", .run),
        ("bash", .run),
        ("multiedit", .edit),
        ("notebookedit", .edit),
        ("edit", .edit),
        ("write", .write),
        ("notebookread", .read),
        ("read", .read),
        ("grep", .search),
        ("glob", .find),
        ("ls", .list),
        ("subagent", .delegate),
        ("agent", .delegate),
        ("task", .delegate),
    ]

    // MARK: - Verb

    static func verb(family: Family, isRunning: Bool) -> String {
        switch family {
        case .plan:
            return isRunning
                ? String(localized: "supermux.chat.activity.planning", defaultValue: "Planning", bundle: .module)
                : String(localized: "supermux.chat.activity.planned", defaultValue: "Updated plan", bundle: .module)
        case .searchWeb:
            return isRunning
                ? String(localized: "supermux.chat.activity.searchingWeb", defaultValue: "Searching the web", bundle: .module)
                : String(localized: "supermux.chat.activity.searchedWeb", defaultValue: "Searched the web", bundle: .module)
        case .fetch:
            return isRunning
                ? String(localized: "supermux.chat.activity.fetching", defaultValue: "Fetching", bundle: .module)
                : String(localized: "supermux.chat.activity.fetched", defaultValue: "Fetched", bundle: .module)
        case .edit:
            return isRunning
                ? String(localized: "supermux.chat.activity.editing", defaultValue: "Editing", bundle: .module)
                : String(localized: "supermux.chat.activity.edited", defaultValue: "Edited", bundle: .module)
        case .write:
            return isRunning
                ? String(localized: "supermux.chat.activity.writing", defaultValue: "Writing", bundle: .module)
                : String(localized: "supermux.chat.activity.wrote", defaultValue: "Wrote", bundle: .module)
        case .read:
            return isRunning
                ? String(localized: "supermux.chat.activity.reading", defaultValue: "Reading", bundle: .module)
                : String(localized: "supermux.chat.activity.read", defaultValue: "Read", bundle: .module)
        case .search:
            return isRunning
                ? String(localized: "supermux.chat.activity.searching", defaultValue: "Searching", bundle: .module)
                : String(localized: "supermux.chat.activity.searched", defaultValue: "Searched", bundle: .module)
        case .find:
            return isRunning
                ? String(localized: "supermux.chat.activity.finding", defaultValue: "Finding", bundle: .module)
                : String(localized: "supermux.chat.activity.found", defaultValue: "Found", bundle: .module)
        case .list:
            return isRunning
                ? String(localized: "supermux.chat.activity.listing", defaultValue: "Listing", bundle: .module)
                : String(localized: "supermux.chat.activity.listed", defaultValue: "Listed", bundle: .module)
        case .delegate:
            return isRunning
                ? String(localized: "supermux.chat.activity.delegating", defaultValue: "Delegating to", bundle: .module)
                : String(localized: "supermux.chat.activity.delegated", defaultValue: "Delegated to", bundle: .module)
        case .run:
            return isRunning
                ? String(localized: "supermux.chat.activity.running", defaultValue: "Running", bundle: .module)
                : String(localized: "supermux.chat.activity.ran", defaultValue: "Ran", bundle: .module)
        case .genericTool:
            return isRunning
                ? String(localized: "supermux.chat.activity.usingTool", defaultValue: "Using", bundle: .module)
                : String(localized: "supermux.chat.activity.usedTool", defaultValue: "Used", bundle: .module)
        }
    }

    // MARK: - Target

    /// Strips the parser's leading tool name off the summary, then shortens
    /// whatever remains. When the summary carried nothing but the tool name,
    /// the target is empty and the verb stands alone.
    static func target(toolName: String, summary: String) -> String {
        var remainder = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.lowercased().hasPrefix(toolName.lowercased()) {
            remainder = String(remainder.dropFirst(toolName.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Only the first line ever fits on a row.
        if let newline = remainder.firstIndex(of: "\n") {
            remainder = String(remainder[..<newline])
        }
        guard !remainder.isEmpty else { return "" }
        return shortenedPaths(in: remainder)
    }

    /// Rewrites long paths down to their last two components so a row shows
    /// `Sources/ChatScreen.swift`, not a 90-character home directory.
    static func shortenedPaths(in text: String) -> String {
        text
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { token -> String in
                guard token.contains("/"), token.count > 24 else { return String(token) }
                let components = token.split(separator: "/", omittingEmptySubsequences: true)
                guard components.count > 2 else { return String(token) }
                return components.suffix(2).joined(separator: "/")
            }
            .joined(separator: " ")
    }
}
