import Foundation
import SupermuxKit
import Testing

/// `SupermuxTerminalReplyFilter` drops the terminal query replies a device
/// mirror's local Ghostty writes while it parses the other Mac's output (the
/// other Mac's own terminal already answered them), and passes every other
/// byte through unchanged.
///
/// Ways it could fail, each covered below:
/// 1. It drops input the user produced: a keystroke encoding (kitty CSI u,
///    modified arrows, SS3 keys), a mouse report (SGR, urxvt, X10), a focus
///    event or a bracketed-paste marker.
/// 2. It keeps a reply: DA1/DA2, CPR/DECXCPR, DSR, DECRPM, the kitty flags
///    reply, XTWINOPS reports, any OSC/DCS/APC/PM/SOS string reply, whether
///    the string ends in BEL or ST.
/// 3. It eats more than the reply: the text around it, or a whole chunk.
/// 4. It mangles an incomplete sequence at the end of a chunk (bare ESC,
///    "ESC [", an unterminated OSC) instead of passing it through.
/// 5. It corrupts UTF-8 text or reorders bytes.
/// 6. It is slow on a large paste.
struct SupermuxTerminalReplyFilterTests {
    private func filtered(_ text: String) -> String {
        String(decoding: SupermuxTerminalReplyFilter.removingReplies(from: Data(text.utf8)), as: UTF8.self)
    }

    // MARK: 1. User input survives

    @Test(arguments: [
        "\u{1B}[27u",          // kitty Escape
        "\u{1B}[13;2u",        // kitty Shift+Enter
        "\u{1B}[99;5u",        // kitty Ctrl+C
        "\u{1B}[1;5A",         // Ctrl+Up
        "\u{1B}[A",            // Up
        "\u{1B}OA",            // Up, application cursor mode
        "\u{1B}OP",            // F1
        "\u{1B}[15~",          // F5
        "\u{1B}[3;5~",         // Ctrl+Delete
        "\u{1B}b",             // Meta+b
        "\u{1B}",              // bare Escape
        "\u{1B}\u{7F}",        // Meta+Backspace
    ])
    func keepsKeyEncodings(_ key: String) {
        #expect(filtered(key) == key)
    }

    @Test(arguments: [
        "\u{1B}[<0;10;5M",     // SGR press
        "\u{1B}[<0;10;5m",     // SGR release
        "\u{1B}[<35;80;24M",   // SGR motion
        "\u{1B}[<64;3;4M",     // SGR wheel
        "\u{1B}[32;10;5M",     // urxvt
        "\u{1B}[M !!",         // X10
        "\u{1B}[I",            // focus in
        "\u{1B}[O",            // focus out
        "\u{1B}[200~hello\u{1B}[201~", // bracketed paste
    ])
    func keepsMouseFocusAndPaste(_ input: String) {
        #expect(filtered(input) == input)
    }

    // MARK: 2. Replies are dropped

    @Test(arguments: [
        "\u{1B}[?62;22c",                 // DA1
        "\u{1B}[?1;2c",                   // DA1 (VT100)
        "\u{1B}[>1;10;0c",                // DA2
        "\u{1B}[12;40R",                  // CPR
        "\u{1B}[?12;40;1R",               // DECXCPR
        "\u{1B}[0n",                      // DSR OK
        "\u{1B}[3n",                      // DSR failure
        "\u{1B}[?997;1n",                 // color scheme report
        "\u{1B}[?2004;1$y",               // DECRPM private
        "\u{1B}[4;2$y",                   // DECRPM ANSI
        "\u{1B}[?1u",                     // kitty flags reply
        "\u{1B}[?0u",                     // kitty flags reply, none
        "\u{1B}[4;600;800t",              // window size in pixels
        "\u{1B}[6;16;8t",                 // cell size
        "\u{1B}[8;24;80t",                // text area size
        "\u{1B}]11;rgb:0000/0000/0000\u{07}",       // OSC 11, BEL
        "\u{1B}]10;rgb:ffff/ffff/ffff\u{1B}\\",     // OSC 10, ST
        "\u{1B}]4;1;rgb:cccc/0000/0000\u{1B}\\",    // OSC 4
        "\u{1B}]52;c;aGVsbG8=\u{07}",               // OSC 52 clipboard
        "\u{1B}P>|ghostty 1.2.0\u{1B}\\",           // XTVERSION
        "\u{1B}P1$r0m\u{1B}\\",                     // DECRQSS
        "\u{1B}P1+r544e=787465726d\u{1B}\\",        // XTGETTCAP
        "\u{1B}P!|00000000\u{1B}\\",                // DA3
        "\u{1B}_Gi=1;OK\u{1B}\\",                   // kitty graphics APC
        "\u{1B}^privacy\u{1B}\\",                   // PM
        "\u{1B}Xstart of string\u{1B}\\",           // SOS
    ])
    func dropsReplies(_ reply: String) {
        #expect(filtered(reply) == "")
    }

    // MARK: 3. Only the reply goes

    @Test func dropsOnlyTheReplyBetweenUserBytes() {
        #expect(filtered("ab\u{1B}[?62;22c\u{1B}[27ucd") == "ab\u{1B}[27ucd")
        #expect(filtered("\u{1B}]11;rgb:0/0/0\u{07}x\u{1B}[12;40Ry") == "xy")
    }

    @Test func dropsSeveralRepliesInOneChunk() {
        #expect(filtered("\u{1B}[?1u\u{1B}[?62;22c\u{1B}[0n") == "")
    }

    // MARK: 4. Incomplete sequences pass through

    @Test(arguments: [
        "\u{1B}",
        "abc\u{1B}",
        "\u{1B}[",
        "\u{1B}[?62;2",
        "\u{1B}]11;rgb:0000",
        "\u{1B}P>|ghostty",
        "\u{1B}P>|ghostty\u{1B}",
    ])
    func passesIncompleteSequencesThrough(_ input: String) {
        #expect(filtered(input) == input)
    }

    @Test func keepsMalformedControlSequence() {
        // A byte outside the CSI grammar ends the sequence without a final.
        let input = "\u{1B}[1\u{01}c"
        #expect(filtered(input) == input)
    }

    // MARK: 5. Text is untouched

    @Test func keepsUTF8AndControlBytes() {
        let input = "héllo 日本語 🎉\r\t\u{7F}"
        #expect(filtered(input) == input)
    }

    @Test func keepsArbitraryBinaryBytes() {
        let bytes = Data([0x00, 0xFF, 0x80, 0x9B, 0x41])
        #expect(SupermuxTerminalReplyFilter.removingReplies(from: bytes) == bytes)
    }

    @Test func emptyStaysEmpty() {
        #expect(SupermuxTerminalReplyFilter.removingReplies(from: Data()).isEmpty)
    }

    // MARK: 6. Large input

    @Test func handlesALargePasteQuickly() {
        let line = String(repeating: "x", count: 1_000) + "\u{1B}[27u"
        let input = String(repeating: line, count: 1_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { #expect(filtered(input) == input) }
        #expect(elapsed < .seconds(1))
    }
}
