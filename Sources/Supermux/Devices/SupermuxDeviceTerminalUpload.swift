import CmuxCloud
import CmuxControlSocket
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// The Mac a file pasted or dropped into a device-mirror terminal goes to.
///
/// Resolved per pane when the paste or drop starts, so a device terminal in
/// any workspace (a mirror, or a local workspace showing another Mac's
/// terminal) uploads to the Mac that runs it. `machine` is nil only for a
/// restored pane whose owner is not known yet; its upload fails instead of
/// typing a path that names a file on this Mac.
struct SupermuxDeviceUploadTarget: Equatable, Sendable {
    let machine: SurfaceMachineID?
    /// The owning Mac's id for the workspace the terminal belongs to.
    let remoteWorkspaceID: String?
    let deviceName: String
}

/// Files pasted or dropped into a terminal that runs on another Mac.
///
/// Upstream typed the local path of the file (for a pasted image, a temporary
/// file on this Mac), which names nothing on the Mac running the terminal.
/// A device-mirror pane resolves to ``SupermuxDeviceUploadTarget`` instead
/// (the `device-terminal-upload` touchpoint in
/// `TerminalSurface+ImageTransferTarget.swift`), and each file is uploaded in
/// 3 MB chunks with `mobile.supermux.terminal.attachment.upload`. The owning
/// Mac stores it under `~/.cache/cmux/task-attachments` and answers its path
/// there, which the paste types (shell-escaped) like an SSH upload's.
///
/// Nothing ever falls back to a local path: an owning Mac without
/// `supermux.terminal_attachments.v1`, a link that is down, a folder or a
/// file over the store's limits fails the transfer with a sentence saying
/// why, and nothing is typed.
enum SupermuxDeviceTerminalUpload {
    /// Raw bytes per upload call (the host's chunk cap).
    static let chunkBytes = MobileTaskAttachmentStore.maximumChunkBytes

    // MARK: - Resolution

    /// The upload target for terminal `panelID` in `workspace`, or nil when
    /// another Mac does not run it.
    @MainActor
    static func target(forPanel panelID: UUID, in workspace: Workspace) -> SupermuxDeviceUploadTarget? {
        let projection = SurfaceCatalog.shared.projectionIncludingPendingRestore(forPanel: panelID)
        let mirror = SupermuxComposition.mirrorResolver.target(for: workspace)
        if let projection, projection.resource.machine.isDevice {
            let machine = projection.resource.machine
            return SupermuxDeviceUploadTarget(
                machine: machine,
                remoteWorkspaceID: projection.remoteWorkspaceID
                    ?? (mirror?.machine == machine ? mirror?.remoteWorkspaceID : nil),
                deviceName: SupermuxComposition.devices.device(for: machine)?.displayName
                    ?? mirror?.deviceName ?? otherMacName
            )
        }
        // A restored device pane before its Mac reconnects has no projection yet.
        guard workspace.terminalPanel(for: panelID)?.deviceAttachment != nil else { return nil }
        return SupermuxDeviceUploadTarget(
            machine: mirror?.machine,
            remoteWorkspaceID: mirror?.remoteWorkspaceID,
            deviceName: mirror?.deviceName ?? otherMacName
        )
    }

    private static var otherMacName: String {
        String(localized: "supermux.mirror.otherMac", defaultValue: "the other Mac")
    }

    // MARK: - Upload

    /// Uploads `fileURLs` to `target` and calls `completion` on the main
    /// actor with each file's path on that Mac, in order. Cancelling
    /// `operation` stops between chunks. The caller owns the local files.
    nonisolated static func upload(
        _ fileURLs: [URL],
        to target: SupermuxDeviceUploadTarget,
        operation: TerminalImageTransferOperation,
        completion: @escaping @MainActor (Result<[String], Error>) -> Void
    ) {
        let task = Task { @MainActor in
            do {
                completion(.success(try await upload(fileURLs, to: target, operation: operation)))
            } catch {
                completion(.failure(error))
            }
        }
        operation.installCancellationHandler { task.cancel() }
    }

