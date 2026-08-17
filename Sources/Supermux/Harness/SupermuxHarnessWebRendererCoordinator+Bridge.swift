import AppKit
import SupermuxKit
import UniformTypeIdentifiers
import WebKit

extension SupermuxHarnessWebRendererCoordinator {
    func handle(_ request: SupermuxHarnessBridgeRequest) async throws -> Any {
        guard let controller = sessionController else {
            throw SupermuxHarnessBridgeError.invalidRequest
        }
        if let reply = try await handleTaskBridgeRequest(request, controller: controller) {
            return reply
        }
        switch request.method {
        case "harness.context":
            let bootstrap = await controller.contextBootstrap()
            var context: [String: Any] = [
                "panelId": panelId.uuidString,
                "workspaceId": workspaceId.uuidString,
                "theme": theme.dictionary,
                "copy": SupermuxHarnessCopy.dictionary(),
                "cliStatus": bootstrap.cliStatus,
            ]
            if let workingDirectory = controller.workingDirectory {
                context["workingDirectory"] = workingDirectory
            }
            if let restore = controller.restoreContext {
                context["restore"] = restore
            }
            if let draft = controller.composerDraft, !draft.isEmpty {
                context["draft"] = draft
            }
            if let cachedModels = bootstrap.cachedModels {
                context["cachedModels"] = cachedModels
            }
            return context
        case "harness.listSessions":
            return ["sessions": try await controller.listSessions(limit: request.integer("limit"))]
        case "harness.loadSessionHistory":
            return try await controller.loadSessionHistory(
                sessionId: try request.requiredString("sessionId")
            )
        case "harness.start":
            controller.invalidateCLIStatus()
            let runId = try await controller.start(
                resumeSessionId: request.string("resumeSessionId"),
                forkSession: request.bool("forkSession") ?? false,
                model: request.string("model"),
                permissionMode: request.string("permissionMode"),
                effort: request.string("effort")
            )
            return ["runId": runId]
        case "harness.restart":
            controller.invalidateCLIStatus()
            let runId = try await controller.restart(
                resumeSessionId: request.string("resumeSessionId"),
                forkSession: request.bool("forkSession") ?? false,
                model: request.string("model"),
                permissionMode: request.string("permissionMode"),
                effort: request.string("effort")
            )
            return ["runId": runId]
        case "harness.openSessionInNewPane":
            try openSessionInNewPane(
                sessionId: try request.requiredString("sessionId"),
                workingDirectory: controller.workingDirectory
            )
            return [:] as [String: Any]
        case "harness.send":
            let images = (request.objects("images") ?? []).compactMap { entry -> SupermuxHarnessImage? in
                guard let mediaType = entry["mediaType"] as? String,
                      let dataBase64 = entry["dataBase64"] as? String else {
                    return nil
                }
                return SupermuxHarnessImage(mediaType: mediaType, dataBase64: dataBase64)
            }
            try await controller.send(
                text: try request.requiredRawString("text"),
                images: images,
                uuid: try request.requiredString("uuid")
            )
            return ["sent": true]
        case "harness.interrupt":
            try await controller.interrupt(cancelQueued: request.bool("cancelQueued") ?? false)
            return [:] as [String: Any]
        case "harness.cancelQueued":
            try await controller.cancelQueued(messageUuid: try request.requiredString("messageUuid"))
            return [:] as [String: Any]
        case "harness.stop":
            await controller.stop()
            return [:] as [String: Any]
        case "harness.setModel":
            try await controller.setModel(
                model: try request.requiredString("model"),
                effort: request.string("effort")
            )
            return [:] as [String: Any]
        case "harness.setPermissionMode":
            try await controller.setPermissionMode(try request.requiredString("mode"))
            return [:] as [String: Any]
        case "harness.respondPermission":
            try await controller.respondPermission(
                requestId: try request.requiredString("requestId"),
                behavior: try request.requiredString("behavior"),
                updatedInput: request.object("updatedInput"),
                updatedPermissions: request.objects("updatedPermissions"),
                message: request.rawString("message"),
                interrupt: request.bool("interrupt") ?? false
            )
            return [:] as [String: Any]
        case "harness.renameSession":
            try await controller.renameSession(title: try request.requiredString("title"))
            return [:] as [String: Any]
        case "harness.getContextUsage":
            return try await controller.getContextUsage()
        case "harness.fileSuggestions":
            return await controller.fileSuggestions(query: request.rawString("query") ?? "")
        case "harness.pickFiles":
            return await pickLocalFiles()
        case "harness.openFile":
            openFileInWorkspace(
                path: try request.requiredString("path"),
                line: request.integer("line")
            )
            return [:] as [String: Any]
        case "harness.copyText":
            let text = try request.requiredRawString("text")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return [:] as [String: Any]
        case "harness.saveFile":
            let saved = await saveTextFile(
                suggestedName: try request.requiredString("suggestedName"),
                text: try request.requiredRawString("text")
            )
            return ["saved": saved]
        case "harness.notify":
            postNotificationIfUnfocused(
                title: try request.requiredString("title"),
                body: request.rawString("body") ?? ""
            )
            return [:] as [String: Any]
        case "harness.saveDraft":
            controller.composerDraft = request.rawString("text")
            return [:] as [String: Any]
        case "harness.getBinarySetting":
            return await controller.binarySettingState()
        case "harness.setBinaryPath":
            return try await controller.setBinaryPath(request.rawString("path"))
        case "harness.rewindPreview":
            return await controller.rewindPreview(
                userMessageUuid: try request.requiredString("userMessageUuid")
            )
        case "harness.rewind":
            return try await controller.rewind(
                userMessageUuid: try request.requiredString("userMessageUuid"),
                restoreFiles: request.bool("restoreFiles") ?? false,
                resumeAtUuid: request.string("resumeAtUuid")
            )
        default:
            throw SupermuxHarnessBridgeError.unsupportedMethod(request.method)
        }
    }

