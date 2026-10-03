import CmuxCloud
import CmuxControlSocket
import Foundation

/// The host side of a file pasted or dropped into another Mac's device mirror
/// of a terminal here (capability `supermux.terminal_attachments.v1`).
///
/// `mobile.supermux.terminal.attachment.upload` takes upstream's
/// `mobile.task.attachment.upload` chunk contract (`operation_id`,
/// `upload_id`, `file_name`, `total_bytes`, `offset`, `data_b64`, `last`)
/// and stores the file in the same ``MobileTaskAttachmentStore``
/// (`~/.cache/cmux/task-attachments`, pruned after 7 days). The last chunk
/// answers the stored file's absolute `path`, which the other Mac types into
/// the terminal. Unlike upstream's method it is not gated on the Task
/// Composer feature flag: a paste into a terminal is not a task. The request
/// names the mirrored `workspace_id`, so a workspace-pinned ticket can upload
/// only into its own workspace (``SupermuxMobileAuthorization``).
extension TerminalController {
    func v2SupermuxTerminalAttachmentUpload(params: [String: Any]) -> V2CallResult {
        guard !ManagedFileTransferPolicy.isDisabled else {
            return .err(code: "forbidden", message: ManagedFileTransferPolicy.disabledMessage, data: nil)
        }
        guard v2RawString(params, "workspace_id")?.isEmpty == false,
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