    @MainActor
    private static func upload(
        _ fileURLs: [URL],
        to target: SupermuxDeviceUploadTarget,
        operation: TerminalImageTransferOperation
    ) async throws -> [String] {
        guard ManagedFileTransferPolicy.isEnabled else { throw ManagedFileTransferPolicy.refusalError() }
        let name = target.deviceName
        guard let machine = target.machine, let workspaceID = target.remoteWorkspaceID else {
            throw SupermuxDeviceError.notConnected(name)
        }
        let devices = SupermuxComposition.devices
        guard let capabilities = await devices.hostCapabilities(on: machine) else {
            throw SupermuxDeviceError.notConnected(name)
        }
        guard capabilities.contains(SupermuxMobileCapability.terminalAttachmentsV1.rawValue) else {
            throw SupermuxDeviceTerminalUploadError.updateMac(name)
        }
        guard fileURLs.count <= MobileTaskAttachmentStore.maximumAttachmentsPerOperation else {
            throw SupermuxDeviceTerminalUploadError.tooManyFiles(MobileTaskAttachmentStore.maximumAttachmentsPerOperation)
        }
        let operationID = UUID()
        var paths: [String] = []
        for fileURL in fileURLs {
            let data = try await readRegularFile(fileURL)
            paths.append(try await uploadFile(
                data, named: fileURL.lastPathComponent, operationID: operationID,
                workspaceID: workspaceID, machine: machine, operation: operation
            ))
        }
        return paths
    }

    /// One file, chunk by chunk; the last chunk's reply names the stored file.
    @MainActor
    private static func uploadFile(
        _ data: Data,
        named fileName: String,
        operationID: UUID,
        workspaceID: String,
        machine: SurfaceMachineID,
        operation: TerminalImageTransferOperation
    ) async throws -> String {
        let uploadID = UUID()
        var offset = 0
        repeat {
            try Task.checkCancellation()
            try operation.throwIfCancelled()
            let end = min(offset + chunkBytes, data.count)
            let isLast = end == data.count
            let reply = try await SupermuxComposition.devices.request(
                .terminalAttachmentUpload,
                params: [
                    "workspace_id": workspaceID,
                    "operation_id": operationID.uuidString,
                    "upload_id": uploadID.uuidString,
                    "file_name": fileName,
                    "total_bytes": data.count,
                    "offset": offset,
                    "data_b64": data.subdata(in: offset..<end).base64EncodedString(),
                    "last": isLast,
                ],
                on: machine
            )
            if isLast {
                guard let path = reply["path"] as? String, path.hasPrefix("/") else {
                    throw SupermuxDeviceError.malformedResponse(SupermuxMobileMethod.terminalAttachmentUpload.rawValue)
                }
                return path
            }
            offset = end
        } while true
    }

    /// The file's bytes, read off the main actor. Only regular files within
    /// the host store's size cap upload.
    private static func readRegularFile(_ fileURL: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let url = fileURL.standardizedFileURL
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else {
                throw SupermuxDeviceTerminalUploadError.notAFile(url.lastPathComponent)
            }
            guard (values?.fileSize ?? 0) <= MobileTaskAttachmentStore.maximumFileBytes else {
                throw SupermuxDeviceTerminalUploadError.tooLarge(url.lastPathComponent)
            }
            return try Data(contentsOf: url)
        }.value
    }
}

/// Why a file could not go to the other Mac; shown in the upload-failed notification.
enum SupermuxDeviceTerminalUploadError: Error, LocalizedError, Equatable {
    /// The owning Mac runs a Supermux without `terminal.attachment.upload`.
    case updateMac(String)
    /// A folder (or anything else that is not a regular file).
    case notAFile(String)
    /// Over the owning Mac's per-file cap.
    case tooLarge(String)
    /// More files than one upload takes.
    case tooManyFiles(Int)

    var errorDescription: String? {
        switch self {
        case .updateMac(let name):
            return String(
                localized: "supermux.terminalUpload.updateMac",
                defaultValue: "Update Supermux on \(name) to paste files into its terminals."
            )
        case .notAFile(let file):
            return String(
                localized: "supermux.terminalUpload.notAFile",
                defaultValue: "“\(file)” is a folder. Only files can be pasted into a terminal on another Mac."
            )
        case .tooLarge(let file):
            return String(
                localized: "supermux.terminalUpload.tooLarge",
                defaultValue: "“\(file)” is larger than 32 MB, the most a terminal on another Mac takes."
            )
        case .tooManyFiles(let limit):
            return String(
                localized: "supermux.terminalUpload.tooManyFiles",
                defaultValue: "Paste at most \(limit) files at a time into a terminal on another Mac."
            )
        }
    }
}
