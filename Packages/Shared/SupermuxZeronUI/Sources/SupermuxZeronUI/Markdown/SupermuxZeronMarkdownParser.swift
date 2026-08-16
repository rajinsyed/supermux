//
//  SupermuxZeronMarkdownParser.swift
//  SupermuxZeronUI
//
//  markdown source → `SupermuxZeronBlock` tree. A port of
//  `/tmp/zeron-comet/crates/ui/src/markdown/parser.rs`.
//
//  ── Why this is hand-written ──
//
//  zeron runs pulldown-cmark with EXACTLY three extensions enabled
//  (`parser.rs:107`): tables, strikethrough, task lists. Footnotes, smart
//  punctuation, heading attributes and math are OFF. This package is allowed
//  exactly one dependency (`SupermuxClaudeHarness`), and swift-markdown would
//  add a cmark-gfm C target plus its own tree model that still has to be
//  lowered into this one. The behaviors that actually distinguish zeron's
//  renderer live in this file's SEMANTICS, not in its parser vendor:
//
//    * a soft break is a SPACE and a hard break is a literal `\n` INSIDE the
//      same text element, so a two-line paragraph is one wrapped element and
//      not two blocks (`parser.rs:403-404`);
//    * task-list markers are LITERAL `"[x] "` text — there is no checkbox UI
//      (`parser.rs:406`);
//    * images render as LINKS on their alt text and no image is ever fetched
//      (`parser.rs:418`);
//    * raw HTML renders as literal text, block or inline (`parser.rs:264`, `405`);
//    * bare `http(s)://` URLs autolink with GFM's boundary + trailing-punctuation
//      rules, which pulldown-cmark itself does not do (`parser.rs:430`);
//    * a fenced block's trailing newline is stripped, so a block ending in `\n`
//      does not render a blank last line (`parser.rs:224`).
//
//  Every one of those is reproduced below and covered by tests.
//
//  ── What is deliberately NOT reproduced ──
//
//  zeron's `IncrementalParser` reparses from the second-to-last top-level block
//  and reports a `stable_prefix_blocks()` count. That is a performance
//  structure, not a visual one: it exists so a streaming reply costs O(tail)
//  per delta instead of O(document). This port parses the whole source each
//  delta and gets the same TREE; the caching that makes it cheap lives in the
//  renderer's per-element cache instead. Documented gap, no visual difference.
//

internal import Foundation

// MARK: - Inline model

/// Inline styling flags threaded through nested emphasis/links.
public struct SupermuxZeronInlineStyle: Sendable, Equatable, Hashable {
    public var bold = false
    public var italic = false
    public var code = false
    public var strikethrough = false
    /// Destination URL when inside a link. Images carry one too — they render
    /// as a link on the alt text.
    public var link: String?

    public init(
        bold: Bool = false,
        italic: Bool = false,
        code: Bool = false,
        strikethrough: Bool = false,
        link: String? = nil
    ) {
        self.bold = bold
        self.italic = italic
        self.code = code
        self.strikethrough = strikethrough
        self.link = link
    }
}

/// One run of identically-styled inline text.
public struct SupermuxZeronInlineRun: Sendable, Equatable {
    public var text: String
    public var style: SupermuxZeronInlineStyle

    public init(text: String, style: SupermuxZeronInlineStyle = .init()) {
        self.text = text
        self.style = style
    }
}

// MARK: - Block model

/// GFM column alignment. An unspecified column renders Left.
public enum SupermuxZeronTableAlign: Sendable, Equatable, Hashable {
    case leading
    case center
    case trailing
}

/// A markdown block. Containers nest.
public indirect enum SupermuxZeronBlock: Sendable, Equatable {
    case paragraph(runs: [SupermuxZeronInlineRun])
    case heading(level: Int, runs: [SupermuxZeronInlineRun])
    /// `language` is `nil` for a bare fence AND for an indented block — which
    /// is exactly what suppresses the header bar.
    case codeBlock(language: String?, code: String)
    case blockQuote(children: [SupermuxZeronBlock])
    /// `orderedStart` is `nil` for a bullet list; for an ordered list it is the
    /// AUTHORED start number, so `5. 6. 7.` renders as 5, 6, 7.
    case list(orderedStart: UInt64?, items: [[SupermuxZeronBlock]])
    case table(
        header: [[SupermuxZeronInlineRun]],
        rows: [[[SupermuxZeronInlineRun]]],
        align: [SupermuxZeronTableAlign]
    )
    case rule
}

