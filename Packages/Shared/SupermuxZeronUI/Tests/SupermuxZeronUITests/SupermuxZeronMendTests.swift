import Testing
@testable import SupermuxZeronUI

/// The streaming marker repair, table-driven from spec 05 §5.3 and asserted
/// case-for-case against `mend.rs`'s own test module.
///
/// These matter because a mend that fires when it should not makes text FLASH
/// styled and back, and a mend that fails to fire makes the paragraph's tail
/// REFLOW when the closer arrives — the artifact the whole module exists to
/// remove.
struct SupermuxZeronMendTests {
    /// `close_hanging` returns the repaired string.
    private func mends(_ input: String, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(
            SupermuxZeronMend.closeHanging(input) == expected,
            "\(input.debugDescription) should mend",
            sourceLocation: sourceLocation
        )
    }

    /// `close_hanging` returns `nil` — zero further work, the common case.
    private func stays(_ input: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(
            SupermuxZeronMend.closeHanging(input) == nil,
            "\(input.debugDescription) should stay literal",
            sourceLocation: sourceLocation
        )
    }

    @Test("balanced text needs nothing")
    func balancedTextNeedsNothing() {
        stays("plain words, no markers")
        stays("a **b** and *c* and `d` and ~~e~~")
        stays("[docs](https://x.dev) done")
        stays("")
    }

    @Test("bold and italic close")
    func boldAndItalicClose() {
        mends("**bold", "**bold**")
        mends("some *em", "some *em*")
        mends("a __b", "a __b__")
        mends("a _b", "a _b_")
        mends("***both", "***both***")
    }

    @Test("half-streamed closers complete")
    func halfStreamedClosersComplete() {
        mends("**bold*", "**bold**")
        mends("__b_", "__b__")
        mends("~~gone~", "~~gone~~")
    }

    @Test("nested closers come innermost-first")
    func nestedClosersComeInnermostFirst() {
        mends("**a *b", "**a *b***")
        mends("*a **b", "*a **b***")
        mends("_a **b", "_a **b**_")
    }

    /// A bare opener with no substantive content yet stays literal until real
    /// content arrives — otherwise every `**` keystroke would flash bold.
    @Test("bare openers stay literal until content")
    func bareOpenersStayLiteral() {
        stays("**")
        stays("text **")
        stays("text ** ")
        stays("*")
        stays("~~")
        stays("`")
    }

    /// `**bold **` would be left-flanking only and would not close, so the
    /// closer goes BEFORE the trailing whitespace.
    @Test("closers insert before trailing whitespace")
    func closersInsertBeforeTrailingWhitespace() {
        mends("**bold ", "**bold** ")
        mends("*em\n", "*em*\n")
    }

    @Test("intraword markers and escapes stay literal")
    func intrawordAndEscapes() {
        stays("2*3 equals 6")
        stays("snake_case_name")
        stays("20~25 degrees")
        stays(#"\*not emphasis"#)
        stays(#"a \** b"#)
    }

    @Test("list markers are not emphasis openers")
    func listMarkersAreNotOpeners() {
        stays("* item one")
        stays("- a\n* b")
    }

    @Test("strikethrough closes, a single tilde never opens")
    func strikethroughCloses() {
        mends("~~gone", "~~gone~~")
        stays("~single~x")
    }

    /// Code shields emphasis markers, and a shorter backtick run inside a span
    /// is CONTENT, not a closer.
    @Test("inline code closes and shields markers")
    func inlineCodeClosesAndShields() {
        mends("`code", "`code`")
        mends("call `a ** b", "call `a ** b`")
        mends("``a`", "``a```")
        stays("`done` after")
    }

    @Test("links mend to the pending sentinel")
    func linksMendToPendingSentinel() {
        mends("[docs](https://x.dev/lo", "[docs](zeron:pending-link)")
        mends("[docs](", "[docs](zeron:pending-link)")
        mends("see [do", "see [do](zeron:pending-link)")
        mends("![alt](https://x/i.p", "![alt](zeron:pending-link)")
        stays("see [")
        // A completed bracket with no `(` is not a link.
        stays("[x] task-like")
    }

    @Test("link URLs allow balanced nested parens")
    func linkURLsAllowNestedParens() {
        stays("[a](https://x.dev/(y)) done")
        mends("[a](https://x.dev/(y", "[a](zeron:pending-link)")
    }

    /// A `[` open splits the closers: delimiters opened INSIDE the link text
    /// close before the `](…)`, ones opened before it close after.
    @Test("emphasis inside link text closes inside")
    func emphasisInsideLinkText() {
        mends("[**a", "[**a**](zeron:pending-link)")
        mends("**a [b", "**a [b](zeron:pending-link)**")
    }

    /// Emphasis opened inside a COMPLETED `[…]` and never closed there stays
    /// literal, exactly as the final parse decides.
    @Test("emphasis unclosed in a completed bracket is dropped")
    func emphasisInCompletedBracketDropped() {
        stays("[**a] done")
    }

    /// A trailing line of 1–2 `-`/`=` under text is a setext underline to the
    /// parser but almost always a streaming list item; the zero-width space
    /// breaks that reading invisibly until the next characters decide.
    @Test("setext partials get a zero-width space")
    func setextPartialsGetZeroWidthSpace() {
        mends("para\n-", "para\n-\u{200B}")
        mends("para\n--", "para\n--\u{200B}")
        mends("para\n=", "para\n=\u{200B}")
        // A real hr / settled setext is left alone.
        stays("para\n---")
        // No line above, and an EMPTY line above, are both left alone.
        stays("-")
        stays("\n-")
        // Closers go ABOVE the underline line.
        mends("**b\n-", "**b**\n-\u{200B}")
    }

    @Test("the pending-link sentinel is exactly zeron's")
    func pendingLinkSentinel() {
        #expect(SupermuxZeronMend.pendingLinkURL == "zeron:pending-link")
        #expect(SupermuxZeronMend.setextGuard == "\u{200B}")
    }

    /// The scanner is char-indexed, so a multi-byte scalar before a hanging
    /// marker must not shift the insertion point.
    @Test("multi-byte text mends at the right offset")
    func multiByteMends() {
        mends("café **bold", "café **bold**")
        mends("→ `code", "→ `code`")
        mends("emoji 🎉 **b", "emoji 🎉 **b**")
    }
}
