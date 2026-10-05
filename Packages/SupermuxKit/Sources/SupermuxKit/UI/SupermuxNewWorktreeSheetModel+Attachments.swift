public import Foundation
import SupermuxMobileCore

/// Images attached to the prompt: added by the attach button, a drop or a
/// paste, staged on the selected Mac when Start Claude runs.
extension SupermuxNewWorktreeSheetModel {
    /// Whether the attach button is offered: the selected Mac starts Claude
    /// and takes images, and the sheet is editable.
    public var canAttachImages: Bool {
        phase == .idle && showsPromptEditor && target?.supportsPromptAttachments == true
    }

    /// Converts the images Claude cannot read (HEIC, TIFF, …) off the main
    /// actor, then adds them like ``addAttachments(_:)``. The file picker and
    /// the socket's `fill` use it, as a paste or drop does.
    /// - Parameter files: Image files on this Mac.
    public func attachImages(_ files: [URL]) async {
        await importImages(.files(files))
    }

    /// Converts a paste, drop or pick (``SupermuxPromptImageImporter``), then
    /// adds its files; ``canCreate`` stays false meanwhile.
    func importImages(_ source: SupermuxPromptImageSource, using importer: SupermuxPromptImageImporter = .init()) async {
        guard phase == .idle else { return }
        pendingImageImports += 1
        defer { pendingImageImports -= 1 }
        let files = await importer.files(for: source)
        if files.isEmpty, case .data = source {
            // Pasted or dropped image data that could not be written as a file.
            errorMessage = SupermuxAgentAttachmentError.unreadable("pasted-image").localizedDescription
            return
        }
        addAttachments(files)
    }

    /// Adds image files in order. A file that is not a PNG, JPEG, GIF or WebP
    /// image, is over 32 MB, or would pass the limit of
    /// ``SupermuxAgentAttachmentLimits/maximumAttachments`` is left out and
    /// the first such problem is shown; the others are still added. A file
    /// already attached is not added twice. A symlink is attached as the file
    /// it points to.
    /// - Parameter files: Image files on this Mac.
    public func addAttachments(_ files: [URL]) {
        guard phase == .idle else { return }
        var problem: SupermuxAgentAttachmentError?
        for file in files.map({ $0.standardizedFileURL.resolvingSymlinksInPath() }) {
            if attachments.contains(where: { $0.fileURL == file }) { continue }
            if let refusal = Self.refusal(for: file, attachedCount: attachments.count) {
                problem = problem ?? refusal
                continue
            }
            attachments.append(SupermuxPromptAttachment(fileURL: file))
        }
        errorMessage = problem?.localizedDescription
    }

    /// Removes one attached image.
    /// - Parameter id: The attachment's id.
    public func removeAttachment(id: UUID) {
        guard phase == .idle else { return }
        attachments.removeAll { $0.id == id }
    }

    /// Why `file` cannot be attached next, or `nil` when it can.
    static func refusal(for file: URL, attachedCount: Int) -> SupermuxAgentAttachmentError? {
        let name = file.lastPathComponent
        guard SupermuxAgentAttachmentLimits.imageFileExtensions.contains(file.pathExtension.lowercased()) else {
            return .unsupported(name)
        }
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return .unreadable(name) }
        guard (values?.fileSize ?? 0) <= SupermuxAgentAttachmentLimits.maximumFileBytes else {
            return .tooLarge(name)
        }
        guard attachedCount < SupermuxAgentAttachmentLimits.maximumAttachments else { return .tooMany }
        return nil
    }
}
