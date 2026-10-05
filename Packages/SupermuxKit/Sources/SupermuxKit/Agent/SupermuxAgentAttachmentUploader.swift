public import Foundation
public import SupermuxMobileCore

/// Uploads the images attached to a Start Claude prompt to the other Mac
/// that runs Claude, in `agent.attachment.upload` chunks, and returns their
/// paths there for `agent.start`'s `attachment_paths`.
///
/// Each file is its own upload operation (`operation_id`), so the host's
/// per-operation total (64 MiB) never refuses a set the sheet accepted
/// (10 × 32 MiB); each lands in a folder of its own there, made readable to
/// Claude with `--add-dir`. The chunk contract is upstream's
/// `mobile.task.attachment.upload`; `send` performs one call.
///
/// ```swift
/// let uploader = SupermuxAgentAttachmentUploader { params in
///     try await devices.request(.agentAttachmentUpload, params: params, on: machine)
/// }
/// let paths = try await uploader.upload(files)
/// ```
@MainActor
public struct SupermuxAgentAttachmentUploader {
    /// One `agent.attachment.upload` call: its params in, the host's result out.
    public typealias Send = @MainActor (_ params: [String: Any]) async throws -> [String: Any]

    private let chunkBytes: Int
    private let send: Send

    /// Creates the uploader.
    /// - Parameters:
    ///   - chunkBytes: Raw bytes per call (the host's cap by default).
    ///   - send: Performs one call on the other Mac.
    public init(chunkBytes: Int = SupermuxAgentAttachmentLimits.chunkBytes, send: @escaping Send) {
        self.chunkBytes = chunkBytes
        self.send = send
    }

    /// Uploads `files` in order.
    /// - Parameter files: The attached image files.
    /// - Returns: Each file's absolute path on the other Mac, in order.
    /// - Throws: ``SupermuxAgentAttachmentError`` for an unreadable file or a
    ///   reply without a path, `CancellationError` between chunks, otherwise
    ///   the error `send` threw.
    public func upload(_ files: [URL]) async throws -> [String] {
        var paths: [String] = []
        for file in files {
            let data = try await Self.read(file)
            paths.append(try await upload(data, named: file.lastPathComponent, operationID: UUID()))
        }
        return paths
    }

    /// One file, chunk by chunk; the last chunk's reply names the stored file.
    private func upload(_ data: Data, named fileName: String, operationID: UUID) async throws -> String {
        let uploadID = UUID()
        var offset = 0
        repeat {
            try Task.checkCancellation()
            let end = min(offset + chunkBytes, data.count)
            let isLast = end == data.count
            let reply = try await send([
                "operation_id": operationID.uuidString,
                "upload_id": uploadID.uuidString,
                "file_name": fileName,
                "total_bytes": data.count,
                "offset": offset,
                "data_b64": data.subdata(in: offset..<end).base64EncodedString(),
                "last": isLast,
            ])
            if isLast {
                guard let path = reply["path"] as? String, path.hasPrefix("/") else {
                    throw SupermuxAgentAttachmentError.uploadFailed(fileName)
                }
                return path
            }
            offset = end
        } while true
    }

    /// The file's bytes, read off the main actor.
    private static func read(_ file: URL) async throws -> Data {
        do {
            return try await Task.detached(priority: .userInitiated) { try Data(contentsOf: file) }.value
        } catch {
            throw SupermuxAgentAttachmentError.unreadable(file.lastPathComponent)
        }
    }
}
