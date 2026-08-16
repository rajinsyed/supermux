public import Foundation

/// A complete client-to-CLI JSON line ready for serialized stdin writing.
public struct SupermuxHarnessEncodedFrame: Equatable, Sendable {
    /// JSON bytes without the terminating newline.
    public let jsonData: Data
    /// JSON bytes followed by exactly one newline.
    public let lineData: Data

    init(object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw SupermuxHarnessProtocolError.invalidJSONObject
        }
        jsonData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var line = jsonData
        line.append(0x0A)
        lineData = line
    }

    /// Decodes the encoded frame back into an immutable protocol object.
    ///
    /// - Returns: The encoded JSON object.
    /// - Throws: ``SupermuxHarnessProtocolError`` if the stored bytes cannot be decoded.
    public func jsonObject() throws -> SupermuxHarnessJSONObject {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw SupermuxHarnessProtocolError.invalidJSON
        }
        guard let object = value as? [String: Any] else {
            throw SupermuxHarnessProtocolError.expectedJSONObject
        }
        return SupermuxHarnessJSONObject(parsedObject: object)
    }
}
