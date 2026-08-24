import Foundation

/// Validates image attachments before they cross a harness protocol boundary.
public struct SupermuxHarnessAttachmentPolicy: Sendable {
    /// Claude's direct-API ceiling for one decoded image payload.
    public static let maximumImageBytes = 10 * 1024 * 1024
    /// Keeps base64 expansion plus JSON below the standard 32 MiB request envelope.
    public static let maximumTotalImageBytes = 20 * 1024 * 1024
    /// The largest image count accepted by the composer's single attachment strip.
    public static let maximumImageCount = 8
    /// MIME types accepted by Claude's image content-block protocol.
    public static let supportedMediaTypes: Set<String> = [
        "image/gif",
        "image/jpeg",
        "image/png",
        "image/webp",
    ]

    /// Creates the shared harness attachment policy.
    public init() {}

    /// Validates every image and the aggregate decoded-byte budget.
    ///
    /// Validation is strict: MIME types must be supported, base64 must be canonical
    /// enough for Foundation's strict decoder, and decoded data must be non-empty.
    ///
    /// - Parameter images: The attachments to validate as one message.
    /// - Throws: ``ValidationError`` when any attachment violates the contract.
    public func validate(_ images: [SupermuxHarnessImage]) throws {
        guard images.count <= Self.maximumImageCount else {
            throw ValidationError.tooManyImages(
                maximum: Self.maximumImageCount,
                actual: images.count
            )
        }

        var totalDecodedBytes = 0
        for (index, image) in images.enumerated() {
            guard Self.supportedMediaTypes.contains(image.mediaType) else {
                throw ValidationError.unsupportedMediaType(
                    index: index,
                    mediaType: image.mediaType
                )
            }

            // Bound the encoded representation before asking Foundation to allocate
            // decoded storage for an untrusted bridge string.
            let maximumEncodedBytes = ((Self.maximumImageBytes + 2) / 3) * 4
            let encodedByteCount = image.dataBase64.utf8.count
            guard encodedByteCount <= maximumEncodedBytes else {
                throw ValidationError.imageTooLarge(
                    index: index,
                    maximumBytes: Self.maximumImageBytes,
                    actualBytes: Self.maximumImageBytes + 1
                )
            }
            guard let decoded = Data(base64Encoded: image.dataBase64), !decoded.isEmpty else {
                throw ValidationError.invalidBase64(index: index)
            }
            guard decoded.count <= Self.maximumImageBytes else {
                throw ValidationError.imageTooLarge(
                    index: index,
                    maximumBytes: Self.maximumImageBytes,
                    actualBytes: decoded.count
                )
            }

            totalDecodedBytes += decoded.count
            guard totalDecodedBytes <= Self.maximumTotalImageBytes else {
                throw ValidationError.totalTooLarge(
                    maximumBytes: Self.maximumTotalImageBytes,
                    actualBytes: totalDecodedBytes
                )
            }
        }
    }

    /// Stable rejection codes shared with attachment-picker bridge responses.
    public enum RejectionCode: String, Equatable, Sendable {
        /// The declared MIME type is not supported by the protocol.
        case unsupportedMediaType
        /// The image is empty, unreadable, or not strict base64.
        case invalidImage
        /// One decoded image exceeds the per-image byte limit.
        case imageTooLarge
        /// The message's decoded images exceed the aggregate byte limit.
        case totalTooLarge
        /// The message exceeds the attachment-strip image count.
        case tooManyImages
    }

    /// A typed reason an attachment message violates the shared policy.
    public enum ValidationError: Error, Equatable, Sendable {
        /// The message carries more images than the composer can own safely.
        case tooManyImages(maximum: Int, actual: Int)
        /// An image declares a MIME type unsupported by the protocol.
        case unsupportedMediaType(index: Int, mediaType: String)
        /// An image payload is empty or not strict base64.
        case invalidBase64(index: Int)
        /// One decoded image exceeds its byte budget.
        case imageTooLarge(index: Int, maximumBytes: Int, actualBytes: Int)
        /// The decoded images collectively exceed their byte budget.
        case totalTooLarge(maximumBytes: Int, actualBytes: Int)

        /// The stable bridge code for this rejection.
        public var rejectionCode: RejectionCode {
            switch self {
            case .tooManyImages:
                return .tooManyImages
            case .unsupportedMediaType:
                return .unsupportedMediaType
            case .invalidBase64:
                return .invalidImage
            case .imageTooLarge:
                return .imageTooLarge
            case .totalTooLarge:
                return .totalTooLarge
            }
        }
    }
}
