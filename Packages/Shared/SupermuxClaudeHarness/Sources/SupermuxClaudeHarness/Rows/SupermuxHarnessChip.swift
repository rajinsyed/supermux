import Foundation

/// One chip's expandable body.
///
/// Every height here is **analytic** — nothing is measured. That is what lets a
/// fold tween interpolate two known heights and a virtualizer skip offscreen
/// rows; the mono bodies are fixed 18 pt single-line rows, so content cannot
/// exceed the box it is given.
public enum SupermuxHarnessChipDetail: Sendable, Equatable {
    /// Verbatim output lines (indentation intact), capped with a counted tail.
    case output(lines: [String], truncatedBy: Int)
    /// Per-file `+N −N` rows — the thin record of an edit. No counted tail.
    case stats([SupermuxHarnessDiffStat])
    /// A real diff, rendered by the shared diff body.
    case diff(SupermuxHarnessDiff)

    public var height: CGFloat {
        let metrics = SupermuxHarnessChipMetrics.self
        let body: CGFloat
        switch self {
        case .output(let lines, let truncatedBy):
            let rows = lines.count + (truncatedBy > 0 ? 1 : 0)
            body = CGFloat(rows) * metrics.outputLineHeight + metrics.outputBodyPad
        case .stats(let stats):
            body = CGFloat(stats.count) * metrics.outputLineHeight + metrics.outputBodyPad
        case .diff(let diff):
            body = CGFloat(diff.notices.count) * metrics.noticeHeight
                + CGFloat(diff.hunks.count) * metrics.hunkHeaderHeight
                + CGFloat(diff.lineCount) * metrics.diffLineHeight
                + metrics.diffBodyBottomPad
        }
        return metrics.detailSeparator + body
    }
}

/// One file's `+N −N` tally.
public struct SupermuxHarnessDiffStat: Sendable, Equatable {
    public let path: String
    public let additions: Int
    public let deletions: Int

    public init(path: String, additions: Int, deletions: Int) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
    }
}

public extension SupermuxHarnessToolCall {
    /// What a chip *is* — it picks the icon, the verb and the subject shape.
    enum ChipKind: Sendable, Equatable {
        case exec
        case readFile
        case writeFile
        case editFile
        case applyPatch
        case search
        case glob
        case webFetch
        case webSearch
        case todo
        case mcp
        case unknown
    }

    /// Claude Code's tool names onto the twelve chip kinds.
    ///
    /// `Task`, `Skill`, `AskUserQuestion`, the plan-mode tools and the
    /// cmux-specific tools all land on `.unknown` deliberately: a chip that
    /// claims a shape it cannot fill reads worse than the honest generic one.
    var chipKind: ChipKind {
        switch name {
        case "Bash", "BashOutput", "KillShell":
            return .exec
        case "Read", "NotebookRead":
            return .readFile
        case "Write":
            return .writeFile
        case "Edit", "MultiEdit", "NotebookEdit":
            return .editFile
        case "ApplyPatch":
            return .applyPatch
        case "Grep":
            return .search
        case "Glob":
            return .glob
        case "WebFetch":
            return .webFetch
        case "WebSearch":
            return .webSearch
        case "TodoWrite":
            return .todo
        default:
            return name.hasPrefix("mcp__") ? .mcp : .unknown
        }
    }

    /// The chip's leading word. ONE word: the chip has 8 pt of room, and the
    /// humanizer's sentences ("Ran command") do not fit. `labels` remains the
    /// accessibility text.
    var verb: String {
        switch chipKind {
        case .exec: return SupermuxHarnessChipVerb.run
        case .readFile: return SupermuxHarnessChipVerb.read
        case .writeFile: return SupermuxHarnessChipVerb.write
        case .editFile: return SupermuxHarnessChipVerb.edit
        case .applyPatch: return SupermuxHarnessChipVerb.patch
        case .search: return SupermuxHarnessChipVerb.search
        case .glob: return SupermuxHarnessChipVerb.glob
        case .webFetch: return SupermuxHarnessChipVerb.fetch
        case .webSearch: return SupermuxHarnessChipVerb.web
        case .todo: return SupermuxHarnessChipVerb.todo
        case .mcp: return SupermuxHarnessChipVerb.mcp
        case .unknown: return SupermuxHarnessChipVerb.tool
        }
    }

