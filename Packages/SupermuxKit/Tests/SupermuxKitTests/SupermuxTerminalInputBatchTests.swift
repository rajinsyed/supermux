import Foundation
import SupermuxKit
import Testing

/// `SupermuxTerminalInputBatch` is the ordered input a device mirror sends to
/// the Mac that runs the terminal in one request: raw bytes (paste, mouse
/// reports, binding text) and forwarded key presses.
///
/// Ways it could fail, each covered below:
/// 1. Items change order, so a key overtakes the bytes typed before it.
/// 2. Adjacent byte chunks are not merged, multiplying writes on the host.
/// 3. The byte limit is not enforced, or a refused append is half-applied.
/// 4. The wire form loses bytes (NUL, LF, CR, invalid UTF-8) or key fields.
/// 5. The host accepts a malformed wire form (missing or bad fields, wrong
///    types, unknown kinds) instead of rejecting the whole request.
/// 6. The Ghostty `text:` binding written on the host does not reproduce the
///    exact bytes: a backslash, a byte outside ASCII letters and digits, or
///    edge whitespace the action parser could trim is not escaped.
/// 7. The fallback text for a terminal that has not started yet drops
///    Escape, Return, Tab, Backspace or a Control letter.
struct SupermuxTerminalInputBatchTests {
    private let escape = SupermuxForwardedKeyEvent(action: 1, mods: 0, consumedMods: 0, keycode: 53, text: nil, unshiftedCodepoint: 0x1B)
    private let ctrlC = SupermuxForwardedKeyEvent(action: 1, mods: 2, consumedMods: 0, keycode: 8, text: "c", unshiftedCodepoint: 99)

    // MARK: 1-3. Order, merging, limit

