import Foundation

/// One raw stdout line classified before typed decoding.
///
/// Launchers such as `ccx` legitimately print ANSI banners to stdout before
/// exec'ing Claude Code, so a non-JSON line is never fatal. Classification is
/// the first stage; `.json` lines then go through ``ClaudeStreamLineDecoder``.
public enum ClaudeLineClassification: Sendable, Equatable {
    /// A syntactically valid JSON object line (typed decoding happens next).
    case json(ClaudeJSONValue)
    /// A line whose first non-whitespace byte is not `{`: launcher output such
    /// as the ccx ANSI banner. The associated text has ANSI escapes stripped.
    case launcherNotice(String)
    /// A line that looks like JSON (starts with `{`) but fails to parse.
    case malformedJSON(String)
    /// A line exceeding the configured byte bound; content is discarded.
    case tooLarge(byteCount: Int)
    /// A blank or whitespace-only line.
    case empty
}

/// Classifies raw NDJSON lines from a Claude Code launcher's stdout.
///
/// lint:allow namespace-type — pure stateless classification table with no
/// dependencies to inject; instances would carry no meaning. (lint:allow)
public enum ClaudeLineClassifier {
    /// Default single-line byte bound (32 MiB).
    public static let defaultMaxLineBytes = 32 * 1024 * 1024

    /// Classifies one newline-framed stdout line.
    ///
    /// - Parameters:
    ///   - data: The line's bytes, without the trailing newline.
    ///   - maxBytes: Upper byte bound; larger lines classify as ``ClaudeLineClassification/tooLarge(byteCount:)``.
    public static func classify(
        _ data: Data,
        maxBytes: Int = defaultMaxLineBytes
    ) -> ClaudeLineClassification {
        if data.count > maxBytes {
            return .tooLarge(byteCount: data.count)
        }
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        // A launcher banner may open with ANSI escapes; strip before probing
        // the first byte so `\e[2m{...` is still recognized by content.
        let stripped = strippingANSI(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.first == "{" else {
            return .launcherNotice(stripped)
        }
        do {
            let value = try JSONDecoder().decode(
                ClaudeJSONValue.self,
                from: Data(stripped.utf8)
            )
            return .json(value)
        } catch {
            return .malformedJSON(stripped)
        }
    }

    /// Classifies one stdout line given as a string.
    public static func classify(
        _ line: String,
        maxBytes: Int = defaultMaxLineBytes
    ) -> ClaudeLineClassification {
        classify(Data(line.utf8), maxBytes: maxBytes)
    }

    /// Removes ANSI CSI/OSC escape sequences from launcher output.
    public static func strippingANSI(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar.value == 0x1B else {
                result.unicodeScalars.append(scalar)
                continue
            }
            guard let introducer = iterator.next() else { break }
            switch introducer {
            case "[":
                // CSI: parameters end at a final byte in 0x40...0x7E.
                while let byte = iterator.next() {
                    if (0x40...0x7E).contains(byte.value) { break }
                }
            case "]":
                // OSC: terminated by BEL or ST (ESC \).
                while let byte = iterator.next() {
                    if byte.value == 0x07 { break }
                    if byte.value == 0x1B {
                        _ = iterator.next()
                        break
                    }
                }
            default:
                // Two-character escape such as ESC c; drop both.
                break
            }
        }
        return result
    }
}
