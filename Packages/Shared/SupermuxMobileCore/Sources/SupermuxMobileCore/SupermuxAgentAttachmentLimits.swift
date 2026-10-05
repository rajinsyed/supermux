/// The limits on images attached to an `agent.start` prompt.
///
/// They mirror what the host's attachment store accepts
/// (`MobileTaskAttachmentStore`: 32 MiB per file, 3 MiB per chunk, 10 files
/// and 64 MiB per operation), so a client rejects an image up front instead
/// of after part of it was sent, and packs a prompt's images into as few
/// operations as those totals allow. The formats are the ones Claude Code
/// reads as images.
public enum SupermuxAgentAttachmentLimits {
    /// The most images one prompt carries.
    public static let maximumAttachments = 10
    /// The most bytes one image may have.
    public static let maximumFileBytes = 32 * 1024 * 1024
    /// The most bytes one upload operation may hold across its files.
    public static let maximumOperationBytes = 64 * 1024 * 1024
    /// Raw bytes per `agent.attachment.upload` chunk.
    public static let chunkBytes = 3 * 1024 * 1024
    /// Lowercased file extensions of the image formats Claude reads.
    public static let imageFileExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
}
