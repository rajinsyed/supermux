import AppKit
import Foundation
import SupermuxMobileCore
import UniformTypeIdentifiers

/// Turns what the user pastes, drops or picks into image files the New
/// Worktree prompt can attach.
///
/// Image files are used as they are when Claude reads their format (PNG,
/// JPEG, GIF, WebP); other images (HEIC, TIFF, …) and raw image data (a
/// screenshot copied to the clipboard) are written as PNG files under
/// ``temporaryDirectory``. Text on the pasteboard wins over image data, so
/// pasting text from a rich document still types it.
@MainActor
struct SupermuxPromptImageImporter {
    /// Where pasted image data and converted images are written.
    let temporaryDirectory: URL

    init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-prompt-images", isDirectory: true)
    ) {
        self.temporaryDirectory = temporaryDirectory
    }

    /// Whether the pasteboard holds images to attach rather than text to type:
    /// files of which at least one is an image, or image data without text.
    static func holdsImages(_ pasteboard: NSPasteboard) -> Bool {
        let files = fileURLs(in: pasteboard)
        if !files.isEmpty { return files.contains(where: isImageFile) }
        return pasteboard.string(forType: .string) == nil && NSImage.canInit(with: pasteboard)
    }

    /// The pasteboard's images as attachable files, or `nil` when it holds
    /// none (the text view then pastes or drops as usual).
    func imageFiles(from pasteboard: NSPasteboard) -> [URL]? {
        guard Self.holdsImages(pasteboard) else { return nil }
        let files = Self.fileURLs(in: pasteboard)
        if !files.isEmpty { return attachable(files.filter(Self.isImageFile)) }
        return NSImage(pasteboard: pasteboard).flatMap { writePNG($0, stem: "pasted-image") }.map { [$0] }
    }

    /// `files` with every image Claude cannot read converted to PNG; a file
    /// that cannot be converted is kept as is (the sheet then says why it
    /// cannot be attached).
    func attachable(_ files: [URL]) -> [URL] {
        files.map { file in
            guard !SupermuxAgentAttachmentLimits.imageFileExtensions.contains(file.pathExtension.lowercased()),
                  Self.isImageFile(file),
                  let image = NSImage(contentsOf: file),
                  let converted = writePNG(image, stem: file.deletingPathExtension().lastPathComponent)
            else { return file }
            return converted
        }
    }

    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// Writes `image` as `<stem>.png` in a folder of its own (two pastes never
    /// collide, and the name stays readable).
    private func writePNG(_ image: NSImage, stem: String) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let folder = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(stem.isEmpty ? "image" : stem).appendingPathExtension("png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}
