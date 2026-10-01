import Foundation
import SupermuxKit
import Testing

/// `SupermuxForwardedKeyEvent` carries a key press from a device mirror to
/// the Mac that runs the terminal, so that Mac's Ghostty encodes it with its
/// own terminal state (kitty keyboard flags, cursor-key mode), exactly as a
/// key pressed on that Mac.
///
/// Ways it could fail, each covered below:
/// 1. A plain typed character is forwarded, losing local echo prediction, or
///    an Option-composed character ("å") is forwarded as Alt+a.
/// 2. A key whose encoding depends on terminal state stays local: Escape,
///    Return, Tab, Backspace, arrows and other function keys, any key with an
///    unconsumed Control, Option or Command, a modifier-only press.
/// 3. IME preedit (composing) text is forwarded.
/// 4. Encoding and decoding lose a field: action, modifiers, consumed
///    modifiers, key code, text (Unicode, separators, newlines), unshifted
///    code point.
/// 5. A name that is not ours (a remote-tmux key such as "Up") or a malformed
///    payload decodes to a key, or crashes.
struct SupermuxForwardedKeyEventTests {
    private let shift: UInt32 = 1 << 0
    private let ctrl: UInt32 = 1 << 1
    private let alt: UInt32 = 1 << 2
    private let command: UInt32 = 1 << 3
    private let caps: UInt32 = 1 << 4

    private func forwards(
        text: String?, mods: UInt32 = 0, consumed: UInt32 = 0, composing: Bool = false
    ) -> Bool {
        SupermuxForwardedKeyEvent.shouldForward(text: text, mods: mods, consumedMods: consumed, composing: composing)
    }

    // MARK: 1. Plain text stays local

    @Test(arguments: ["a", "A", " ", "1", "é", "日", "🎉", "/"])
    func plainTextStaysLocal(_ text: String) {
        #expect(!forwards(text: text))
        #expect(!forwards(text: text, mods: shift, consumed: shift))
        #expect(!forwards(text: text, mods: caps))
    }

    @Test func optionComposedCharacterStaysLocal() {
        #expect(!forwards(text: "å", mods: alt, consumed: alt))
        #expect(!forwards(text: "Å", mods: alt | shift, consumed: alt | shift))
    }

    // MARK: 2. State-dependent keys are forwarded

    @Test(arguments: [
        "\u{1B}",   // Escape
        "\r",       // Return
        "\t",       // Tab
        "\u{7F}",   // Backspace
        "\u{08}",   // Ctrl+H style backspace
        "\u{F700}", // Up arrow (AppKit function-key range)
        "\u{F704}", // F1
        "\u{F729}", // Home
    ])
    func controlAndFunctionKeysAreForwarded(_ text: String) {
        #expect(forwards(text: text))
    }

    @Test func keysWithoutTextAreForwarded() {
        #expect(forwards(text: nil))
        #expect(forwards(text: ""))
        #expect(forwards(text: nil, mods: shift)) // modifier-only press
    }

    @Test func unconsumedModifiersAreForwarded() {
        #expect(forwards(text: "c", mods: ctrl))
        #expect(forwards(text: "b", mods: alt))
        #expect(forwards(text: "k", mods: command))
        #expect(forwards(text: "C", mods: ctrl | shift, consumed: shift))
        #expect(forwards(text: "\r", mods: shift))
        #expect(forwards(text: " ", mods: ctrl))
    }

    // MARK: 3. Preedit stays local

    @Test func composingTextStaysLocal() {
        #expect(!forwards(text: "に", composing: true))
        #expect(!forwards(text: nil, composing: true))
    }

    // MARK: 4. Round trip

    @Test(arguments: [
        SupermuxForwardedKeyEvent(action: 1, mods: 0, consumedMods: 0, keycode: 53, text: "\u{1B}", unshiftedCodepoint: 0),
        SupermuxForwardedKeyEvent(action: 2, mods: 2, consumedMods: 0, keycode: 8, text: "c", unshiftedCodepoint: 99),
        SupermuxForwardedKeyEvent(action: 0, mods: 1, consumedMods: 1, keycode: 36, text: nil, unshiftedCodepoint: 13),
        SupermuxForwardedKeyEvent(action: 1, mods: 4, consumedMods: 0, keycode: 0, text: "a:b\n日本🎉", unshiftedCodepoint: 97),
    ])
    func roundTripsThroughAName(_ event: SupermuxForwardedKeyEvent) {
        #expect(SupermuxForwardedKeyEvent(keyName: event.keyName) == event)
    }

    @Test func namesAreMarked() {
        let event = SupermuxForwardedKeyEvent(action: 1, mods: 0, consumedMods: 0, keycode: 53, text: nil, unshiftedCodepoint: 0)
        #expect(event.keyName.hasPrefix(SupermuxForwardedKeyEvent.keyNamePrefix))
    }

    // MARK: 5. Foreign and malformed names

    @Test(arguments: [
        "Up", "Escape", "C-c", "",
        SupermuxForwardedKeyEvent.keyNamePrefix,
        SupermuxForwardedKeyEvent.keyNamePrefix + "not base64!",
        SupermuxForwardedKeyEvent.keyNamePrefix + Data("{\"k\":1}".utf8).base64EncodedString(),
        SupermuxForwardedKeyEvent.keyNamePrefix + Data("[1,2,3]".utf8).base64EncodedString(),
    ])
    func rejectsForeignOrMalformedNames(_ name: String) {
        #expect(SupermuxForwardedKeyEvent(keyName: name) == nil)
    }
}
