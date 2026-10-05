public import Foundation
public import SupermuxMobileCore

/// Uploads the images attached to a Start Claude prompt to the other Mac
/// that runs Claude, in `agent.attachment.upload` chunks, and returns their
/// paths there for `agent.start`'s `attachment_paths`.
///
/// Files share an upload operation (`operation_id`) until the next one would
/// pass its 64 MiB total, so the host never refuses a set the sheet accepted
/// (10 × 32 MiB), and few operations means few folders there: each becomes
/// one `--add-dir`, and every one of them must fit the launch line (see
/// ``SupermuxAgentLaunchCommand/maxInputUTF8Length``). The chunk contract is
/// upstream's `mobile.task.attachment.upload`; `send` performs one call.
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
        var operationID = UUID()
        var operationBytes = 0
        var operationFiles = 0
        for file in files {
            let data = try await Self.read(file)
            if operationFiles == SupermuxAgentAttachmentLimits.maximumAttachments
                || operationBytes + data.count > SupermuxAgentAttachmentLimits.maximumOperationBytes {
                operationID = UUID()
                operationBytes = 0
                operationFiles = 0
            }
            operationBytes += data.count
            operationFiles += 1
            paths.append(try await upload(data, named: file.lastPathComponent, operationID: operationID))
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
