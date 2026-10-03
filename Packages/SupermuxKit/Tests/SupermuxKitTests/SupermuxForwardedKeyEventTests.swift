import Foundation
import SupermuxKit
import Testing

/// `SupermuxForwardedKeyEvent` carries a key press from a device mirror to
/// the Mac that runs the terminal, so that Mac's Ghostty encodes it with its
/// own terminal state (kitty keyboard flags, cursor-key mode), exactly as a
/// key pressed on that Mac.
///
/// Ways it could fail, each covered below:
/// 1. Keys reach the other Mac out of order. Forwarded keys travel through a
///    different queue than locally encoded bytes, so a plain character typed
///    right after Escape could overtake it: every key press is forwarded,
///    plain text included.
/// 2. A key whose encoding depends on terminal state stays local: Escape,
///    Return, Tab, Backspace, arrows and other function keys, any key with
///    Control, Option or Command, a modifier-only press.
/// 3. IME preedit (composing) text is forwarded, or a key release is
///    forwarded (Ghostty never forwards a release of a forwarded press).
/// 4. Encoding and decoding lose a field: action, modifiers, consumed
///    modifiers, key code, text (Unicode, separators, newlines), unshifted
///    code point.
/// 5. A name that is not ours (a remote-tmux key such as "Up") or a malformed
///    payload decodes to a key, or crashes.
struct SupermuxForwardedKeyEventTests {
    private let ctrl: UInt32 = 1 << 1
    private let alt: UInt32 = 1 << 2

    private let press: UInt32 = 1
    private let release: UInt32 = 0
    private let `repeat`: UInt32 = 2

    private func forwards(action: UInt32 = 1, composing: Bool = false) -> Bool {
        SupermuxForwardedKeyEvent.shouldForward(action: action, composing: composing)
    }

    // MARK: 1. Every press travels, plain text included

    @Test func pressesAndRepeatsAreForwarded() {
        #expect(forwards(action: press))
        #expect(forwards(action: `repeat`))
    }

    // MARK: 2. State-dependent keys are forwarded

    @Test(arguments: ["\u{1B}", "\r", "\t", "\u{7F}", "\u{F700}", "\u{F704}", "a", "é", ""])
    func keysOfEveryKindAreForwarded(_ text: String) {
        let event = SupermuxForwardedKeyEvent(action: press, mods: ctrl | alt, consumedMods: 0, keycode: 0, text: text, unshiftedCodepoint: 0)
        #expect(forwards(action: event.action))
    }

    // MARK: 3. Preedit and releases stay local

    @Test func composingTextStaysLocal() {
        #expect(!forwards(composing: true))
        #expect(!forwards(action: `repeat`, composing: true))
    }

    @Test func releasesStayLocal() {
        #expect(!forwards(action: release))
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