// MARK: - Parser

/// The block parser.
///
/// A pure `String -> [Block]` transform; the Swift form of `parser.rs`'s free
/// functions, with no instance state to hold.
/// lint:allow namespace-enum, namespace-type — free-function module.
public enum SupermuxZeronMarkdownParser {
    /// Parse a whole source into top-level blocks, in document order.
    public static func parse(_ source: String) -> [SupermuxZeronBlock] {
        let lines = splitLines(source)
        return parseBlocks(lines[...])
    }

    /// Parse the DISPLAY tree: the source with hanging inline markers mended.
    ///
    /// zeron mends only the LAST top-level block (`parser.rs:694`) because a
    /// blank line settles a block and CommonMark keeps unclosed markers literal
    /// across it — and because mending the whole document each delta would be
    /// O(document). Mending is skipped for a trailing code block (an unclosed
    /// fence already renders verbatim and is stable), a rule, and a table.
    public static func parseDisplay(_ source: String) -> [SupermuxZeronBlock] {
        guard let split = lastBlockBoundary(source) else { return parse(source) }
        let (head, tail) = split
        switch parseBlocks(splitLines(tail)[...]).first {
        case .codeBlock, .rule, .table, .none:
            return parse(source)
        default:
            break
        }
        guard let mended = SupermuxZeronMend.closeHanging(tail) else { return parse(source) }
        return parse(head + mended)
    }

    /// The byte split between everything before the last top-level block and
    /// the block itself. `nil` when the source is a single block.
    private static func lastBlockBoundary(_ source: String) -> (String, String)? {
        // A top-level block boundary is a blank line at column 0. Fences are
        // skipped: a blank line inside a fenced block does not end it.
        let lines = splitLines(source)
        var boundary: Int?
        var fence: (marker: Character, count: Int)?
        for (i, line) in lines.enumerated() {
            if let open = fence {
                if let close = closingFence(line), close.marker == open.marker,
                   close.count >= open.count {
                    fence = nil
                }
                continue
            }
            if let open = openingFence(line) {
                fence = (open.marker, open.count)
                continue
            }
            if line.allSatisfy(\.isWhitespace) {
                // The block starts at the first non-blank line after the run.
                var j = i + 1
                while j < lines.count, lines[j].allSatisfy(\.isWhitespace) { j += 1 }
                if j < lines.count { boundary = j }
            }
        }
        guard let boundary, boundary > 0 else { return nil }
        let head = lines[..<boundary].map(String.init).joined(separator: "\n") + "\n"
        let tail = lines[boundary...].map(String.init).joined(separator: "\n")
        return (head, tail)
    }

    // MARK: Line helpers

