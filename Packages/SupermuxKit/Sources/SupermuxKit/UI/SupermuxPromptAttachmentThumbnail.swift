import AppKit
import ImageIO
import SwiftUI

/// A small, downscaled preview of one image file (decoded once, by ImageIO,
/// off the main actor: an attached image may be up to 32 MB).
struct SupermuxPromptAttachmentThumbnail: View {
    let fileURL: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: fileURL) {
            guard image == nil else { return }
            let url = fileURL
            let decoded = await Task.detached(priority: .userInitiated) { Self.thumbnail(of: url) }.value
            if let cgImage = decoded?.cgImage {
                image = NSImage(cgImage: cgImage, size: .zero)
            }
        }
    }

    /// A decoded thumbnail handed back from the decoding task; a `CGImage`
    /// is immutable, so passing it across actors is safe.
    private struct Decoded: @unchecked Sendable {
        let cgImage: CGImage
    }

    private nonisolated static func thumbnail(of url: URL) -> Decoded? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 120,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Decoded(cgImage: cgImage)
    }
}