    /// The chip's trailing identity line.
    ///
    /// ALWAYS collapsed to one line: a literal newline breaks truncation, and
    /// every value here is model-generated text.
    var chipSubject: String {
        SupermuxHarnessChipText.singleLine(rawChipSubject)
    }

    /// The full, un-flattened call — the complete command, pattern, URL or
    /// input JSON the header truncates to one line.
    ///
    /// Always built (which is why almost every chip expands), hard-wrapped at
    /// exactly `callWrapColumns` CHARACTERS rather than word boundaries, with
    /// trailing blanks popped and a counted tail past `outputMaxLines`.
    var invocationBlock: SupermuxHarnessChipDetail? {
        SupermuxHarnessChipText.outputBlock(
            from: invocationText,
            wrappingAt: SupermuxHarnessChipMetrics.callWrapColumns
        )
    }

    /// The chip's result body. Strict precedence, FIRST MATCH WINS:
    /// diff → stats → output → none.
    ///
    /// A diff wins over raw output because it is the more structured record of
    /// the same action. An identical-text patch produces zero hunks and returns
    /// `nil` outright — it must render NOTHING, not an empty box.
    var detail: SupermuxHarnessChipDetail? {
        if let diff, !diff.isEmpty {
            return .diff(diff.truncated(to: SupermuxHarnessChipMetrics.diffMaxLines))
        }
        if !diffStats.isEmpty {
            return .stats(diffStats)
        }
        guard let resultText else { return nil }
        return SupermuxHarnessChipText.outputBlock(from: resultText, wrappingAt: nil)
    }

    // MARK: - Private

    private var rawChipSubject: String {
        switch chipKind {
        case .exec:
            return input["command"]?.stringValue ?? name
        case .readFile, .writeFile, .editFile:
            return subject ?? name
        case .applyPatch:
            return subject ?? SupermuxHarnessChipText.workspace
        case .search:
            let pattern = input["pattern"]?.stringValue ?? ""
            guard let path = input["path"]?.stringValue, !path.isEmpty else { return pattern }
            return SupermuxHarnessChipText.patternInPath(pattern: pattern, path: path)
        case .glob:
            return input["pattern"]?.stringValue ?? name
        case .webFetch:
            return input["url"]?.stringValue ?? name
        case .webSearch:
            return input["query"]?.stringValue ?? name
        case .todo:
            let items = todos
            let done = items.filter { $0.state == .completed }.count
            return SupermuxHarnessChipText.todoProgress(done: done, total: items.count)
        case .mcp:
            return mcpIdentity ?? name
        case .unknown:
            return name
        }
    }

    /// `"{server} · {tool}"` for an `mcp__server__tool` name.
    private var mcpIdentity: String? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.dropFirst(5).split(separator: "__", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return "\(parts[0]) · \(parts[1])"
    }

    private var invocationText: String {
        switch chipKind {
        case .exec:
            return input["command"]?.stringValue ?? name
        case .readFile, .editFile:
            return subject ?? name
        case .writeFile:
            let path = subject ?? name
            guard let content = input["content"]?.stringValue, !content.isEmpty else { return path }
            return "\(path)\n\(content)"
        case .applyPatch:
            return subject ?? SupermuxHarnessChipText.workspace
        case .search, .glob, .webSearch:
            return rawChipSubject
        case .webFetch:
            let url = input["url"]?.stringValue ?? name
            guard let prompt = input["prompt"]?.stringValue, !prompt.isEmpty else { return url }
            return "\(url)\n\(prompt)"
        case .todo:
            return todos
                .map { "\($0.state == .completed ? "[x]" : "[ ]") \($0.content)" }
                .joined(separator: "\n")
        case .mcp, .unknown:
            let header = chipKind == .mcp ? (mcpIdentity ?? name) : name
            guard let pretty = SupermuxHarnessChipText.prettyJSON(input) else { return header }
            return "\(header)\n\(pretty)"
        }
    }
}