    /// Split on `\n`, dropping a single trailing empty line so `"a\n"` is one
    /// line — Rust's `str::lines` semantics, which the boundary math relies on.
    private static func splitLines(_ source: String) -> [Substring] {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        if source.hasSuffix("\n") { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
    }

    private static func indent(_ line: Substring) -> Int {
        var n = 0
        for c in line {
            if c == " " { n += 1 } else if c == "\t" { n += 4 - (n % 4) } else { break }
        }
        return n
    }

    private static func stripIndent(_ line: Substring, _ count: Int) -> Substring {
        var line = line
        var removed = 0
        while removed < count, let first = line.first, first == " " || first == "\t" {
            removed += first == " " ? 1 : 4
            line = line.dropFirst()
        }
        return line
    }

    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    // MARK: Block scanning

    private static func parseBlocks(_ lines: ArraySlice<Substring>) -> [SupermuxZeronBlock] {
        var out: [SupermuxZeronBlock] = []
        var i = lines.startIndex
        while i < lines.endIndex {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }
            let ind = indent(line)

            // Indented code — 4+ spaces, and only where a paragraph is not
            // already open (handled by falling through from the paragraph arm).
            if ind >= 4 {
                var code: [String] = []
                while i < lines.endIndex, indent(lines[i]) >= 4 || isBlank(lines[i]) {
                    code.append(String(stripIndent(lines[i], 4)))
                    i += 1
                }
                while code.last?.allSatisfy(\.isWhitespace) == true { code.removeLast() }
                // An indented block carries NO language ⇒ no header bar.
                out.append(.codeBlock(language: nil, code: code.joined(separator: "\n")))
                continue
            }

            if let fence = openingFence(line) {
                var code: [String] = []
                i += 1
                while i < lines.endIndex {
                    if let close = closingFence(lines[i]), close.marker == fence.marker,
                       close.count >= fence.count {
                        i += 1
                        break
                    }
                    code.append(String(stripIndent(lines[i], fence.indent)))
                    i += 1
                }
                out.append(.codeBlock(language: fence.info, code: code.joined(separator: "\n")))
                continue
            }

            if isThematicBreak(line) {
                out.append(.rule)
                i += 1
                continue
            }

            if let heading = atxHeading(line) {
                out.append(.heading(level: heading.level, runs: parseInline(heading.text)))
                i += 1
                continue
            }

            if stripIndent(line, ind).first == ">" {
                var inner: [Substring] = []
                while i < lines.endIndex {
                    let l = lines[i]
                    if indent(l) < 4, stripIndent(l, indent(l)).first == ">" {
                        var body = stripIndent(l, indent(l)).dropFirst()
                        if body.first == " " { body = body.dropFirst() }
                        inner.append(body)
                        i += 1
                    } else if !isBlank(l), !startsNewBlock(l) {
                        // Lazy continuation of the quote's last paragraph.
                        inner.append(l)
                        i += 1
                    } else {
                        break
                    }
                }
                out.append(.blockQuote(children: parseBlocks(inner[...])))
                continue
            }

            if let table = parseTable(lines, &i) {
                out.append(table)
                continue
            }

            if listMarker(line) != nil {
                out.append(parseList(lines, &i))
                continue
            }

            if isHTMLBlockStart(line) {
                var text: [Substring] = []
                while i < lines.endIndex, !isBlank(lines[i]) {
                    text.append(lines[i])
                    i += 1
                }
                // Raw HTML renders as LITERAL TEXT, trailing newlines trimmed.
                let joined = text.joined(separator: "\n")
                if !joined.isEmpty {
                    out.append(.paragraph(runs: [SupermuxZeronInlineRun(text: joined)]))
                }
                continue
            }

            // Paragraph: run to a blank line or the start of another block.
            var para: [Substring] = [line]
            i += 1
            var setextLevel: Int?
            while i < lines.endIndex {
                let l = lines[i]
                if isBlank(l) { break }
                if let level = setextUnderline(l) {
                    setextLevel = level
                    i += 1
                    break
                }
                if startsNewBlock(l) { break }
                para.append(l)
                i += 1
            }
            let text = para.map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
            if let setextLevel {
                out.append(.heading(level: setextLevel, runs: parseInline(text)))
            } else {
                out.append(.paragraph(runs: parseInline(text)))
            }
        }
        return out
    }

    /// Whether a line interrupts an open paragraph.
    private static func startsNewBlock(_ line: Substring) -> Bool {
        if indent(line) >= 4 { return false }
        if openingFence(line) != nil { return true }
        if isThematicBreak(line) { return true }
        if atxHeading(line) != nil { return true }
        if stripIndent(line, indent(line)).first == ">" { return true }
        if isHTMLBlockStart(line) { return true }
        // Only a bullet or a `1.`-style marker interrupts a paragraph, and only
        // when the item is non-empty — CommonMark's list-interruption rule.
        if let marker = listMarker(line) {
            if marker.ordered == nil { return !marker.rest.isEmpty }
            return marker.start == 1 && !marker.rest.isEmpty
        }
        return false
    }

    // MARK: Leaf recognizers

    private static func openingFence(
        _ line: Substring
    ) -> (marker: Character, count: Int, info: String?, indent: Int)? {
        let ind = indent(line)
        guard ind < 4 else { return nil }
        let body = stripIndent(line, ind)
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let count = body.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        let rest = body.dropFirst(count)
        // A backtick fence's info string may not contain a backtick.
        if first == "`", rest.contains("`") { return nil }
        // The LANGUAGE is the first whitespace-delimited token, VERBATIM — not
        // title-cased, not uppercased (`parser.rs:207`).
        let info = rest.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return (first, count, info?.isEmpty == false ? info : nil, ind)
    }

