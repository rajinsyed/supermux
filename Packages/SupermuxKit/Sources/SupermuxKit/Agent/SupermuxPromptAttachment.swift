public import Foundation

/// One image attached to the New Worktree prompt, as a file on this Mac (the
/// picked or dropped file itself, or a temporary file for a pasted image).
public struct SupermuxPromptAttachment: Identifiable, Equatable, Sendable {
    /// Stable identity for the thumbnail strip and removal.
    public let id: UUID
    /// The image file on this Mac.
    public let fileURL: URL

    /// Creates an attachment.
    /// - Parameters:
    ///   - id: Identity; a new one by default.
    ///   - fileURL: The image file on this Mac.
    public init(id: UUID = UUID(), fileURL: URL) {
        self.id = id
        self.fileURL = fileURL
    }

    /// The file name shown in the thumbnail's tooltip.
    public var name: String { fileURL.lastPathComponent }
}
