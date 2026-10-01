public import Foundation

/// The ordered input a device mirror sends to the Mac that runs the terminal
/// in one request: raw bytes (paste, mouse reports, binding text) and
/// forwarded key presses (``SupermuxForwardedKeyEvent``). Adjacent bytes are
/// merged; the batch refuses input past its byte limit.
public struct SupermuxTerminalInputBatch: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case bytes(Data)
        case key(SupermuxForwardedKeyEvent)
    }

    public private(set) var items: [Item] = []
    public let byteLimit: Int
    private var byteCount = 0

    public init(byteLimit: Int = 256 * 1024) {
        self.byteLimit = byteLimit
    }

    public var isEmpty: Bool { items.isEmpty }

    public var containsKeys: Bool {
        items.contains { if case .key = $0 { true } else { false } }
    }

    /// Appends bytes, merged into a trailing byte item; false (and nothing
    /// appended) past the limit.
    public mutating func append(bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return true }
        guard byteCount + bytes.count <= byteLimit else { return false }
        byteCount += bytes.count
        if case .bytes(let previous) = items.last {
            items[items.count - 1] = .bytes(previous + bytes)
        } else {
            items.append(.bytes(bytes))
        }
        return true
    }

    /// Appends a key, which counts as its text's length (at least one byte).
    public mutating func append(key: SupermuxForwardedKeyEvent) -> Bool {
        let cost = max(1, key.text?.utf8.count ?? 0)
        guard byteCount + cost <= byteLimit else { return false }
        byteCount += cost
        items.append(.key(key))
        return true
    }

    // MARK: Wire form (`supermux_input` of `mobile.terminal.input`)

    private static let bytesKey = "bytes_b64"
    private static let keyKey = "key"

    public var wireEvents: [[String: Any]] {
        items.map { item in
            switch item {
            case .bytes(let data):
                return [Self.bytesKey: data.base64EncodedString()]
            case .key(let key):
                let object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(key))) ?? [:]
                return [Self.keyKey: object]
            }
        }
    }

    /// Decodes ``wireEvents``; nil when any event is malformed or there are none.
    public init?(wireEvents: [Any]) {
        guard !wireEvents.isEmpty else { return nil }
        self.init(byteLimit: .max)
        for case let event in wireEvents {
            guard let event = event as? [String: Any], event.count == 1 else { return nil }
            if let encoded = event[Self.bytesKey] as? String, let data = Data(base64Encoded: encoded) {
                items.append(.bytes(data))
            } else if let object = event[Self.keyKey], JSONSerialization.isValidJSONObject(object),
                      let json = try? JSONSerialization.data(withJSONObject: object),
                      let key = try? JSONDecoder().decode(SupermuxForwardedKeyEvent.self, from: json) {
                items.append(.key(key))
            } else {
                return nil
            }
        }
    }

    // MARK: Host forms

    /// A Ghostty `text:` binding action that writes `bytes` to the PTY exactly:
    /// every byte except ASCII letters and digits is a `\xNN` escape, which
    /// Ghostty's string parser turns back into that one byte.
    public static func ghosttyTextBinding(for bytes: Data) -> String {
        var action = "text:"
        action.reserveCapacity(5 + bytes.count * 4)
        for byte in bytes {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                action.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                action += "\\x" + (byte < 0x10 ? "0" : "") + String(byte, radix: 16)
            }
        }
        return action
    }

    /// Plain text for a terminal that has not started yet, which only takes
    /// text: bytes as UTF-8, and per key its text, or its control character
    /// (Return, Escape, Tab, Backspace, a Control letter). Function keys
    /// have no text form and are dropped.
    public var fallbackText: String {
        var text = ""
        for item in items {
            switch item {
            case .bytes(let data):
                text += String(decoding: data, as: UTF8.self)
            case .key(let key):
                text += Self.fallbackText(for: key)
            }
        }
        return text
    }

    private static func fallbackText(for key: SupermuxForwardedKeyEvent) -> String {
        let ctrl: UInt32 = 1 << 1
        if key.mods & ctrl != 0, let letter = key.text?.unicodeScalars.first, key.text?.unicodeScalars.count == 1,
           let control = Unicode.Scalar(letter.value & 0x1F), (0x40...0x7F).contains(letter.value) {
            return String(control)
        }
        if let text = key.text, !text.isEmpty, !text.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) {
            return text
        }
        switch key.unshiftedCodepoint {
        case 0x0D, 0x1B, 0x09, 0x7F:
            return Unicode.Scalar(key.unshiftedCodepoint).map(String.init) ?? ""
        default:
            return ""
        }
    }
}
