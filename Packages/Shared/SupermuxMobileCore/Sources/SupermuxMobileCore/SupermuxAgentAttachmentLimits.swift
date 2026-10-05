/// The limits on images attached to an `agent.start` prompt.
///
/// They mirror what the host's attachment store accepts
/// (`MobileTaskAttachmentStore`: 32 MiB per file, 3 MiB per chunk), so a
/// client rejects an image up front instead of after part of it was sent; a
/// client uploads each image as its own operation, which stays within the
/// store's 64 MiB per-operation total. The formats are the ones Claude Code
/// reads as images.
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
