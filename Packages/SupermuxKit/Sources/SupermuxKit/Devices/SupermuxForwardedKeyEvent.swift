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

    private static let releaseAction: UInt32 = 0

    /// Whether a key event goes to the other Mac as an event: every press and
    /// repeat, plain text included. Forwarded keys take a different queue
    /// than bytes Ghostty encodes locally, so forwarding only some keys would
    /// let a character overtake the Escape typed before it. IME preedit never
    /// leaves the mirror, and a release stays local (Ghostty swallows the
    /// release of a forwarded press).
    public static func shouldForward(action: UInt32, composing: Bool) -> Bool {
        !composing && action != releaseAction
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