    @Test func keepsOrderAndMergesAdjacentBytes() {
        var batch = SupermuxTerminalInputBatch()
        do { let appended = batch.append(bytes: Data("ab".utf8)); #expect(appended) }
        do { let appended = batch.append(bytes: Data("c".utf8)); #expect(appended) }
        do { let appended = batch.append(key: escape); #expect(appended) }
        do { let appended = batch.append(bytes: Data("d".utf8)); #expect(appended) }
        #expect(batch.items == [.bytes(Data("abc".utf8)), .key(escape), .bytes(Data("d".utf8))])
        #expect(!batch.isEmpty)
        #expect(batch.containsKeys)
    }

    @Test func emptyBytesAddNothing() {
        var batch = SupermuxTerminalInputBatch()
        do { let appended = batch.append(bytes: Data()); #expect(appended) }
        #expect(batch.isEmpty)
        #expect(!batch.containsKeys)
    }

    @Test func refusesInputPastTheLimitWithoutChangingTheBatch() {
        var batch = SupermuxTerminalInputBatch(byteLimit: 4)
        do { let appended = batch.append(bytes: Data("abc".utf8)); #expect(appended) }
        do { let appended = batch.append(bytes: Data("de".utf8)); #expect(!appended) }
        #expect(batch.items == [.bytes(Data("abc".utf8))])
        do { let appended = batch.append(bytes: Data("d".utf8)); #expect(appended) }
        do { let appended = batch.append(key: escape); #expect(!appended) }
        #expect(batch.items == [.bytes(Data("abcd".utf8))])
    }

    @Test func appendsItemsAndEmptiesKeepingTheLimit() {
        var batch = SupermuxTerminalInputBatch(byteLimit: 2)
        do { let appended = batch.append(.key(escape)); #expect(appended) }
        do { let appended = batch.append(.bytes(Data("a".utf8))); #expect(appended) }
        do { let appended = batch.append(.bytes(Data("b".utf8))); #expect(!appended) }
        batch.removeAll()
        #expect(batch.isEmpty)
        do { let appended = batch.append(.bytes(Data("ab".utf8))); #expect(appended) }
        do { let appended = batch.append(.bytes(Data("c".utf8))); #expect(!appended) }
    }

    // MARK: 4-5. Wire form

    @Test func wireFormRoundTrips() throws {
        var batch = SupermuxTerminalInputBatch()
        _ = batch.append(bytes: Data([0x00, 0x0A, 0x0D, 0xFF, 0x1B, 0x5B]))
        _ = batch.append(key: ctrlC)
        _ = batch.append(bytes: Data("é".utf8))
        let json = try JSONSerialization.data(withJSONObject: batch.wireEvents)
        let decoded = try #require(try JSONSerialization.jsonObject(with: json) as? [Any])
        #expect(SupermuxTerminalInputBatch(wireEvents: decoded)?.items == batch.items)
    }

    @Test(arguments: [
        #"[{"bytes_b64": "not base64!"}]"#,
        #"[{"key": {"a": 1}}]"#,
        #"[{"mystery": 1}]"#,
        #"["just a string"]"#,
        #"[]"#,
    ])
    func rejectsMalformedWireForms(_ json: String) throws {
        let wire = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
        #expect(SupermuxTerminalInputBatch(wireEvents: wire) == nil)
    }

    // MARK: 6. Ghostty text binding

    @Test func bindingTextEscapesEverythingButLettersAndDigits() {
        let bytes = Data([0x61, 0x5C, 0x1B, 0x5B, 0x0A, 0x00, 0xC3, 0xA9, 0x7E, 0x20, 0x3A])
        let binding = SupermuxTerminalInputBatch.ghosttyTextBinding(for: bytes)
        #expect(binding == "text:a\\x5c\\x1b\\x5b\\x0a\\x00\\xc3\\xa9\\x7e\\x20\\x3a")
        #expect(Self.ghosttyParse(String(binding.dropFirst("text:".count))) == bytes)
    }

    @Test func bindingTextReproducesEveryByte() {
        let bytes = Data((0...255).map(UInt8.init))
        let binding = SupermuxTerminalInputBatch.ghosttyTextBinding(for: bytes)
        #expect(binding.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F })
        #expect(Self.ghosttyParse(String(binding.dropFirst("text:".count))) == bytes)
    }

    /// Ghostty's `config/string.zig` parse, restricted to what the binding
    /// emits: `\xNN` is one byte, every other character is itself.
    private static func ghosttyParse(_ text: String) -> Data? {
        var out = Data()
        var scalars = Array(text.unicodeScalars)[...]
        while let first = scalars.first {
            scalars = scalars.dropFirst()
            guard first == "\\" else {
                out.append(contentsOf: Array(String(first).utf8))
                continue
            }
            guard scalars.count >= 3, scalars.first == "x",
                  let byte = UInt8(String(String.UnicodeScalarView(scalars.dropFirst().prefix(2))), radix: 16) else { return nil }
            out.append(byte)
            scalars = scalars.dropFirst(3)
        }
        return out
    }

    // MARK: 7. Fallback text

    @Test func fallbackTextKeepsControlKeys() {
        var batch = SupermuxTerminalInputBatch()
        _ = batch.append(bytes: Data("ls".utf8))
        _ = batch.append(key: SupermuxForwardedKeyEvent(action: 1, mods: 0, consumedMods: 0, keycode: 36, text: nil, unshiftedCodepoint: 0x0D))
        _ = batch.append(key: escape)
        _ = batch.append(key: SupermuxForwardedKeyEvent(action: 1, mods: 0, consumedMods: 0, keycode: 48, text: nil, unshiftedCodepoint: 0x09))
        _ = batch.append(key: SupermuxForwardedKeyEvent(action: 1, mods: 0, consumedMods: 0, keycode: 51, text: nil, unshiftedCodepoint: 0x7F))
        _ = batch.append(key: ctrlC)
        _ = batch.append(key: SupermuxForwardedKeyEvent(action: 1, mods: 1, consumedMods: 1, keycode: 0, text: "A", unshiftedCodepoint: 97))
        _ = batch.append(key: SupermuxForwardedKeyEvent(action: 1, mods: 0, consumedMods: 0, keycode: 126, text: nil, unshiftedCodepoint: 0xF700))
        #expect(batch.fallbackText == "ls\r\u{1B}\t\u{7F}\u{03}A")
    }
}
