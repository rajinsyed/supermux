/// The limits on images attached to an `agent.start` prompt.
///
/// They mirror what the host's attachment store accepts for one upload
/// operation (`MobileTaskAttachmentStore`: 10 files, 32 MiB each, 3 MiB per
/// chunk), so a client rejects an image up front instead of after part of it
/// was sent. The formats are the ones Claude Code reads as images.
public enum SupermuxAgentAttachmentLimits {
    /// The most images one prompt carries.
    public static let maximumAttachments = 10
    /// The most bytes one image may have.
    public static let maximumFileBytes = 32 * 1024 * 1024
    /// Raw bytes per `agent.attachment.upload` chunk.
    public static let chunkBytes = 3 * 1024 * 1024
    /// Lowercased file extensions of the image formats Claude reads.
    public static let imageFileExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
}
