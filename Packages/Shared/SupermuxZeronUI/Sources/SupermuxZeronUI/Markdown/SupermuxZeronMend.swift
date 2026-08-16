//
//  SupermuxZeronMend.swift
//  SupermuxZeronUI
//
//  Streaming marker repair. A line-for-line port of
//  `/tmp/zeron-comet/crates/ui/src/markdown/mend.rs` (spec 05 §5).
//
//  ── What it is for ──
//
//  While a block streams, an unclosed `**bold`, `*em`, `` `code ``, `~~strike`
//  or `[link](partial-url` parses as LITERAL TEXT. When the closing marker
//  finally arrives the marker characters vanish and the run restyles, so wrap
//  points shift and the paragraph's tail visibly reflows mid-stream. That
//  reflow is the single most jarring artifact of naive streaming markdown.
//
//  The fix is to append synthetic closers to the DISPLAY parse only. The
//  canonical tree is untouched, so a marker that genuinely never closes settles
//  honestly with ONE flip when the row completes, instead of jittering
//  throughout.
//
//  ── Accepted quirks (reproduce them, do not "fix" them) ──
//
//  The scanner is deliberately approximate; streamdown ships the same
//  trade-off, preferring "stable and close to the final parse" over exact
//  CommonMark delimiter resolution, because any mid-stream misjudgment is
//  repaired by the very next append or by the settle. Known: intraword `**`
//  closes (`2**3` briefly bolds the `3`), and whitespace-only or marker-only
//  content after an opener leaves the opener literal for a chunk.
//
//  ── Cost ──
//
//  One pass over the text plus the returned allocation, and `nil` — zero
//  further work — whenever nothing hangs, which is the overwhelmingly common
//  case. Callers feed it only the LAST top-level block, so per-append work is
//  O(tail).
//

internal import Foundation

/// The streaming marker repair (`mend.rs`).
///
/// A pure `String -> String?` transform with no instance state, ported 1:1
/// from a Rust free-function module.
/// lint:allow namespace-enum, namespace-type — free-function module.
public enum SupermuxZeronMend {
    /// Sentinel destination for a link whose URL is still streaming.
    ///
    /// The renderer styles it like any other link — full `theme.text` plus the
    /// muted underline — but must NOT register it as clickable, so the URL's
    /// completion changes nothing visually (`mend.rs:44`, `render.rs:576`).
    public static let pendingLinkURL = "zeron:pending-link"

    /// The zero-width space that breaks a streaming list item's misreading as a
    /// setext underline.
    public static let setextGuard: Character = "\u{200B}"

    /// One unclosed emphasis-family delimiter run (`*`, `_`, or `~~`).
    private struct OpenDelim {
        let ch: Character
        var len: Int
        /// Char index just past the run: nesting order for closers, and the
        /// content-must-follow guard.
        let pos: Int
    }

