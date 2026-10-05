import Foundation

/// Images attached to a Start Claude prompt, by their paths on the Mac that
/// runs Claude.
///
/// Claude Code reads an image whose path is in the prompt with its Read tool,
/// but asks before reading outside its working directory. So the paths are
/// listed after the typed prompt, and their folders are passed as
/// `--add-dir` (``directories``) to let Claude read them without asking.
///
/// ```swift
/// let attachments = SupermuxAgentPromptAttachments(paths: ["/tmp/a/shot.png"])
/// attachments.prompt(appendingTo: "Fix this layout")
/// // "Fix this layout\n\nAttached images:\n/tmp/a/shot.png"
/// ```
public struct SupermuxAgentPromptAttachments: Equatable, Sendable {
    /// The images' absolute paths, in the order they were attached.
    public let paths: [String]

    /// Creates the attachment list, dropping blank entries.
    /// - Parameter paths: Absolute paths on the Mac that runs Claude.
    public init(paths: [String] = []) {
        self.paths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Whether no image is attached.
    public var isEmpty: Bool { paths.isEmpty }

    /// The prompt Claude receives: the typed text, then one line per image.
    /// - Parameter prompt: The typed prompt.
    /// - Returns: `prompt` unchanged when nothing is attached.
    public func prompt(appendingTo prompt: String) -> String {
        guard !paths.isEmpty else { return prompt }
        return prompt + "\n\nAttached images:\n" + paths.joined(separator: "\n")
    }

    /// The folders that hold the images, in first-use order without repeats.
    public var directories: [String] {
        var seen: Set<String> = []
        return paths
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            .filter { seen.insert($0).inserted }
    }
}