/// The twelve chip verbs. One word each — zeron's own table, not the
/// humanizer's sentences.
/// lint:allow namespace-enum, namespace-type — the twelve localized chip verbs — a string table.
enum SupermuxHarnessChipVerb {
    static var run: String {
        String(localized: "supermux.harness.chip.verb.run", defaultValue: "Run")
    }
    static var read: String {
        String(localized: "supermux.harness.chip.verb.read", defaultValue: "Read")
    }
    static var write: String {
        String(localized: "supermux.harness.chip.verb.write", defaultValue: "Write")
    }
    static var edit: String {
        String(localized: "supermux.harness.chip.verb.edit", defaultValue: "Edit")
    }
    static var patch: String {
        String(localized: "supermux.harness.chip.verb.patch", defaultValue: "Patch")
    }
    static var search: String {
        String(localized: "supermux.harness.chip.verb.search", defaultValue: "Search")
    }
    static var glob: String {
        String(localized: "supermux.harness.chip.verb.glob", defaultValue: "Glob")
    }
    static var fetch: String {
        String(localized: "supermux.harness.chip.verb.fetch", defaultValue: "Fetch")
    }
    static var web: String {
        String(localized: "supermux.harness.chip.verb.web", defaultValue: "Web")
    }
    static var todo: String {
        String(localized: "supermux.harness.chip.verb.todo", defaultValue: "Todo")
    }
    static var mcp: String {
        String(localized: "supermux.harness.chip.verb.mcp", defaultValue: "MCP")
    }
    static var tool: String {
        String(localized: "supermux.harness.chip.verb.tool", defaultValue: "Tool")
    }
}

/// Text shaping shared by the chip header and its bodies.
/// lint:allow namespace-enum, namespace-type — pure text shaping shared by the chip header and its bodies.
enum SupermuxHarnessChipText {
    static var workspace: String {
        String(
            localized: "supermux.harness.chip.subject.workspace",
            defaultValue: "workspace"
        )
    }

    static func patternInPath(pattern: String, path: String) -> String {
        String(
            format: String(
                localized: "supermux.harness.chip.subject.patternInPath",
                defaultValue: "%1$@ in %2$@"
            ),
            pattern, path
        )
    }

    static func todoProgress(done: Int, total: Int) -> String {
        String(
            format: String(
                localized: "supermux.harness.chip.subject.todoProgress",
                defaultValue: "%1$lld/%2$lld done"
            ),
            Int64(done), Int64(total)
        )
    }

    /// Collapse model text onto ONE line: newlines, tabs and whitespace runs
    /// become single spaces, trimmed.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Build an `.output` body: split lines, optionally hard-wrap at a column
    /// budget, pop trailing blanks, then cap with a counted tail.
    ///
    /// The wrap is char-counted rather than measured because block heights must
    /// stay analytic. Returns `nil` when nothing survives — an empty body must
    /// render as nothing, not as an empty box.
    static func outputBlock(
        from text: String,
        wrappingAt columns: Int?
    ) -> SupermuxHarnessChipDetail? {
        var lines = text.components(separatedBy: "\n")
        // `components` on a trailing newline yields a final "", which the
        // blank-popping below removes; splitting on lines() semantics first
        // would drop an intentional trailing blank *inside* the body.
        if let columns {
            lines = lines.flatMap { wrap($0, at: columns) }
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }
        let cap = SupermuxHarnessChipMetrics.outputMaxLines
        let truncatedBy = max(0, lines.count - cap)
        return .output(lines: Array(lines.prefix(cap)), truncatedBy: truncatedBy)
    }

    /// Hard-wrap one line into fixed-width chunks — no word boundaries, so a
    /// long single-token command stays fully readable instead of ellipsizing.
    private static func wrap(_ line: String, at columns: Int) -> [String] {
        guard columns > 0, line.count > columns else { return [line] }
        var chunks: [String] = []
        var index = line.startIndex
        while index < line.endIndex {
            let end = line.index(index, offsetBy: columns, limitedBy: line.endIndex)
                ?? line.endIndex
            chunks.append(String(line[index..<end]))
            index = end
        }
        return chunks
    }

    /// Sorted-key pretty JSON, so the same input always renders the same block
    /// (and a fingerprint over it stays stable).
    static func prettyJSON(_ value: ClaudeJSONValue) -> String? {
        if case .object(let object) = value, object.isEmpty { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