    /// Repair hanging inline markers in a streaming block's source.
    ///
    /// Returns `nil` when the text needs no repair.
    public static func closeHanging(_ text: String) -> String? {
        // Char-indexed exactly as the Rust does: every `pos` below is a
        // CHARACTER index, and the two byte-slicing sites convert back through
        // the stored `String.Index`.
        let cs: [(index: String.Index, char: Character)] = zip(text.indices, text)
            .map { (index: $0, char: $1) }
        let n = cs.count
        func at(_ i: Int) -> Character? { i >= 0 && i < n ? cs[i].char : nil }

        var delims: [OpenDelim] = []
        // Char indices of unmatched `[`.
        var brackets: [Int] = []
        // Open inline code span: (backtick run length, content char index).
        var code: (ticks: Int, contentPos: Int)?
        // Char index of the last SUBSTANTIVE character — content that justifies
        // closing an opener (not whitespace, not a bare marker).
        var lastContent: Int?
        // Char index of the `]` of a `](…` whose URL runs off the end.
        var pendingURL: Int?

        var i = 0
        scan: while i < n {
            let c = cs[i].char
            if code == nil, c == "\\" {
                // Escaped char: both literal; the escapee still counts as content.
                if i + 1 < n { lastContent = i + 1 }
                i += 2
                continue
            }
            if c == "`" {
                let run = runLength(cs, i)
                if let open = code {
                    // A span closes only on a run of the OPENING length.
                    if run == open.ticks {
                        code = nil
                    } else {
                        lastContent = i + run - 1
                    }
                } else {
                    code = (ticks: run, contentPos: i + run)
                }
                i += run
                continue
            }
            if code != nil {
                lastContent = i
                i += 1
                continue
            }
            switch c {
            case "*", "_", "~":
                let run = runLength(cs, i)
                delimiter(&delims, cs, c, run, i, &lastContent)
                i += run
            case "[":
                brackets.append(i)
                i += 1
            case "]":
                if let open = brackets.popLast() {
                    // Emphasis opened inside a COMPLETED `[…]` and never closed
                    // there stays literal — as the final parse decides too.
                    delims.removeAll { $0.pos >= open }
                    if at(i + 1) == "(" {
                        // Consume the URL through its balanced `)`.
                        var j = i + 2
                        var depth = 0
                        url: while true {
                            switch at(j) {
                            case "(": depth += 1
                            case ")" where depth == 0: break url
                            case ")": depth -= 1
                            case nil:
                                pendingURL = i
                                break url
                            default: break
                            }
                            j += 1
                        }
                        if pendingURL != nil { break scan }
                        lastContent = j
                        i = j + 1
                        continue
                    }
                }
                lastContent = i
                i += 1
            case let c where c.isWhitespace:
                i += 1
            default:
                lastContent = i
                i += 1
            }
        }

        // Text ends inside a link/image URL: drop the partial URL, keep the text.
        if let close = pendingURL {
            return String(text[..<cs[close].index]) + "](\(pendingLinkURL))"
        }

        // Collect closers INNERMOST-FIRST (descending open position). A `[` open
        // splits the emphasis closers naturally: delimiters opened inside the
        // link text close before the `](…)`, ones opened before it close after.
        var pending: [(pos: Int, closer: String)] = []
        if let open = code, let lc = lastContent, lc >= open.contentPos {
            pending.append((open.contentPos, String(repeating: "`", count: open.ticks)))
        }
        for d in delims where lastContent.map({ $0 >= d.pos }) == true {
            pending.append((d.pos, String(repeating: d.ch, count: d.len)))
        }
        if let open = brackets.last, let lc = lastContent, lc > open {
            pending.append((open, "](\(pendingLinkURL))"))
        }
        // A stable descending sort: Rust's `sort_by` is stable, and two closers
        // can share a position when a zero-width span opens where another closed.
        pending = pending.enumerated()
            .sorted { a, b in
                a.element.pos == b.element.pos ? a.offset < b.offset : a.element.pos > b.element.pos
            }
            .map(\.element)
        let closers = pending.map(\.closer).joined()

        // A trailing line of only `-`/`--`/`=`/`==` under text is a setext
        // underline (or hr) to the parser but almost always a streaming list
        // item; a zero-width space breaks the reading invisibly until the next
        // characters decide.
        let setext = setextPartial(text)

        if closers.isEmpty, !setext { return nil }
        if setext {
            // Closers belong to the paragraph content ABOVE the underline line.
            if let nl = text.lastIndex(of: "\n"), !closers.isEmpty {
                return String(text[..<nl]) + closers + String(text[nl...]) + String(setextGuard)
            }
            return text + String(setextGuard)
        }
        // Insert BEFORE trailing whitespace: a closer after a trailing space is
        // not right-flanking and would not close.
        let end = trimmedEndIndex(text)
        return String(text[..<end]) + closers + String(text[end...])
    }

