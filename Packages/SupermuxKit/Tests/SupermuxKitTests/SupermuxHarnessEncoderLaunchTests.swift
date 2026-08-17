import Foundation
import Testing

@testable import SupermuxKit

@Suite struct SupermuxHarnessEncoderLaunchTests {
    private let encoder = SupermuxHarnessProtocolEncoder()

    @Test func textUserMessageHasStringContentAndExactlyOneNewline() throws {
        let frame = try encoder.userMessage(
            text: "hello",
            uuid: "message-id",
            sessionID: "session-id"
        )
        let object = try frame.jsonObject()
        #expect(object.string(forKey: "type") == "user")
        #expect(object.string(forKey: "uuid") == "message-id")
        #expect(object.string(forKey: "session_id") == "session-id")
        #expect(object.object(forKey: "message")?.string(forKey: "role") == "user")
        #expect(object.object(forKey: "message")?.string(forKey: "content") == "hello")
        #expect(frame.lineData == frame.jsonData + Data([0x0A]))
        #expect(frame.jsonData.last != 0x0A)
        #expect(frame.lineData.last == 0x0A)
    }

    @Test func imageUserMessageUsesTextThenBase64ImageBlocks() throws {
        let frame = try encoder.userMessage(
            text: "inspect",
            images: [
                SupermuxHarnessImage(mediaType: "image/png", dataBase64: "cG5n"),
                SupermuxHarnessImage(mediaType: "image/jpeg", dataBase64: "anBlZw=="),
            ],
            uuid: "message-id"
        )
        let object = try frame.jsonObject()
        let content = try #require(object.object(forKey: "message")?.rawValue["content"] as? [[String: Any]])
        #expect(content.count == 3)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "inspect")
        #expect(content[1]["type"] as? String == "image")
        let firstSource = try #require(content[1]["source"] as? [String: Any])
        #expect(firstSource["type"] as? String == "base64")
        #expect(firstSource["media_type"] as? String == "image/png")
        #expect(firstSource["data"] as? String == "cG5n")
        let secondSource = try #require(content[2]["source"] as? [String: Any])
        #expect(secondSource["media_type"] as? String == "image/jpeg")
        #expect(object.rawValue["session_id"] == nil)
    }

