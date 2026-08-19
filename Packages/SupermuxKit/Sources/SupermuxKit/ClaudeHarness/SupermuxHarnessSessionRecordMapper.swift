import Foundation

/// Maps persisted Claude session records into the live protocol wrapper shape.
struct SupermuxHarnessSessionRecordMapper: Sendable {
    /// Returns a replayable user or assistant event, or `nil` for non-conversation records.
    func protocolEvent(
        from record: [String: Any],
        fallbackSessionID: String
    ) -> SupermuxHarnessJSONObject? {
        guard let type = record["type"] as? String,
              type == "user" || type == "assistant",
              let message = record["message"] as? [String: Any] else {
            return nil
        }
        var event: [String: Any] = [
            "type": type,
            "message": message,
            "parent_tool_use_id": record["parent_tool_use_id"] ?? NSNull(),
            "session_id": record["session_id"] ?? record["sessionId"] ?? fallbackSessionID,
        ]
        for key in [
            "uuid",
            "timestamp",
            "subagent_type",
            "task_description",
            // The CLI stamps the reasoning effort on every persisted assistant
            // record; it is the one account a resumed session has of the level
            // it was running (history has no init frame), and the web reducer
            // adopts it on historyReplayed.
            "effort",
            "error",
            "aborted",
            "supersedes",
            "isReplay",
        ] {
            if let value = record[key] {
                event[key] = value
            }
        }
        if type == "user", let toolResult = record["toolUseResult"] {
            event["tool_use_result"] = toolResult
        }
        return try? SupermuxHarnessJSONObject(rawValue: event)
    }
}
