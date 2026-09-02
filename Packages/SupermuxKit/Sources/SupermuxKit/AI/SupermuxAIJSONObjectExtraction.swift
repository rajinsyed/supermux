import Foundation

/// Finds a JSON object inside a model reply that may surround it with prose.
///
/// Slicing from the first `{` to the last `}` breaks as soon as the prose
/// contains braces of its own; this walks balanced braces (skipping brace
/// characters inside JSON strings) and returns the first candidate that
/// actually decodes as an object.
enum SupermuxAIJSONObjectExtraction {
    /// The first balanced, decodable `{…}` object in `text`, or `nil`.
    /// - Parameter text: The reply, already stripped of any code fence.
    static func firstObject(in text: String) -> [String: Any]? {
        var searchStart = text.startIndex
        while let open = text[searchStart...].firstIndex(of: "{") {
            if let close = closingBrace(in: text, from: open),
               let object = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [String: Any] {
                return object
            }
            searchStart = text.index(after: open)
        }
        return nil
    }

    /// The index of the `}` that balances the `{` at `open`, honoring JSON
    /// string literals and their escapes; `nil` when the braces never close.
    private static func closingBrace(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