    @Test func imageOnlyMessageOmitsEmptyTextBlock() throws {
        let frame = try encoder.userMessage(
            text: "",
            images: [SupermuxHarnessImage(mediaType: "image/png", dataBase64: "AA==")],
            uuid: "message-id"
        )
        let content = try #require(
            try frame.jsonObject().object(forKey: "message")?.rawValue["content"] as? [[String: Any]]
        )
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "image")
    }

    @Test func genericControlRequestWrapsRequestIDAndPayload() throws {
        let frame = try encoder.controlRequest(.renameSession(title: "New name"), requestID: "request")
        let (object, request) = try controlRequestParts(frame)
        #expect(object.string(forKey: "type") == "control_request")
        #expect(object.string(forKey: "request_id") == "request")
        #expect(request.string(forKey: "subtype") == "rename_session")
        #expect(request.string(forKey: "title") == "New name")
    }

    @Test func initializeControlRequestAdvertisesCanUseToolCapability() throws {
        let (_, request) = try controlRequestParts(
            encoder.initializeControlRequest(requestID: "initialize")
        )
        #expect(request.string(forKey: "subtype") == "initialize")
        #expect(request.object(forKey: "capabilities")?.bool(forKey: "canUseTool") == true)
    }

    @Test func interruptControlRequestOmitsOrEncodesCancelQueued() throws {
        let (_, omitted) = try controlRequestParts(
            encoder.interruptControlRequest(requestID: "interrupt")
        )
        #expect(omitted.string(forKey: "subtype") == "interrupt")
        #expect(omitted.rawValue["cancel_queued"] == nil)

        let (_, included) = try controlRequestParts(
            encoder.interruptControlRequest(requestID: "interrupt", cancelQueued: true)
        )
        #expect(included.bool(forKey: "cancel_queued") == true)
    }

    @Test(arguments: SupermuxHarnessPermissionMode.allCases)
    func permissionModeControlRequestEncodesEveryMode(_ mode: SupermuxHarnessPermissionMode) throws {
        let (_, request) = try controlRequestParts(
            encoder.setPermissionModeControlRequest(requestID: "mode", mode: mode)
        )
        #expect(request.string(forKey: "subtype") == "set_permission_mode")
        #expect(request.string(forKey: "mode") == mode.rawValue)
    }

    @Test func modelControlRequestEncodesEffortAndNullReset() throws {
        let (_, selected) = try controlRequestParts(
            encoder.setModelControlRequest(requestID: "model", model: "claude-haiku-4-5", effort: "high")
        )
        #expect(selected.string(forKey: "subtype") == "set_model")
        #expect(selected.string(forKey: "model") == "claude-haiku-4-5")
        #expect(selected.string(forKey: "effort") == "high")

        let (_, reset) = try controlRequestParts(
            encoder.setModelControlRequest(requestID: "model", model: nil)
        )
        #expect(reset.rawValue["model"] is NSNull)
        #expect(reset.rawValue["effort"] == nil)
    }

    @Test func maximumThinkingTokensControlRequestEncodesValueAndNullReset() throws {
        let (_, selected) = try controlRequestParts(
            encoder.setMaxThinkingTokensControlRequest(requestID: "thinking", maximumTokens: 4096)
        )
        #expect(selected.string(forKey: "subtype") == "set_max_thinking_tokens")
        #expect(selected.integer(forKey: "max_thinking_tokens") == 4096)

        let (_, reset) = try controlRequestParts(
            encoder.setMaxThinkingTokensControlRequest(requestID: "thinking", maximumTokens: nil)
        )
        #expect(reset.rawValue["max_thinking_tokens"] is NSNull)
    }

    @Test func rewindFilesControlRequestEncodesMessageUUIDAndDryRunMode() throws {
        let (_, preview) = try controlRequestParts(
            encoder.controlRequest(
                .rewindFiles(userMessageID: "user-message-uuid", dryRun: true),
                requestID: "rewind-preview"
            )
        )
        #expect(preview.string(forKey: "subtype") == "rewind_files")
        #expect(preview.string(forKey: "user_message_id") == "user-message-uuid")
        #expect(preview.bool(forKey: "dry_run") == true)

        let (_, restore) = try controlRequestParts(
            encoder.controlRequest(
                .rewindFiles(userMessageID: "user-message-uuid", dryRun: false),
                requestID: "rewind"
            )
        )
        #expect(restore.bool(forKey: "dry_run") == false)
    }

    @Test func stopTaskControlRequestEncodesTaskIdentifier() throws {
        let (_, request) = try controlRequestParts(
            encoder.controlRequest(.stopTask(taskID: "task-123"), requestID: "stop")
        )
        #expect(request.rawValue.count == 2)
        #expect(request.string(forKey: "subtype") == "stop_task")
        #expect(request.string(forKey: "task_id") == "task-123")
    }

    @Test func backgroundTasksControlRequestIncludesOrOmitsToolUseIdentifier() throws {
        let (_, oneTask) = try controlRequestParts(
            encoder.controlRequest(
                .backgroundTasks(toolUseID: "toolu_123"),
                requestID: "background-one"
            )
        )
        #expect(oneTask.string(forKey: "subtype") == "background_tasks")
        #expect(oneTask.string(forKey: "tool_use_id") == "toolu_123")

        let (_, allTasks) = try controlRequestParts(
            encoder.controlRequest(
                .backgroundTasks(toolUseID: nil),
                requestID: "background-all"
            )
        )
        #expect(allTasks.rawValue.count == 1)
        #expect(allTasks.string(forKey: "subtype") == "background_tasks")
        #expect(allTasks.rawValue["tool_use_id"] == nil)
    }

    @Test func contextUsageControlRequestHasNoExtraPayload() throws {
        let (_, request) = try controlRequestParts(
            encoder.getContextUsageControlRequest(requestID: "context")
        )
        #expect(request.rawValue.count == 1)
        #expect(request.string(forKey: "subtype") == "get_context_usage")
    }

    @Test func renameCancelAndFileSuggestionConveniencesEncodeTheirValues() throws {
        let (_, rename) = try controlRequestParts(
            encoder.renameSessionControlRequest(requestID: "rename", title: "Session title")
        )
        #expect(rename.string(forKey: "subtype") == "rename_session")
        #expect(rename.string(forKey: "title") == "Session title")

        let (_, cancel) = try controlRequestParts(
            encoder.cancelAsyncMessageControlRequest(requestID: "cancel", messageUUID: "message")
        )
        #expect(cancel.string(forKey: "subtype") == "cancel_async_message")
        #expect(cancel.string(forKey: "message_uuid") == "message")

        let (_, suggestions) = try controlRequestParts(
            encoder.fileSuggestionsControlRequest(requestID: "files", query: "Sources/Sup")
        )
        #expect(suggestions.string(forKey: "subtype") == "file_suggestions")
        #expect(suggestions.string(forKey: "query") == "Sources/Sup")
    }

    @Test func allowPermissionResponseEchoesInputAndSelectedSuggestions() throws {
        let input = try SupermuxHarnessJSONObject(rawValue: ["command": "pwd"])
        let suggestion = try SupermuxHarnessJSONObject(rawValue: [
            "type": "addRules",
            "destination": "session",
        ])
        let frame = try encoder.canUseToolAllowResponse(
            requestID: "permission",
            updatedInput: input,
            updatedPermissions: [suggestion]
        )
        let (envelope, response) = try controlResponseParts(frame)
        #expect(envelope.string(forKey: "subtype") == "success")
        #expect(envelope.string(forKey: "request_id") == "permission")
        #expect(response.string(forKey: "behavior") == "allow")
        #expect(response.object(forKey: "updatedInput") == input)
        #expect(response.objects(forKey: "updatedPermissions") == [suggestion])
    }

    @Test func allowPermissionResponseOmitsUnselectedPermissions() throws {
        let input = try SupermuxHarnessJSONObject(rawValue: ["command": "pwd"])
        let (_, response) = try controlResponseParts(
            encoder.canUseToolAllowResponse(requestID: "permission", updatedInput: input)
        )
        #expect(response.rawValue["updatedPermissions"] == nil)
    }

    @Test func denyPermissionResponseContainsRequiredFields() throws {
        let (_, response) = try controlResponseParts(
            encoder.canUseToolDenyResponse(
                requestID: "permission",
                message: "Not approved",
                interrupt: true
            )
        )
        #expect(response.string(forKey: "behavior") == "deny")
        #expect(response.string(forKey: "message") == "Not approved")
        #expect(response.bool(forKey: "interrupt") == true)
    }

    @Test func launchPlanAlwaysIncludesRequiredProtocolArgumentsAndPWD() {
        let executable = URL(fileURLWithPath: "/opt/claude")
        let directory = URL(fileURLWithPath: "/tmp/project/../project")
        let environment = ["PATH": "/custom/path", "HOME": "/home/test", "PWD": "/old"]
        let plan = SupermuxHarnessLaunchPlan(
            executableURL: executable,
            workingDirectoryURL: directory,
            environment: environment
        )

        #expect(plan.executableURL == executable.standardizedFileURL)
        #expect(plan.workingDirectoryURL == directory.standardizedFileURL)
        #expect(plan.arguments == [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--permission-prompt-tool", "stdio",
        ])
        #expect(plan.environment["PATH"] == "/custom/path")
        #expect(plan.environment["HOME"] == "/home/test")
        #expect(plan.environment["PWD"] == directory.standardizedFileURL.path)
        #expect(plan.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "1")
    }

    @Test func launchPlanAppendsAllOptionalArgumentsInStableOrder() {
        let plan = SupermuxHarnessLaunchPlan(
            executableURL: URL(fileURLWithPath: "/opt/claude"),
            workingDirectoryURL: URL(fileURLWithPath: "/workspace"),
            environment: [:],
            options: SupermuxHarnessLaunchOptions(
                model: "claude-haiku-4-5",
                permissionMode: .plan,
                resumeSessionID: "session",
                resumeSessionAt: "user-message-uuid",
                forkSession: true,
                effort: "high",
                replayUserMessages: true
            )
        )
        #expect(Array(plan.arguments.suffix(11)) == [
            "--model", "claude-haiku-4-5",
            "--permission-mode", "plan",
            "--resume", "session",
            "--resume-session-at=user-message-uuid",
            "--fork-session",
            "--effort", "high",
            "--replay-user-messages",
        ])
    }

    @Test func launchPlanOmitsEmptyOptionalStringsButHonorsBooleanFlags() {
        let plan = SupermuxHarnessLaunchPlan(
            executableURL: URL(fileURLWithPath: "/opt/claude"),
            workingDirectoryURL: URL(fileURLWithPath: "/workspace"),
            environment: [:],
            options: SupermuxHarnessLaunchOptions(
                model: "",
                resumeSessionID: "",
                forkSession: true,
                effort: "",
                replayUserMessages: true
            )
        )
        #expect(!plan.arguments.contains("--model"))
        #expect(!plan.arguments.contains("--resume"))
        #expect(!plan.arguments.contains("--effort"))
        #expect(plan.arguments.contains("--fork-session"))
        #expect(plan.arguments.contains("--replay-user-messages"))
    }

    @Test func launchPlanEmitsResumeSessionAtOnlyAlongsideResume() {
        let withoutResume = SupermuxHarnessLaunchPlan(
            executableURL: URL(fileURLWithPath: "/opt/claude"),
            workingDirectoryURL: URL(fileURLWithPath: "/workspace"),
            environment: [:],
            options: SupermuxHarnessLaunchOptions(resumeSessionAt: "user-message-uuid")
        )
        #expect(!withoutResume.arguments.contains("--resume-session-at=user-message-uuid"))

        let withResume = SupermuxHarnessLaunchPlan(
            executableURL: URL(fileURLWithPath: "/opt/claude"),
            workingDirectoryURL: URL(fileURLWithPath: "/workspace"),
            environment: [:],
            options: SupermuxHarnessLaunchOptions(
                resumeSessionID: "session",
                resumeSessionAt: "user-message-uuid"
            )
        )
        #expect(withResume.arguments.contains("--resume-session-at=user-message-uuid"))
    }

    private func controlRequestParts(
        _ frame: SupermuxHarnessEncodedFrame
    ) throws -> (SupermuxHarnessJSONObject, SupermuxHarnessJSONObject) {
        let object = try frame.jsonObject()
        return (object, try #require(object.object(forKey: "request")))
    }

    private func controlResponseParts(
        _ frame: SupermuxHarnessEncodedFrame
    ) throws -> (SupermuxHarnessJSONObject, SupermuxHarnessJSONObject) {
        let object = try frame.jsonObject()
        let envelope = try #require(object.object(forKey: "response"))
        return (envelope, try #require(envelope.object(forKey: "response")))
    }
}
