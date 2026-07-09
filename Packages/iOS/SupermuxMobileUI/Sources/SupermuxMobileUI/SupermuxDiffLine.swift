/// One pre-classified line of a unified diff, for the diff screen's
/// monospaced, tinted rendering.
///
/// Classification is a pure string projection (package-unit-tested) computed
/// once per fetched diff — never inside a row's `body`.
public struct SupermuxDiffLine: Identifiable, Equatable, Sendable {
    /// How a line renders: additions green, removals red, hunk headers and
    /// file metadata de-emphasized, context plain.
    public enum Kind: Equatable, Sendable {
        /// A `+` line (not the `+++` file header).
        case addition
        /// A `-` line (not the `---` file header).
        case removal
        /// A `@@ … @@` hunk header.
        case hunk
        /// File-level metadata (`diff --git`, `index`, `+++`, `---`, …).
        case meta
        /// An unchanged context line.
        case context
    }

    /// The line's position in the diff (stable list identity).
    public let id: Int
    /// The raw line text, rendered verbatim.
    public let text: String
    /// The line's render classification.
    public let kind: Kind

    /// Creates a classified line.
    /// - Parameters:
    ///   - id: The line's position in the diff.
    ///   - text: The raw line text.
    ///   - kind: The render classification.
    public init(id: Int, text: String, kind: Kind) {
        self.id = id
        self.text = text
        self.kind = kind
    }

    /// Splits and classifies a unified diff. A single trailing empty line
    /// (from the diff's terminating newline) is dropped; interior blank
    /// context lines are preserved.
    /// - Parameter diffText: The unified diff text from the Mac.
    public static func lines(from diffText: String) -> [SupermuxDiffLine] {
        var raw = diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if raw.last?.isEmpty == true {
            raw.removeLast()
        }
        return raw.enumerated().map { index, line in
            SupermuxDiffLine(id: index, text: line, kind: kind(of: line))
        }
    }

    /// Classifies one raw diff line.
    /// - Parameter line: The raw line text.
    public static func kind(of line: String) -> Kind {
        if line.hasPrefix("@@") { return .hunk }
        let metaPrefixes = [
            "+++", "---", "diff ", "index ", "new file", "deleted file",
            "old mode", "new mode", "similarity", "dissimilarity",
            "rename ", "copy ", "Binary files",
        ]
        if metaPrefixes.contains(where: line.hasPrefix) { return .meta }
        if line.hasPrefix("+") { return .addition }
        if line.hasPrefix("-") { return .removal }
        return .context
    }
}