    private static func closingFence(_ line: Substring) -> (marker: Character, count: Int)? {
        let ind = indent(line)
        guard ind < 4 else { return nil }
        let body = stripIndent(line, ind)
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let count = body.prefix { $0 == first }.count
        guard count >= 3, body.dropFirst(count).allSatisfy(\.isWhitespace) else { return nil }
        return (first, count)
    }

    private static func isThematicBreak(_ line: Substring) -> Bool {
        guard indent(line) < 4 else { return false }
        let body = stripIndent(line, indent(line)).filter { !$0.isWhitespace }
        guard body.count >= 3 else { return false }
        guard let first = body.first, first == "-" || first == "_" || first == "*" else {
            return false
        }
        return body.allSatisfy { $0 == first }
    }

    private static func atxHeading(_ line: Substring) -> (level: Int, text: String)? {
        guard indent(line) < 4 else { return nil }
        let body = stripIndent(line, indent(line))
        let hashes = body.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = body.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing sequence of `#`s is stripped only when space-separated.
        if text.hasSuffix("#") {
            let trailing = text.reversed().prefix { $0 == "#" }.count
            let head = String(text.dropLast(trailing))
            if head.isEmpty || head.hasSuffix(" ") {
                text = head.trimmingCharacters(in: .whitespaces)
            }
        }
        return (hashes, text)
    }

    /// A setext underline: a line of only `=` (h1) or `-` (h2) under a
    /// non-empty paragraph line. `SupermuxZeronMend`'s U+200B guard exists to
    /// stop a streaming list item from being read as one of these.
    private static func setextUnderline(_ line: Substring) -> Int? {
        guard indent(line) < 4 else { return nil }
        let body = stripIndent(line, indent(line)).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        if body.allSatisfy({ $0 == "=" }) { return 1 }
        // `---` is a thematic break, which wins; `--` and `-` are setext.
        if body.allSatisfy({ $0 == "-" }), body.count < 3 { return 2 }
        return nil
    }

    private static func isHTMLBlockStart(_ line: Substring) -> Bool {
        guard indent(line) < 4 else { return false }
        let body = stripIndent(line, indent(line))
        guard body.first == "<" else { return false }
        let second = body.dropFirst().first
        return second?.isLetter == true || second == "/" || second == "!" || second == "?"
    }

    // MARK: Lists

    private struct ListMarker {
        let ordered: Character?
        let start: UInt64
        let width: Int
        let rest: Substring
    }

    private static func listMarker(_ line: Substring) -> ListMarker? {
        let ind = indent(line)
        guard ind < 4 else { return nil }
        let body = stripIndent(line, ind)
        guard let first = body.first else { return nil }
        if first == "-" || first == "+" || first == "*" {
            let rest = body.dropFirst()
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            let content = rest.drop { $0 == " " || $0 == "\t" }
            let spaces = rest.count - content.count
            return ListMarker(
                ordered: nil,
                start: 0,
                width: ind + 1 + max(1, min(spaces, 4)),
                rest: content
            )
        }
        let digits = body.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9,
              let delim = body.dropFirst(digits.count).first,
              delim == "." || delim == ")" else { return nil }
        let rest = body.dropFirst(digits.count + 1)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let content = rest.drop { $0 == " " || $0 == "\t" }
        let spaces = rest.count - content.count
        return ListMarker(
            ordered: delim,
            start: UInt64(digits) ?? 1,
            width: ind + digits.count + 1 + max(1, min(spaces, 4)),
            rest: content
        )
    }

    private static func parseList(
        _ lines: ArraySlice<Substring>,
        _ i: inout ArraySlice<Substring>.Index
    ) -> SupermuxZeronBlock {
        guard let first = listMarker(lines[i]) else { return .paragraph(runs: []) }
        let ordered = first.ordered
        var items: [[SupermuxZeronBlock]] = []
        while i < lines.endIndex {
            guard let marker = listMarker(lines[i]) else { break }
            // A different marker family starts a NEW list, not a new item.
            guard (marker.ordered == nil) == (ordered == nil) else { break }
            var body: [Substring] = [marker.rest]
            i += 1
            while i < lines.endIndex {
                let l = lines[i]
                if isBlank(l) {
                    // A blank line only continues the item when indented
                    // content follows it.
                    var j = i + 1
                    while j < lines.endIndex, isBlank(lines[j]) { j += 1 }
                    guard j < lines.endIndex, indent(lines[j]) >= marker.width else { break }
                    body.append("")
                    i += 1
                    continue
                }
                if indent(l) >= marker.width {
                    body.append(stripIndent(l, marker.width))
                    i += 1
                    continue
                }
                if listMarker(l) != nil { break }
                if startsNewBlock(l) { break }
                // Lazy continuation of the item's paragraph.
                body.append(l)
                i += 1
            }
            items.append(parseBlocks(body[...]))
        }
        return .list(orderedStart: ordered == nil ? nil : first.start, items: items)
    }