    func handleTaskBridgeRequest(
        _ request: SupermuxHarnessBridgeRequest,
        controller: SupermuxHarnessSessionController
    ) async throws -> Any? {
        switch request.method {
        case "harness.stopTask":
            try await controller.stopTask(taskId: try request.requiredString("taskId"))
            return [:] as [String: Any]
        case "harness.backgroundTask":
            return try await controller.backgroundTask(toolUseId: request.string("toolUseId"))
        case "harness.loadSubagentTranscript":
            return try await controller.loadSubagentTranscript(
                taskId: request.string("taskId"),
                workflowRunId: request.string("workflowRunId"),
                agentId: request.string("agentId")
            )
        case "harness.readTaskOutput":
            return try await controller.readTaskOutput(
                taskId: try request.requiredString("taskId")
            )
        default:
            return nil
        }
    }

    private func openSessionInNewPane(
        sessionId: String,
        workingDirectory: String?
    ) throws {
        guard let app = AppDelegate.shared,
              let location = app.workspaceContainingPanel(
                  panelId: panelId,
                  preferredWorkspaceId: workspaceId
              ),
              let sourcePaneId = location.workspace.paneId(forPanelId: panelId) else {
            throw SupermuxHarnessBridgeError.openPaneFailed
        }
        var restore = SessionSupermuxHarnessPanelSnapshot()
        restore.workingDirectory = workingDirectory
        restore.sessionId = sessionId
        guard location.workspace.splitPaneWithSupermuxHarness(
            targetPane: sourcePaneId,
            restoreState: restore
        ) != nil else {
            throw SupermuxHarnessBridgeError.openPaneFailed
        }
    }

