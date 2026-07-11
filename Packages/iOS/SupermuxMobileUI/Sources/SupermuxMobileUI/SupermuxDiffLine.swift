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
        var lines: [SupermuxDiffLine] = []
        lines.reserveCapacity(raw.count)
        // Track whether we are inside a hunk body: there the first character IS
        // the change marker, so a code line like `+++counter;` or a `-- ` email
        // signature is a real addition/removal, never file metadata. Classifying
        // by prefix alone (as `kind(of:)` must, lacking context) mis-tints those
        // as headers. A `changes.diff` response is a single file's diff, so the
        // header block always precedes the first `@@`.
        var insideHunk = false
        for (index, line) in raw.enumerated() {
            let kind: Kind
            if line.hasPrefix("@@") {
                kind = .hunk
                insideHunk = true
            } else if insideHunk {
                if line.hasPrefix("+") {
                    kind = .addition
                } else if line.hasPrefix("-") {
                    kind = .removal
                } else if line.hasPrefix("\\") {
                    // `\ No newline at end of file`
                    kind = .meta
                } else {
                    kind = .context
                }
            } else {
                kind = isFileHeader(line) ? .meta : .context
            }
            lines.append(SupermuxDiffLine(id: index, text: line, kind: kind))
        }
        return lines
    }

    /// Whether a pre-hunk line is git file-section metadata (`diff --git`,
    /// `index`, the `--- `/`+++ ` file headers, mode/rename/binary markers).
    private static func isFileHeader(_ line: String) -> Bool {
        let prefixes = [
            "diff ", "index ", "--- ", "+++ ", "new file", "deleted file",
            "old mode", "new mode", "similarity", "dissimilarity",
            "rename ", "copy ", "Binary files",
        ]
        return prefixes.contains(where: line.hasPrefix)
    }

    /// Classifies one raw diff line WITHOUT hunk context. Prefer
    /// ``lines(from:)``, which is hunk-aware and therefore tints hunk-body
    /// `+++`/`---` code lines as real additions/removals rather than headers.
    /// - Parameter line: The raw line text.
    public static func kind(of line: String) -> Kind {
        if line.hasPrefix("@@") { return .hunk }
        // Only the "--- "/"+++ " file-header forms (three marker chars + space)
        // are metadata; a bare "+++x"/"---x" has no space and is content.
        if isFileHeader(line) { return .meta }
        if line.hasPrefix("+") { return .addition }
        if line.hasPrefix("-") { return .removal }
        return .context
    }
}
