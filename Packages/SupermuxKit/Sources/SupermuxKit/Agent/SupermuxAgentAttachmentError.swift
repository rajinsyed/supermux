public import Foundation

/// Why an image could not be attached to a Start Claude prompt, or not sent
/// to the Mac that runs Claude.
public enum SupermuxAgentAttachmentError: Error, Equatable, Sendable, LocalizedError {
    /// The file is not a PNG, JPEG, GIF or WebP image (by name).
    case unsupported(String)
    /// The file is over ``SupermuxAgentAttachmentLimits/maximumFileBytes`` (by name).
    case tooLarge(String)
    /// More than ``SupermuxAgentAttachmentLimits/maximumAttachments`` images.
    case tooMany
    /// The file could not be read (by name).
    case unreadable(String)
    /// The other Mac did not answer an upload with the stored path (by file name).
    case uploadFailed(String)
    /// The other Mac runs a Supermux without prompt images (by Mac name).
    case updateMac(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return String(
                localized: "supermux.agent.attachment.unsupported",
                defaultValue: "“\(name)” isn’t a PNG, JPEG, GIF or WebP image."
            )
        case .tooLarge(let name):
            return String(
                localized: "supermux.agent.attachment.tooLarge",
                defaultValue: "“\(name)” is larger than 32 MB."
            )
        case .tooMany:
            // The limit is SupermuxAgentAttachmentLimits.maximumAttachments.
            return String(
                localized: "supermux.agent.attachment.tooMany",
                defaultValue: "You can attach up to 10 images."
            )
        case .unreadable(let name):
            return String(
                localized: "supermux.agent.attachment.unreadable",
                defaultValue: "Couldn’t read “\(name)”."
            )
        case .uploadFailed(let name):
            return String(
                localized: "supermux.agent.attachment.uploadFailed",
                defaultValue: "Couldn’t send “\(name)” to the other Mac."
            )
        case .updateMac(let device):
            return String(
                localized: "supermux.agent.attachment.updateMac",
                defaultValue: "Update Supermux on \(device) to attach images."
            )
        }
    }
}
