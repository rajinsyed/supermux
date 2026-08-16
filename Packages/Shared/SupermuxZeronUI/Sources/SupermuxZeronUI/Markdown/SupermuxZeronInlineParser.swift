//
//  SupermuxZeronInlineParser.swift
//  SupermuxZeronUI
//
//  CommonMark inline parsing: code spans, emphasis, links, images,
//  strikethrough, breaks. The inline half of `parser.rs`'s pulldown-cmark use.
//
//  Only the three extensions zeron enables are honored: TABLES (block level),
//  STRIKETHROUGH, TASKLISTS. No smart punctuation, no footnotes, no math, no
//  heading attributes.
//
//  ── Behaviors that are load-bearing for the port ──
//
//  * A code span is resolved FIRST and shields every marker inside it, exactly
//    as CommonMark specifies and as `mend.rs` assumes.
//  * `![alt](url)` produces a LINK node on the alt text. No image is ever
//    fetched or drawn by this renderer.
//  * Raw inline HTML is literal text.
//  * A footnote reference renders as the literal `[label]`.
//  * A task-list marker is the literal text `"[x] "` / `"[ ] "`, emitted by the
//    block parser before the item's inline content.
//

internal import Foundation

/// One inline node. The tree is flattened into styled runs by
/// ``SupermuxZeronMarkdownParser/parseInline(_:)``.
public indirect enum SupermuxZeronInlineNode: Sendable, Equatable {
    case text(String)
    case code(String)
    case emphasis([SupermuxZeronInlineNode])
    case strong([SupermuxZeronInlineNode])
    case strikethrough([SupermuxZeronInlineNode])
    case link([SupermuxZeronInlineNode], url: String)
    /// A single `\n` inside a paragraph: renders as ONE SPACE.
    case softBreak
    /// A trailing `\` or two trailing spaces: renders as a literal `\n` in the
    /// SAME text element, so the paragraph stays one wrapped element.
    case hardBreak
}

/// The inline scanner.
///
/// A pure `String -> [Node]` transform, the Swift form of a free-function
/// module, with no instance state.
/// lint:allow namespace-enum, namespace-type — free-function module.
public enum SupermuxZeronInlineParser {
    public static func parse(_ source: String) -> [SupermuxZeronInlineNode] {
        var scanner = Scanner(chars: Array(source), at: 0)
        return scanner.parseNodes(until: .endOfInput)
    }

    // MARK: Scanner

    /// What ends a nested inline run.
    ///
    /// An enum rather than a closure: an Optional closure parameter is
    /// implicitly `@escaping`, which a `mutating` method cannot capture `self`
    /// into. The terminator set is closed anyway — three cases and "end of
    /// input" — so naming them reads better than a predicate.
    private enum Terminator {
        case endOfInput
        case closingBracket
        case emphasis(marker: Character, run: Int)
        case strikethrough
    }

    private struct Scanner {
        let chars: [Character]
        var at: Int

        var isAtEnd: Bool { at >= chars.count }

        func peek(_ offset: Int = 0) -> Character? {
            let i = at + offset
            return i >= 0 && i < chars.count ? chars[i] : nil
        }

        /// Whether `terminator` matches at the cursor. Never consumes.
        func matches(_ terminator: Terminator) -> Bool {
            switch terminator {
            case .endOfInput:
                return false
            case .closingBracket:
                return peek() == "]"
            case .emphasis(let marker, let run):
                guard peek() == marker else { return false }
                // A closer must be preceded by non-whitespace.
                guard let prev = peek(-1), !prev.isWhitespace else { return false }
                // Intraword `_` never delimits (CommonMark).
                if marker == "_", isWord(prev), isWord(peek(runLength(marker))) { return false }
                return runLength(marker) >= run
            case .strikethrough:
                return peek() == "~" && runLength("~") == 2
            }
        }

        /// Parse until `terminator` matches at the cursor (not consumed), or the
        /// end of input.
        mutating func parseNodes(
            until terminator: Terminator
        ) -> [SupermuxZeronInlineNode] {
            var nodes: [SupermuxZeronInlineNode] = []
            var literal = ""

            func flush() {
                if !literal.isEmpty {
                    nodes.append(.text(literal))
                    literal = ""
                }
            }

            while !isAtEnd {
                if matches(terminator) { break }
                let c = chars[at]

                // Backslash escape. A trailing backslash before a newline is a
                // HARD BREAK; everything else escapes the next punctuation.
                if c == "\\" {
                    if peek(1) == "\n" {
                        flush()
                        nodes.append(.hardBreak)
                        at += 2
                        continue
                    }
                    if let next = peek(1), next.isPunctuation || next.isSymbol {
                        literal.append(next)
                        at += 2
                        continue
                    }
                    literal.append(c)
                    at += 1
                    continue
                }

                // Code spans bind tighter than everything else and shield every
                // marker inside them.
                if c == "`" {
                    if let span = scanCodeSpan() {
                        flush()
                        nodes.append(.code(span))
                        continue
                    }
                    literal.append(c)
                    at += 1
                    continue
                }

                if c == "\n" {
                    // Two+ trailing spaces before the newline are a hard break.
                    let hard = literal.hasSuffix("  ")
                    while literal.hasSuffix(" ") { literal.removeLast() }
                    flush()
                    nodes.append(hard ? .hardBreak : .softBreak)
                    at += 1
                    // Leading whitespace on the continuation line is dropped.
                    while peek() == " " || peek() == "\t" { at += 1 }
                    continue
                }

                if c == "!" || c == "[" {
                    if let link = scanLink() {
                        flush()
                        nodes.append(link)
                        continue
                    }
                    literal.append(c)
                    at += 1
                    continue
                }

                if c == "*" || c == "_" {
                    if let emphasis = scanEmphasis(c) {
                        flush()
                        nodes.append(emphasis)
                        continue
                    }
                    // Not a valid opener — emit the whole run literally so the
                    // scanner cannot re-enter it and loop.
                    let run = runLength(c)
                    literal.append(String(repeating: c, count: run))
                    at += run
                    continue
                }

                if c == "~", runLength("~") == 2 {
                    if let strike = scanStrikethrough() {
                        flush()
                        nodes.append(strike)
                        continue
                    }
                    literal.append("~~")
                    at += 2
                    continue
                }

                literal.append(c)
                at += 1
            }
            flush()
            return nodes
        }

