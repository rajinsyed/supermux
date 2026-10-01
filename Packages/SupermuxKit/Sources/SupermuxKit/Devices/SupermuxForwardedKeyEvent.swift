import Foundation

/// A key press on a device mirror, forwarded to the Mac that runs the
/// terminal so that Mac's Ghostty encodes it with its own terminal state
/// (kitty keyboard flags, cursor-key mode), exactly as if it were pressed
/// there. The fields are Ghostty's `ghostty_input_key_s`; modifiers use
/// Ghostty's bits (shift 1, ctrl 2, alt 4, super 8).
///
/// It travels through the mirror surface's ordered manual-I/O stream as a
/// named key whose name carries the encoded event.
public struct SupermuxForwardedKeyEvent: Codable, Equatable, Sendable {
    public let action: UInt32
    public let mods: UInt32
    public let consumedMods: UInt32
    public let keycode: UInt32
    public let text: String?
    public let unshiftedCodepoint: UInt32

    public init(action: UInt32, mods: UInt32, consumedMods: UInt32, keycode: UInt32, text: String?, unshiftedCodepoint: UInt32) {
        self.action = action
        self.mods = mods
        self.consumedMods = consumedMods
        self.keycode = keycode
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
    }

    private enum CodingKeys: String, CodingKey {
        case action = "a", mods = "m", consumedMods = "c", keycode = "k", text = "t", unshiftedCodepoint = "u"
    }

    // MARK: Which keys travel as events

    private static let ctrl: UInt32 = 1 << 1
    private static let alt: UInt32 = 1 << 2
    private static let superKey: UInt32 = 1 << 3

    /// Whether a key event goes to the other Mac as an event. Plain text
    /// (including Shift, Caps Lock and Option-composed characters) stays a
    /// local byte stream so local echo prediction keeps working; everything
    /// whose encoding depends on terminal state is forwarded: control and
    /// function keys, keys with an unconsumed Control, Option or Command, and
    /// modifier-only presses. IME preedit never leaves the mirror.
    public static func shouldForward(text: String?, mods: UInt32, consumedMods: UInt32, composing: Bool) -> Bool {
        guard !composing else { return false }
        if mods & ~consumedMods & (ctrl | alt | superKey) != 0 { return true }
        guard let text, !text.isEmpty else { return true }
        return !text.unicodeScalars.allSatisfy(isPrintable)
    }

    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00..<0x20, 0x7F...0x9F: return false // C0, DEL, C1
        case 0xF700...0xF8FF: return false // AppKit function-key characters
        default: return true
        }
    }

    // MARK: Named-key encoding

    public static let keyNamePrefix = "supermux.key.v1:"

    public var keyName: String {
        let payload = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.keyNamePrefix + payload.base64EncodedString()
    }

    /// Decodes a name made by ``keyName``; nil for any other name.
    public init?(keyName: String) {
        guard keyName.hasPrefix(Self.keyNamePrefix),
              let payload = Data(base64Encoded: String(keyName.dropFirst(Self.keyNamePrefix.count))),
              let event = try? JSONDecoder().decode(Self.self, from: payload) else { return nil }
        self = event
    }
}
