import AppKit
import Foundation
import ImageIO
import SupermuxMobileCore
import UniformTypeIdentifiers

/// What a paste, drop or the file picker hands the New Worktree prompt,
/// read on the main actor; ``SupermuxPromptImageImporter/files(for:)`` turns
/// it into attachable files off it.
enum SupermuxPromptImageSource: Sendable {
    /// Image files (dropped or copied in Finder, or picked).
    case files([URL])
    /// Raw image data of `type` (a screenshot copied to the clipboard).
    case data(Data, UTType)
}

/// Turns what the user pastes, drops or picks into image files the New
/// Worktree prompt can attach.
///
/// Images Claude reads (PNG, JPEG, GIF, WebP) are used as they are. Other
/// images (HEIC, TIFF, …) are converted, off the main actor, into a folder of
/// their own under ``temporaryDirectory``: an image with transparency to PNG,
/// a photo (HEIF/HEIC, camera RAW) to JPEG so it stays about its original
/// size, and anything else to PNG, or JPEG when the PNG would pass
/// ``SupermuxAgentAttachmentLimits/maximumFileBytes``. Text on the pasteboard
/// wins over image data, so pasting text from a rich document still types it.
struct SupermuxPromptImageImporter: Sendable {
    /// Where pasted image data and converted images are written.
    let temporaryDirectory: URL

    init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-prompt-images", isDirectory: true)
    ) {
        self.temporaryDirectory = temporaryDirectory
    }

    // MARK: - Pasteboard (main actor)

    /// Whether the pasteboard holds images to attach rather than text to type:
    /// files that are all images, or image data without text. Files mixed
    /// with non-images paste or drop as their paths, as before.
    @MainActor
    static func holdsImages(_ pasteboard: NSPasteboard) -> Bool {
        let files = fileURLs(in: pasteboard)
        if !files.isEmpty { return files.allSatisfy(isImageFile) }
        return pasteboard.string(forType: .string) == nil && NSImage.canInit(with: pasteboard)
    }

    /// The pasteboard's images, or `nil` when it holds none (the text view
    /// then pastes or drops as usual).
    @MainActor
    static func source(from pasteboard: NSPasteboard) -> SupermuxPromptImageSource? {
        guard holdsImages(pasteboard) else { return nil }
        let files = fileURLs(in: pasteboard)
        if !files.isEmpty { return .files(files) }
        // Data ImageIO decodes as written; anything else NSImage reads (PDF,
        // SVG, …) as TIFF.
        for type in pasteboard.types ?? [] {
            guard let uti = UTType(type.rawValue), uti.conforms(to: .image), isDecodable(uti),
                  let data = pasteboard.data(forType: type) else { continue }
            return .data(data, uti)
        }
        return NSImage(pasteboard: pasteboard)?.tiffRepresentation.map { .data($0, .tiff) }
    }

    @MainActor
    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: - Conversion (off the main actor)

    /// The source's images as attachable files, converted off the main actor.
    func files(for source: SupermuxPromptImageSource) async -> [URL] {
        await Task.detached(priority: .userInitiated) { [self] in
            switch source {
            case .files(let files):
                return attachable(files)
            case .data(let data, let type):
                return writeAttachable(data, type: type).map { [$0] } ?? []
            }
        }.value
    }

    /// `files` with every image Claude cannot read converted; a file that
    /// cannot be converted is kept as is (the sheet then says why it cannot
    /// be attached).
    private func attachable(_ files: [URL]) -> [URL] {
        files.map { file in
            guard !Self.isClaudeFormat(file.pathExtension),
                  let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
                  let source = Self.isDecodable(type)
                      ? CGImageSourceCreateWithURL(file as CFURL, nil)
                      : Self.rendered(NSImage(contentsOf: file)),
                  let converted = convert(source, type: type, stem: file.deletingPathExtension().lastPathComponent)
            else { return file }
            return converted
        }
    }

    /// Pasted image data as a file: written as is in a format Claude reads,
    /// else converted.
    private func writeAttachable(_ data: Data, type: UTType) -> URL? {
        let stem = "pasted-image"
        if let ext = type.preferredFilenameExtension, Self.isClaudeFormat(ext) {
            return write(data, stem: stem, extension: ext)
        }
        let source = Self.isDecodable(type)
            ? CGImageSourceCreateWithData(data as CFData, nil)
            : Self.rendered(NSImage(data: data))
        return source.flatMap { convert($0, type: type, stem: stem) }
    }

    /// Re-encodes the first image of `source` (of format `type`) upright, as
    /// PNG or JPEG (see the type's documentation for which).
    private func convert(_ source: CGImageSource, type: UTType, stem: String) -> URL? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let image = Self.uprightImage(source, properties: properties) else { return nil }
        let isPhoto = type.conforms(to: .heif) || type.conforms(to: .heic) || type.conforms(to: .rawImage)
        let formats: [UTType]
        if properties[kCGImagePropertyHasAlpha] as? Bool == true {
            formats = [.png]
        } else if isPhoto {
            formats = [.jpeg]
        } else {
            formats = [.png, .jpeg]
        }
        for format in formats {
            guard let encoded = Self.encode(image, as: format) else { continue }
            if format != formats.last, encoded.count > SupermuxAgentAttachmentLimits.maximumFileBytes { continue }
            return write(encoded, stem: stem, extension: format.preferredFilenameExtension ?? "png")
        }
        return nil
    }

    /// The full-size image with its EXIF orientation applied (Claude does not
    /// read the orientation tag).
    private static func uprightImage(_ source: CGImageSource, properties: [CFString: Any]) -> CGImage? {
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Whether ImageIO decodes `type` (it does not decode SVG or PDF).
    private static func isDecodable(_ type: UTType) -> Bool {
        (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).contains(type.identifier)
    }

    /// An image only `NSImage` reads (SVG, PDF), rendered as TIFF for ImageIO.
    private static func rendered(_ image: NSImage?) -> CGImageSource? {
        guard let tiff = image?.tiffRepresentation else { return nil }
        return CGImageSourceCreateWithData(tiff as CFData, nil)
    }

    private static func encode(_ image: CGImage, as format: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Writes `data` as `<stem>.<extension>` in a folder of its own (two
    /// pastes never collide, and the name stays readable).
    private func write(_ data: Data, stem: String, extension ext: String) -> URL? {
        let folder = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(stem.isEmpty ? "image" : stem).appendingPathExtension(ext)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    private static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private static func isClaudeFormat(_ fileExtension: String) -> Bool {
        SupermuxAgentAttachmentLimits.imageFileExtensions.contains(fileExtension.lowercased())
    }
}