        func runLength(_ c: Character) -> Int {
            var n = 0
            while at + n < chars.count, chars[at + n] == c { n += 1 }
            return n
        }

        /// A code span: a backtick run closed by a run of the SAME length.
        ///
        /// One leading and one trailing space are stripped when the content is
        /// not all spaces, per CommonMark.
        mutating func scanCodeSpan() -> String? {
            let ticks = runLength("`")
            var i = at + ticks
            while i < chars.count {
                guard chars[i] == "`" else { i += 1; continue }
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                if run == ticks {
                    var content = String(chars[(at + ticks)..<i])
                    // A line ending inside a code span becomes a space.
                    content = content.replacingOccurrences(of: "\n", with: " ")
                    if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
                       !content.allSatisfy({ $0 == " " }) {
                        content = String(content.dropFirst().dropLast())
                    }
                    at = i + run
                    return content
                }
                i += run
            }
            return nil
        }

        /// `[text](url)`, `![alt](url)`, or the literal fallback.
        ///
        /// An IMAGE returns a `.link` on its alt text: `parser.rs:418` maps
        /// both `Tag::Link` and `Tag::Image` to the same destination, so the
        /// renderer never fetches or draws an image.
        mutating func scanLink() -> SupermuxZeronInlineNode? {
            let start = at
            let isImage = chars[at] == "!"
            if isImage {
                guard peek(1) == "[" else { return nil }
                at += 1
            }
            guard chars[at] == "[" else { at = start; return nil }
            at += 1
            var inner = parseNodes(until: .closingBracket)
            guard peek() == "]" else { at = start; return nil }
            at += 1
            guard peek() == "(" else {
                // A completed `[…]` with no destination is literal text — which
                // is exactly what makes `[x] task-like` render as itself.
                at = start
                return nil
            }
            at += 1
            var depth = 0
            var url = ""
            while !isAtEnd {
                let c = chars[at]
                if c == "\\", let next = peek(1) {
                    url.append(next)
                    at += 2
                    continue
                }
                // Link URLs allow BALANCED nested parens.
                if c == "(" { depth += 1 }
                if c == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                url.append(c)
                at += 1
            }
            guard peek() == ")" else { at = start; return nil }
            at += 1
            // A destination in `<…>` sheds the brackets; a title after the URL
            // is dropped.
            var dest = url.trimmingCharacters(in: .whitespaces)
            if dest.hasPrefix("<"), dest.hasSuffix(">"), dest.count >= 2 {
                dest = String(dest.dropFirst().dropLast())
            } else if let space = dest.firstIndex(where: \.isWhitespace) {
                dest = String(dest[..<space])
            }
            if inner.isEmpty { inner = [.text("")] }
            return .link(inner, url: dest)
        }

        /// `*em*`, `**strong**`, `***both***`, and the `_` forms.
        mutating func scanEmphasis(_ marker: Character) -> SupermuxZeronInlineNode? {
            let start = at
            let run = runLength(marker)
            // Intraword `_` never delimits (CommonMark).
            if marker == "_", isWord(peek(-1)), isWord(peek(run)) { return nil }
            // An opener must be followed by non-whitespace.
            guard let next = peek(run), !next.isWhitespace else { return nil }
            // `***x***` is strong wrapping emphasis.
            let take = min(run, 3)
            at += take
            let children = parseNodes(until: .emphasis(marker: marker, run: take))
            guard peek() == marker, runLength(marker) >= take, !children.isEmpty else {
                at = start
                return nil
            }
            at += take
            switch take {
            case 1: return .emphasis(children)
            case 2: return .strong(children)
            default: return .strong([.emphasis(children)])
            }
        }

        /// `~~strike~~`. GFM strikethrough is a run of EXACTLY two tildes;
        /// longer runs are literal.
        mutating func scanStrikethrough() -> SupermuxZeronInlineNode? {
            let start = at
            guard let next = peek(2), !next.isWhitespace else { return nil }
            at += 2
            let children = parseNodes(until: .strikethrough)
            guard peek() == "~", runLength("~") == 2, !children.isEmpty else {
                at = start
                return nil
            }
            at += 2
            return .strikethrough(children)
        }

        func isWord(_ c: Character?) -> Bool {
            guard let c else { return false }
            return c.isLetter || c.isNumber
        }
    }
}
