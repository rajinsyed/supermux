import Foundation

/// Encodes client-to-CLI Claude Code stream-json frames.
public struct SupermuxHarnessProtocolEncoder: Sendable {
    /// Creates a protocol encoder.
    public init() {}

    /// Encodes a user message with optional base64 image blocks.
    ///
    /// - Parameters:
    ///   - text: The user-authored text.
    ///   - images: Image attachments appended after the text block.
    ///   - uuid: The client-stamped UUID used for queue cancellation and receipts.
    ///   - sessionID: An optional explicit session identifier.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: ``SupermuxHarnessAttachmentPolicy/ValidationError`` or a JSON serialization error.
    public func userMessage(
        text: String,
        images: [SupermuxHarnessImage] = [],
        uuid: String,
        sessionID: String? = nil
    ) throws -> SupermuxHarnessEncodedFrame {
        try SupermuxHarnessAttachmentPolicy().validate(images)
        let content: Any
        if images.isEmpty {
            content = text
        } else {
            var blocks: [[String: Any]] = []
            if !text.isEmpty {
                blocks.append(["type": "text", "text": text])
            }
            blocks.append(contentsOf: images.map { image in
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": image.mediaType,
                        "data": image.dataBase64,
                    ],
                ]
            })
            content = blocks
        }
        var object: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "message": ["role": "user", "content": content],
        ]
        if let sessionID {
            object["session_id"] = sessionID
        }
        return try SupermuxHarnessEncodedFrame(object: object)
    }

    /// Encodes any supported client-issued control request.
    ///
    /// - Parameters:
    ///   - command: The control command and associated values.
    ///   - requestID: The unique identifier to match with a response.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func controlRequest(
        _ command: SupermuxHarnessControlCommand,
        requestID: String
    ) throws -> SupermuxHarnessEncodedFrame {
        try encodedControlRequest(requestID: requestID, request: requestObject(for: command))
    }

    /// Encodes an initialize request with stdio tool-permission capability enabled.
    ///
    /// - Parameter requestID: The unique request identifier.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func initializeControlRequest(requestID: String) throws -> SupermuxHarnessEncodedFrame {
        try controlRequest(.initialize, requestID: requestID)
    }

    /// Encodes an interrupt request.
    ///
    /// - Parameters:
    ///   - requestID: The unique request identifier.
    ///   - cancelQueued: Whether queued messages should also be cancelled; `nil` omits the field.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func interruptControlRequest(
        requestID: String,
        cancelQueued: Bool? = nil
    ) throws -> SupermuxHarnessEncodedFrame {
        try controlRequest(.interrupt(cancelQueued: cancelQueued), requestID: requestID)
    }

    /// Encodes a permission-mode change.
    ///
    /// - Parameters:
    ///   - requestID: The unique request identifier.
    ///   - mode: The new permission mode.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func setPermissionModeControlRequest(
        requestID: String,
        mode: SupermuxHarnessPermissionMode
    ) throws -> SupermuxHarnessEncodedFrame {
        try controlRequest(.setPermissionMode(mode), requestID: requestID)
    }

    /// Encodes a model and effort change.
    ///
    /// A `nil` model is encoded as JSON `null`, which resets Claude Code to its default model.
    ///
    /// - Parameters:
    ///   - requestID: The unique request identifier.
    ///   - model: The model selector or `nil` to reset.
    ///   - effort: Optional account-supported effort level.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func setModelControlRequest(
        requestID: String,
        model: String?,
        effort: String? = nil
    ) throws -> SupermuxHarnessEncodedFrame {
        try controlRequest(.setModel(model: model, effort: effort), requestID: requestID)
    }

    /// Encodes a maximum-thinking-token change.
    ///
    /// - Parameters:
    ///   - requestID: The unique request identifier.
    ///   - maximumTokens: The limit or `nil` to reset it.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func setMaxThinkingTokensControlRequest(
        requestID: String,
        maximumTokens: Int?
    ) throws -> SupermuxHarnessEncodedFrame {
        try controlRequest(.setMaxThinkingTokens(maximumTokens), requestID: requestID)
    }

    /// Encodes an authoritative context-usage request.
    ///
    /// - Parameter requestID: The unique request identifier.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func getContextUsageControlRequest(requestID: String) throws -> SupermuxHarnessEncodedFrame {
        try controlRequest(.getContextUsage, requestID: requestID)
    }

    /// Encodes a session rename request.
    ///
    /// - Parameters:
    ///   - requestID: The unique request identifier.
    ///   - title: The new persisted title.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func renameSessionControlRequest(
        requestID: String,
        title: String
    ) throws -> SupermuxHarnessEncodedFrame {
        try controlRequest(.renameSession(title: title), requestID: requestID)
    }

    /// Encodes cancellation of a queued user message.
    ///
    /// - Parameters:
    ///   - requestID: The unique request identifier.
    ///   - messageUUID: The client-stamped user-message UUID.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func cancelAsyncMessageControlRequest(
        requestID: String,
        messageUUID: String
    ) throws -> SupermuxHarnessEncodedFrame {
        try controlRequest(.cancelAsyncMessage(messageUUID: messageUUID), requestID: requestID)
    }

    /// Encodes a CLI-side file-suggestion query.
    ///
    /// - Parameters:
    ///   - requestID: The unique request identifier.
    ///   - query: The partial path query.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func fileSuggestionsControlRequest(
        requestID: String,
        query: String
    ) throws -> SupermuxHarnessEncodedFrame {
        try controlRequest(.fileSuggestions(query: query), requestID: requestID)
    }

    /// Encodes a file-checkpoint rewind request.
    ///
    /// - Parameters:
    ///   - requestID: The unique request identifier.
    ///   - userMessageID: The client-stamped UUID of the user message whose checkpoint should be used.
    ///   - dryRun: Whether to preview changed files without restoring them.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func rewindFilesControlRequest(
        requestID: String,
        userMessageID: String,
        dryRun: Bool
    ) throws -> SupermuxHarnessEncodedFrame {
        try controlRequest(
            .rewindFiles(userMessageID: userMessageID, dryRun: dryRun),
            requestID: requestID
        )
    }

    /// Encodes an allow response to a pending `can_use_tool` request.
    ///
    /// - Parameters:
    ///   - requestID: The CLI-issued request identifier.
    ///   - updatedInput: The echoed or user-edited tool input.
    ///   - updatedPermissions: Optional permission suggestion objects selected by the user.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func canUseToolAllowResponse(
        requestID: String,
        updatedInput: SupermuxHarnessJSONObject,
        updatedPermissions: [SupermuxHarnessJSONObject]? = nil
    ) throws -> SupermuxHarnessEncodedFrame {
        var response: [String: Any] = [
            "behavior": "allow",
            "updatedInput": updatedInput.rawValue,
        ]
        if let updatedPermissions {
            response["updatedPermissions"] = updatedPermissions.map(\.rawValue)
        }
        return try encodedControlResponse(requestID: requestID, response: response)
    }

    /// Encodes a deny response to a pending `can_use_tool` request.
    ///
    /// - Parameters:
    ///   - requestID: The CLI-issued request identifier.
    ///   - message: The required denial reason delivered back to Claude.
    ///   - interrupt: Whether denying should also stop the active turn.
    /// - Returns: A newline-terminated encoded frame.
    /// - Throws: A JSON serialization error.
    public func canUseToolDenyResponse(
        requestID: String,
        message: String,
        interrupt: Bool
    ) throws -> SupermuxHarnessEncodedFrame {
        try encodedControlResponse(
            requestID: requestID,
            response: [
                "behavior": "deny",
                "message": message,
                "interrupt": interrupt,
            ]
        )
    }

    private func requestObject(for command: SupermuxHarnessControlCommand) -> [String: Any] {
        var request: [String: Any] = ["subtype": command.subtype]
        switch command {
        case .initialize:
            request["capabilities"] = ["canUseTool": true]
            // Without this the CLI forwards only tool_use/tool_result frames for
            // subagents; with it the full conversation (text + thinking) arrives
            // with parent_tool_use_id set, which the agent chat views render.
            request["forwardSubagentText"] = true
        case .interrupt(let cancelQueued):
            if let cancelQueued {
                request["cancel_queued"] = cancelQueued
            }
        case .setPermissionMode(let mode):
            request["mode"] = mode.rawValue
        case .setModel(let model, let effort):
            request["model"] = model ?? NSNull()
            if let effort {
                request["effort"] = effort
            }
        case .setMaxThinkingTokens(let maximumTokens):
            request["max_thinking_tokens"] = maximumTokens ?? NSNull()
        case .getContextUsage:
            break
        case .renameSession(let title):
            request["title"] = title
        case .cancelAsyncMessage(let messageUUID):
            request["message_uuid"] = messageUUID
        case .fileSuggestions(let query):
            request["query"] = query
        case .rewindFiles(let userMessageID, let dryRun):
            request["user_message_id"] = userMessageID
            request["dry_run"] = dryRun
        case .stopTask(let taskID):
            request["task_id"] = taskID
        case .backgroundTasks(let toolUseID):
            if let toolUseID {
                request["tool_use_id"] = toolUseID
            }
        }
        return request
    }

    private func encodedControlRequest(
        requestID: String,
        request: [String: Any]
    ) throws -> SupermuxHarnessEncodedFrame {
        try SupermuxHarnessEncodedFrame(object: [
            "type": "control_request",
            "request_id": requestID,
            "request": request,
        ])
    }

    private func encodedControlResponse(
        requestID: String,
        response: [String: Any]
    ) throws -> SupermuxHarnessEncodedFrame {
        try SupermuxHarnessEncodedFrame(object: [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestID,
                "response": response,
            ],
        ])
    }
}