    // MARK: Tables

    private static func parseTable(
        _ lines: ArraySlice<Substring>,
        _ i: inout ArraySlice<Substring>.Index
    ) -> SupermuxZeronBlock? {
        guard i + 1 < lines.endIndex, lines[i].contains("|") else { return nil }
        guard let align = delimiterRow(lines[i + 1]) else { return nil }
        let header = splitCells(lines[i]).map { parseInline(String($0)) }
        guard header.count == align.count else { return nil }
        i += 2
        var rows: [[[SupermuxZeronInlineRun]]] = []
        while i < lines.endIndex, !isBlank(lines[i]), lines[i].contains("|") {
            rows.append(splitCells(lines[i]).map { parseInline(String($0)) })
            i += 1
        }
        return .table(header: header, rows: rows, align: align)
    }

    private static func delimiterRow(_ line: Substring) -> [SupermuxZeronTableAlign]? {
        let cells = splitCells(line)
        guard !cells.isEmpty else { return nil }
        var align: [SupermuxZeronTableAlign] = []
        for cell in cells {
            let t = cell.trimmingCharacters(in: .whitespaces)
            let core = t.hasPrefix(":") ? String(t.dropFirst()) : t
            let dashes = core.hasSuffix(":") ? String(core.dropLast()) : core
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (t.hasPrefix(":"), t.hasSuffix(":")) {
            case (true, true): align.append(.center)
            case (false, true): align.append(.trailing)
            // GFM's `Alignment::None` maps to Left, same as an explicit `:--`.
            default: align.append(.leading)
            }
        }
        return align
    }

    /// Split a table row on UNESCAPED `|`, dropping the optional leading and
    /// trailing pipes.
    private static func splitCells(_ line: Substring) -> [Substring] {
        var cells: [Substring] = []
        var start = line.startIndex
        var idx = line.startIndex
        var escaped = false
        while idx < line.endIndex {
            let c = line[idx]
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "|" {
                cells.append(line[start..<idx])
                start = line.index(after: idx)
            }
            idx = line.index(after: idx)
        }
        cells.append(line[start...])
        if cells.first?.allSatisfy(\.isWhitespace) == true { cells.removeFirst() }
        if cells.last?.allSatisfy(\.isWhitespace) == true { cells.removeLast() }
        return cells.map { $0.drop(while: \.isWhitespace) }
    }

    // MARK: - Inline parsing

    /// Flatten inline markdown into styled runs.
    ///
    /// Adjacent identically-styled runs merge, which keeps run counts small and
    /// makes the tree canonical for equality tests (`parser.rs:526`).
    public static func parseInline(_ source: String) -> [SupermuxZeronInlineRun] {
        let nodes = SupermuxZeronInlineParser.parse(source)
        var runs: [SupermuxZeronInlineRun] = []
        flatten(nodes, style: SupermuxZeronInlineStyle(), into: &runs)
        return autolink(merge(runs))
    }

    private static func flatten(
        _ nodes: [SupermuxZeronInlineNode],
        style: SupermuxZeronInlineStyle,
        into runs: inout [SupermuxZeronInlineRun]
    ) {
        for node in nodes {
            switch node {
            case .text(let text):
                if !text.isEmpty { runs.append(SupermuxZeronInlineRun(text: text, style: style)) }
            case .code(let text):
                var s = style
                s.code = true
                if !text.isEmpty { runs.append(SupermuxZeronInlineRun(text: text, style: s)) }
            case .emphasis(let children):
                var s = style
                s.italic = true
                flatten(children, style: s, into: &runs)
            case .strong(let children):
                var s = style
                s.bold = true
                flatten(children, style: s, into: &runs)
            case .strikethrough(let children):
                var s = style
                s.strikethrough = true
                flatten(children, style: s, into: &runs)
            case .link(let children, let url):
                var s = style
                s.link = url
                flatten(children, style: s, into: &runs)
            // A SOFT break is a single SPACE; a HARD break is a literal `\n`
            // inside the same text element. Neither splits the block.
            case .softBreak:
                runs.append(SupermuxZeronInlineRun(text: " ", style: style))
            case .hardBreak:
                runs.append(SupermuxZeronInlineRun(text: "\n", style: style))
            }
        }
    }

