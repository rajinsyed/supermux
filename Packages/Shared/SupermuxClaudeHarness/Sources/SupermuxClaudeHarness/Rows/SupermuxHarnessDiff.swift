import Foundation

/// A parsed unified diff.
///
/// Ported from remodex's `UnifiedDiffParser` / `UnifiedDiff` (Apache-2.0), with
/// one addition: Claude Code's `tool_use_result.structuredPatch` is already
/// hunk-structured, so it maps directly onto the same model instead of being
/// re-serialized into diff text and re-parsed.
public struct SupermuxHarnessDiff: Sendable, Equatable {
    public let hunks: [Hunk]
    /// Full-width meta rows the body renders ABOVE the hunks (truncation, and
    /// whatever the renderer adds for file status). Part of the model because
    /// the analytic body height counts them.
    public let notices: [String]

    public init(hunks: [Hunk], notices: [String] = []) {
        self.hunks = hunks
        self.notices = notices
    }

    public var isEmpty: Bool { hunks.isEmpty }
    public var additions: Int { hunks.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }
    /// Rendered diff rows across every hunk (the hunk headers are counted
    /// separately, at their own height).
    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }

    /// Keeps hunks in order until the line budget is spent — the straddling
    /// hunk is cut mid-hunk and later hunks are dropped — then appends the
    /// counted notice.
    ///
    /// A transcript diff renders as ONE stacked element inside its row (the
    /// changes pane virtualizes; this does not), so an unbounded whole-file
    /// rewrite would build tens of thousands of views in a frame.
    public func truncated(to maxLines: Int) -> SupermuxHarnessDiff {
        let total = lineCount
        guard maxLines >= 0, total > maxLines else { return self }
        var kept: [Hunk] = []
        var budget = maxLines
        for hunk in hunks {
            guard budget > 0 else { break }
            if hunk.lines.count <= budget {
                kept.append(hunk)
                budget -= hunk.lines.count
                continue
            }
            kept.append(
                Hunk(
                    id: hunk.id,
                    oldStart: hunk.oldStart,
                    newStart: hunk.newStart,
                    lines: Array(hunk.lines.prefix(budget)),
                    isSynthetic: hunk.isSynthetic
                )
            )
            budget = 0
        }
        return SupermuxHarnessDiff(
            hunks: kept,
            notices: notices + [Self.truncationNotice(showing: maxLines, of: total)]
        )
    }

    static func truncationNotice(showing: Int, of total: Int) -> String {
        String(
            format: String(
                localized: "supermux.harness.diff.truncated",
                defaultValue: "Diff truncated — showing first %1$lld of %2$lld lines"
            ),
            Int64(showing), Int64(total)
        )
    }

    public struct Hunk: Sendable, Equatable, Identifiable {
        public let id: String
        public let oldStart: Int
        public let newStart: Int
        public let lines: [Line]
        /// The source had no `@@` header, so line numbers are assumed.
        public let isSynthetic: Bool

        public var additions: Int { lines.reduce(0) { $0 + ($1.kind == .addition ? 1 : 0) } }
        public var deletions: Int { lines.reduce(0) { $0 + ($1.kind == .deletion ? 1 : 0) } }
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case addition
            case deletion
            case context
        }

        public let id: String
        public let kind: Kind
        public let oldNumber: Int?
        public let newNumber: Int?
        public let text: String
    }

    // MARK: - structuredPatch

    /// Builds a diff from a tool result's `structuredPatch`, when present.
    ///
    /// Edit/Write/MultiEdit results carry
    /// `{"structuredPatch":[{"oldStart":N,"oldLines":N,"newStart":N,"newLines":N,
    /// "lines":["-a"," b","+c"]}]}`. An empty array (a file creation) yields
    /// `nil` so the card falls back to its content preview.
    public static func from(toolUseResult: ClaudeJSONValue?) -> SupermuxHarnessDiff? {
        guard let patch = toolUseResult?["structuredPatch"]?.arrayValue, !patch.isEmpty else {
            return nil
        }
        var hunks: [Hunk] = []
        for (index, entry) in patch.enumerated() {
            guard let object = entry.objectValue,
                  let rawLines = object["lines"]?.arrayValue else { continue }
            let oldStart = object["oldStart"]?.intValue ?? 1
            let newStart = object["newStart"]?.intValue ?? 1
            var oldCounter = max(oldStart, 1)
            var newCounter = max(newStart, 1)
            var lines: [Line] = []
            for raw in rawLines.compactMap(\.stringValue) {
                let line = classify(
                    raw,
                    hunkIndex: index,
                    position: lines.count,
                    oldCounter: &oldCounter,
                    newCounter: &newCounter
                )
                lines.append(line)
            }
            guard !lines.isEmpty else { continue }
            hunks.append(
                Hunk(
                    id: "patch-\(index)-\(oldStart)-\(newStart)",
                    oldStart: oldStart,
                    newStart: newStart,
                    lines: lines,
                    isSynthetic: false
                )
            )
        }
        return hunks.isEmpty ? nil : SupermuxHarnessDiff(hunks: hunks)
    }

    // MARK: - Unified diff text

    private static let hunkHeaderPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
    }()

    /// Parses unified diff text. Metadata lines are skipped; change rows that
    /// appear before any `@@` header open a synthetic hunk so a header-less
    /// patch still renders.
    public static func parse(_ diffText: String) -> SupermuxHarnessDiff {
        var hunks: [Hunk] = []
        var currentLines: [Line] = []
        var hasOpenHunk = false
        var isSynthetic = false
        var oldStart = 0
        var newStart = 0
        var oldCounter = 0
        var newCounter = 0
        var hunkIndex = 0

        func flush() {
            defer {
                currentLines = []
                hasOpenHunk = false
                isSynthetic = false
            }
            guard hasOpenHunk, !currentLines.isEmpty else { return }
            hunks.append(
                Hunk(
                    id: "hunk-\(hunkIndex)-\(oldStart)-\(newStart)",
                    oldStart: oldStart,
                    newStart: newStart,
                    lines: currentLines,
                    isSynthetic: isSynthetic
                )
            )
            hunkIndex += 1
        }

        for raw in diffText.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                flush()
                if let header = parseHunkHeader(raw) {
                    oldStart = header.oldStart
                    newStart = header.newStart
                    oldCounter = max(header.oldStart, 1)
                    newCounter = max(header.newStart, 1)
                    hasOpenHunk = true
                    isSynthetic = false
                }
                continue
            }
            if isMetadataLine(raw) || raw.hasPrefix("\\") { continue }
            let isChangeRow = raw.hasPrefix("+") || raw.hasPrefix("-") || raw.hasPrefix(" ")
            if !hasOpenHunk {
                guard isChangeRow else { continue }
                oldStart = 1
                newStart = 1
                oldCounter = 1
                newCounter = 1
                hasOpenHunk = true
                isSynthetic = true
            }
            currentLines.append(
                classify(
                    raw,
                    hunkIndex: hunkIndex,
                    position: currentLines.count,
                    oldCounter: &oldCounter,
                    newCounter: &newCounter
                )
            )
        }
        flush()
        return SupermuxHarnessDiff(hunks: hunks)
    }

    private static func classify(
        _ raw: String,
        hunkIndex: Int,
        position: Int,
        oldCounter: inout Int,
        newCounter: inout Int
    ) -> Line {
        if raw.hasPrefix("+") {
            defer { newCounter += 1 }
            return Line(
                id: "\(hunkIndex)-add-\(position)",
                kind: .addition,
                oldNumber: nil,
                newNumber: newCounter,
                text: String(raw.dropFirst())
            )
        }
        if raw.hasPrefix("-") {
            defer { oldCounter += 1 }
            return Line(
                id: "\(hunkIndex)-del-\(position)",
                kind: .deletion,
                oldNumber: oldCounter,
                newNumber: nil,
                text: String(raw.dropFirst())
            )
        }
        defer {
            oldCounter += 1
            newCounter += 1
        }
        return Line(
            id: "\(hunkIndex)-ctx-\(position)",
            kind: .context,
            oldNumber: oldCounter,
            newNumber: newCounter,
            text: raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
        )
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        let prefixes = [
            "diff --git ", "index ", "--- ", "+++ ", "new file mode",
            "deleted file mode", "old mode ", "new mode ", "rename from ",
            "rename to ", "copy from ", "copy to ", "similarity index ",
            "dissimilarity index ", "Binary files ",
        ]
        return prefixes.contains { line.hasPrefix($0) }
    }

    private static func parseHunkHeader(
        _ line: String
    ) -> (oldStart: Int, newStart: Int)? {
        guard let regex = hunkHeaderPattern else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else { return nil }
        func intAt(_ index: Int) -> Int {
            let nsRange = match.range(at: index)
            guard nsRange.location != NSNotFound, let r = Range(nsRange, in: line) else { return 0 }
            return Int(line[r]) ?? 0
        }
        return (oldStart: intAt(1), newStart: intAt(3))
    }
}