    // MARK: - Scanner internals

    private static func runLength(
        _ cs: [(index: String.Index, char: Character)],
        _ i: Int
    ) -> Int {
        let c = cs[i].char
        var n = 0
        while i + n < cs.count, cs[i + n].char == c { n += 1 }
        return n
    }

    /// Match or open one delimiter run.
    ///
    /// Closes against the innermost same-char opener (partially, for
    /// half-streamed closers like `**a*`); delimiters opened after a consumed
    /// opener were inside the closed span and stay literal, exactly as the final
    /// parse treats them.
    private static func delimiter(
        _ delims: inout [OpenDelim],
        _ cs: [(index: String.Index, char: Character)],
        _ c: Character,
        _ run: Int,
        _ i: Int,
        _ lastContent: inout Int?
    ) {
        let end = i + run
        // GFM strikethrough is `~~` only; longer tilde runs are literal. A run
        // of one may still be the half-streamed first tilde of a closing `~~`,
        // so it proceeds to the matcher (but never opens).
        if c == "~", run > 2 {
            lastContent = end - 1
            return
        }
        let prev: Character? = i > 0 ? cs[i - 1].char : nil
        let next: Character? = end < cs.count ? cs[end].char : nil
        func isWord(_ ch: Character?) -> Bool {
            guard let ch else { return false }
            return ch.isLetter || ch.isNumber
        }
        // Intraword `_` never delimits (CommonMark); intraword single `*` is
        // treated the same, conservatively — `2*3` must not flash italic.
        if isWord(prev), isWord(next), c == "_" || (c == "*" && run == 1) {
            lastContent = end - 1
            return
        }
        let canClose = prev.map { !$0.isWhitespace } ?? false
        let canOpen = next.map { !$0.isWhitespace } ?? false
        var rest = run
        if canClose, let k = delims.lastIndex(where: { $0.ch == c }) {
            let take = min(rest, delims[k].len)
            delims[k].len -= take
            rest -= take
            let keep = delims[k].len == 0 ? k : k + 1
            delims.removeSubrange(keep...)
        }
        if rest > 0 {
            // A lone `~` never opens; `~` entries of len 1 exist only as the
            // remainder of a half-streamed closer.
            if canOpen, c != "~" || rest == 2 {
                delims.append(OpenDelim(ch: c, len: rest, pos: end))
            } else {
                lastContent = end - 1
            }
        }
    }

    /// Last line is only 1–2 `-` or `=` (no trailing whitespace) under a
    /// non-empty line — the incomplete-setext ambiguity.
    private static func setextPartial(_ text: String) -> Bool {
        guard let nl = text.lastIndex(of: "\n") else { return false }
        let last = text[text.index(after: nl)...]
        let trimmed = last.drop { $0.isWhitespace }
        func underline(_ c: Character) -> Bool {
            !trimmed.isEmpty && trimmed.count <= 2 && trimmed.allSatisfy { $0 == c }
        }
        guard underline("-") || underline("=") else { return false }
        guard let above = rustLines(text[..<nl]).last else { return false }
        return !above.allSatisfy(\.isWhitespace)
    }

    /// Rust's `str::lines`, which — unlike `split(separator:)` — yields NO
    /// trailing empty line for a string that ends in a newline. `"para\n"`
    /// is one line, not two, and that difference decides whether
    /// `"para\n\n-"` mends.
    private static func rustLines(_ s: Substring) -> [Substring] {
        guard !s.isEmpty else { return [] }
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        if s.hasSuffix("\n") { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
    }

    /// The index one past the last non-whitespace character — Rust's
    /// `text.trim_end().len()` as a `String.Index`.
    private static func trimmedEndIndex(_ text: String) -> String.Index {
        var end = text.endIndex
        while end > text.startIndex {
            let prev = text.index(before: end)
            guard text[prev].isWhitespace else { break }
            end = prev
        }
        return end
    }
}