    /// `<a download>` is inert inside a file://-loaded WKWebView, so a save is
    /// only real when it goes through the native panel.
    private func saveTextFile(suggestedName: String, text: String) async -> Bool {
        let panel = NSSavePanel()
        panel.title = String(
            localized: "supermux.harness.saveFile.title",
            defaultValue: "Save file"
        )
        panel.nameFieldStringValue = (suggestedName as NSString).lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private func pickLocalFiles() async -> [String: Any] {
        let panel = NSOpenPanel()
        let title = String(
            localized: "supermux.harness.pickFiles.title",
            defaultValue: "Add photos & files"
        )
        panel.title = title
        panel.prompt = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK else {
            return ["images": [], "paths": []]
        }

        let urls = panel.urls
        return await Task.detached(priority: .userInitiated) {
            var images: [[String: Any]] = []
            var paths: [String] = []
            var remainingBytes = Self.imagePreviewTotalMaxBytes
            for url in urls {
                let type = UTType(filenameExtension: url.pathExtension)
                if type?.conforms(to: .image) == true,
                   let byteCount = Self.regularFileByteCount(url),
                   byteCount <= Self.imagePreviewMaxBytes,
                   byteCount <= remainingBytes,
                   let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                   data.count <= byteCount {
                    remainingBytes -= data.count
                    images.append([
                        "mediaType": type?.preferredMIMEType ?? "image/png",
                        "dataBase64": data.base64EncodedString(),
                        "name": url.lastPathComponent,
                    ])
                    continue
                }
                paths.append(url.path)
            }
            return ["images": images, "paths": paths]
        }.value
    }

    nonisolated private static func regularFileByteCount(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType != .typeSymbolicLink,
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        let byteCount = size.intValue
        return byteCount >= 0 ? byteCount : nil
    }

    private func openFileInWorkspace(path: String, line: Int?) {
        _ = line
        guard let app = AppDelegate.shared,
              let location = app.workspaceContainingPanel(
                  panelId: panelId,
                  preferredWorkspaceId: workspaceId
              ),
              let paneId = location.workspace.paneId(forPanelId: panelId) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        _ = location.workspace.newFilePreviewSurface(
            inPane: paneId,
            filePath: path,
            focus: true
        )
    }

    private func postNotificationIfUnfocused(title: String, body: String) {
        deliverHarnessNotification(title: title, subtitle: "", body: body, category: nil)
    }

    func postTurnCompleteNotificationIfUnfocused(_ frame: SupermuxHarnessResultFrame) {
        let subtitle: String
        if frame.isError {
            subtitle = String(
                localized: "supermux.harness.notification.turnFailed",
                defaultValue: "Claude hit an error"
            )
        } else {
            subtitle = String(
                localized: "supermux.harness.notification.turnComplete",
                defaultValue: "Claude finished responding"
            )
        }
        deliverHarnessNotification(
            title: String(localized: "supermux.harness.notification.title", defaultValue: "Claude"),
            subtitle: subtitle,
            body: frame.result.map { String($0.prefix(180)) } ?? "",
            // Error results always deliver, mirroring the terminal hook's
            // "error alerts always deliver" rule.
            category: frame.isError ? nil : .turnComplete
        )
    }

    func postPermissionNotificationIfUnfocused(toolName: String) {
        let subtitle = toolName.isEmpty
            ? String(
                localized: "supermux.harness.notification.permissionNeeded",
                defaultValue: "Claude needs your approval"
            )
            : String(
                format: String(
                    localized: "supermux.harness.notification.permissionNeededFormat",
                    defaultValue: "Claude wants to use %@"
                ),
                toolName
            )
        deliverHarnessNotification(
            title: String(localized: "supermux.harness.notification.title", defaultValue: "Claude"),
            subtitle: subtitle,
            body: "",
            category: .needsPermission
        )
    }

    /// The same policy gate, delivery path, and unread-badge store the
    /// terminal's Claude Code hooks reach through `notify_target_async`:
    /// `AgentNotificationDelivery` applies the user's per-category settings and
    /// the notification store handles focus suppression, the sidebar unread
    /// badge, and the system banner.
    private func deliverHarnessNotification(
        title: String,
        subtitle: String,
        body: String,
        category: AgentNotifyCategory?
    ) {
        _ = AgentNotificationDelivery().enqueue(
            workspaceID: workspaceId,
            surfaceID: panelId,
            title: title,
            subtitle: subtitle,
            body: body,
            category: category,
            pending: false,
            coalesces: true
        )
    }
}