    private static func merge(
        _ runs: [SupermuxZeronInlineRun]
    ) -> [SupermuxZeronInlineRun] {
        var out: [SupermuxZeronInlineRun] = []
        out.reserveCapacity(runs.count)
        for run in runs where !run.text.isEmpty {
            if let last = out.last, last.style == run.style {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }

    // MARK: Autolinking (GFM, which pulldown-cmark has no option for)

    /// Promote bare `http(s)://` URLs into link runs.
    ///
    /// Agents paste naked PR/issue URLs constantly. Runs already inside a link
    /// or a code span pass through untouched, and the pass is idempotent.
    /// Applied AFTER merging: pulldown splits text events at would-be emphasis
    /// characters, so scanning per-event would truncate a URL at every
    /// underscore (`parser.rs:381`).
    private static func autolink(
        _ runs: [SupermuxZeronInlineRun]
    ) -> [SupermuxZeronInlineRun] {
        var out: [SupermuxZeronInlineRun] = []
        for run in runs {
            if run.style.link != nil || run.style.code {
                out.append(run)
                continue
            }
            var rest = Substring(run.text)
            while let at = urlStart(rest) {
                let from = rest[at...]
                let scheme = from.hasPrefix("https://") ? 8 : 7
                let len = bareURLLength(from)
                if len <= scheme {
                    // A scheme with nothing after it stays text — and must not
                    // be re-found, or this loops forever.
                    let head = rest[..<at]
                    let schemeEnd = from.index(from.startIndex, offsetBy: scheme)
                    out.append(
                        SupermuxZeronInlineRun(
                            text: String(head) + String(from[..<schemeEnd]),
                            style: run.style
                        )
                    )
                    rest = from[schemeEnd...]
                    continue
                }
                out.append(SupermuxZeronInlineRun(text: String(rest[..<at]), style: run.style))
                let urlEnd = from.index(from.startIndex, offsetBy: len)
                var linked = run.style
                linked.link = String(from[..<urlEnd])
                out.append(SupermuxZeronInlineRun(text: String(from[..<urlEnd]), style: linked))
                rest = from[urlEnd...]
            }
            out.append(SupermuxZeronInlineRun(text: String(rest), style: run.style))
        }
        return merge(out)
    }

    /// First viable `http(s)://`: not glued to a preceding alphanumeric, per
    /// GFM's boundary rule — `foohttps://…` stays text.
    private static func urlStart(_ text: Substring) -> Substring.Index? {
        var from = text.startIndex
        while let found = text[from...].range(of: "http") {
            let at = found.lowerBound
            let after = text[at...]
            let isScheme = after.hasPrefix("http://") || after.hasPrefix("https://")
            let boundary = at == text.startIndex
                || !(text[text.index(before: at)].isLetter || text[text.index(before: at)].isNumber)
            if isScheme, boundary { return at }
            from = found.upperBound
            if from >= text.endIndex { break }
        }
        return nil
    }

    /// Length (in CHARACTERS) of the bare URL at the start of `text`.
    ///
    /// Runs to whitespace or one of `< > " ' \``, then trims the trailing
    /// punctuation GFM excludes. A closing paren stays only when an opener
    /// inside the URL balances it: `…/Foo_(bar))` keeps one and sheds one.
    private static func bareURLLength(_ text: Substring) -> Int {
        let end = text.firstIndex { $0.isWhitespace || "<>\"'`".contains($0) } ?? text.endIndex
        var url = text[..<end]
        while let last = url.last {
            let trim: Bool
            switch last {
            case ".", ",", ";", ":", "!", "?", "*", "_", "~":
                trim = true
            case ")":
                trim = url.filter { $0 == "(" }.count < url.filter { $0 == ")" }.count
            default:
                trim = false
            }
            if !trim { break }
            url = url.dropLast()
        }
        return url.count
    }
}
