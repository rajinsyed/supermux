import CmuxCloud
import CmuxControlSocket
import Foundation

/// The host side of files other devices upload here: a file pasted or dropped
/// into another Mac's device mirror of a terminal here (capability
/// `supermux.terminal_attachments.v1`), and an image attached to a Start
/// Claude prompt that runs here (`supermux.agent_attachments.v1`).
///
/// `mobile.supermux.terminal.attachment.upload` and
/// `mobile.supermux.agent.attachment.upload` take upstream's
/// `mobile.task.attachment.upload` chunk contract (`operation_id`,
/// `upload_id`, `file_name`, `total_bytes`, `offset`, `data_b64`, `last`)
/// and store the file in the same ``MobileTaskAttachmentStore``
/// (`~/.cache/cmux/task-attachments`, pruned after 7 days). The last chunk
/// answers the stored file's absolute `path`: the other Mac types it into
/// the terminal, or sends it back in `agent.start`'s `attachment_paths`.
/// Unlike upstream's method neither is gated on the Task Composer feature
/// flag: a paste into a terminal is not a task. A terminal upload names the
/// mirrored `workspace_id`, so a workspace-pinned ticket can upload only into
/// its own workspace; a prompt image has no workspace yet and needs a
/// Mac-wide ticket, like `agent.start` (``SupermuxMobileAuthorization``).
extension TerminalController {
    func v2SupermuxTerminalAttachmentUpload(params: [String: Any]) -> V2CallResult {
        supermuxStoreAttachmentChunk(params, requiresWorkspace: true)
    }

    func v2SupermuxAgentAttachmentUpload(params: [String: Any]) -> V2CallResult {
        supermuxStoreAttachmentChunk(params, requiresWorkspace: false)
    }

    /// Stores one chunk in the task-attachment store; the last answers `path`.
    private func supermuxStoreAttachmentChunk(_ params: [String: Any], requiresWorkspace: Bool) -> V2CallResult {
        guard !ManagedFileTransferPolicy.isDisabled else {
            return .err(code: "forbidden", message: ManagedFileTransferPolicy.disabledMessage, data: nil)
        }
        guard !requiresWorkspace || v2RawString(params, "workspace_id")?.isEmpty == false,
              let request = Self.supermuxAttachmentUploadRequest(params) else {
            return .err(code: "invalid_params", message: "Missing or invalid attachment upload parameters", data: nil)
        }
        let store = MobileTaskAttachmentStore(
            rootURL: MobileTaskAttachmentStore.defaultRootURL(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ),
            now: Date(),
            fileManager: FileManager.default
        )
        do {
            let result = try store.upload(request)
            var payload: [String: Any] = ["received_bytes": result.receivedBytes]
            if let path = result.path { payload["path"] = path }
            return .ok(payload)
        } catch let error as MobileTaskAttachmentStoreError {
            return .err(code: error.code, message: error.message, data: nil)
        } catch {
            return .err(code: "internal_error", message: "Could not store the attachment", data: nil)
        }
    }

    private static func supermuxAttachmentUploadRequest(_ params: [String: Any]) -> MobileTaskAttachmentUploadRequest? {
        guard let operationID = (params["operation_id"] as? String).flatMap(UUID.init(uuidString:)),
              let uploadID = (params["upload_id"] as? String).flatMap(UUID.init(uuidString:)),
              let fileName = params["file_name"] as? String,
              let totalBytes = params["total_bytes"] as? Int,
              let offset = params["offset"] as? Int,
              let dataBase64 = params["data_b64"] as? String,
              let isLast = params["last"] as? Bool else { return nil }
        return MobileTaskAttachmentUploadRequest(
            operationID: operationID,
            uploadID: uploadID,
            fileName: fileName,
            totalBytes: totalBytes,
            offset: offset,
            dataBase64: dataBase64,
            isLast: isLast
        )
    }
}
