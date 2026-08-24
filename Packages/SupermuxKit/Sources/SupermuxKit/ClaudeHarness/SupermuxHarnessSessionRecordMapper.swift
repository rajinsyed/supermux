import Foundation

/// Maps persisted Claude session records into the live protocol wrapper shape.
struct SupermuxHarnessSessionRecordMapper: Sendable {
    /// Returns a replayable user or assistant event, or `nil` for non-conversation records.
    func protocolEvent(
        from record: [String: Any],
        fallbackSessionID: String
    ) -> SupermuxHarnessJSONObject? {
        if let queued = queuedCommandEvent(from: record, fallbackSessionID: fallbackSessionID) {
            return queued
        }
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
            "isMeta",
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

    /// A message the user queued mid-turn, persisted as a `queued_command` attachment.
    ///
    /// The CLI consumes a queued message at the running turn's next step rather than opening a new
    /// turn for it, so the transcript has no `user` record for it at all — the attachment is the
    /// only trace. It replays as a `mid_turn` user line, which the web reducer files INSIDE the
    /// turn it interjected into. Only `commandMode == "prompt"` qualifies: the CLI also refeeds
    /// task notifications through the same attachment shape, and those are machine-authored.
    private func queuedCommandEvent(
        from record: [String: Any],
        fallbackSessionID: String
    ) -> SupermuxHarnessJSONObject? {
        guard record["type"] as? String == "attachment",
              let attachment = record["attachment"] as? [String: Any],
              attachment["type"] as? String == "queued_command",
              attachment["commandMode"] as? String == "prompt" else {
            return nil
        }
        let prompt = attachment["prompt"]
        let content: Any
        if let text = prompt as? String, !text.isEmpty {
            content = text
        } else if let blocks = prompt as? [[String: Any]], !blocks.isEmpty {
            content = blocks
        } else {
            return nil
        }
        var event: [String: Any] = [
            "type": "user",
            "mid_turn": true,
            "message": ["role": "user", "content": content],
            "session_id": record["sessionId"] ?? fallbackSessionID,
        ]
        // source_uuid is the uuid the client stamped on the queued send; the record's own uuid is
        // the fallback so replays stay idempotent either way.
        if let uuid = (attachment["source_uuid"] as? String) ?? (record["uuid"] as? String) {
            event["uuid"] = uuid
        }
        if let timestamp = attachment["timestamp"] ?? record["timestamp"] {
            event["timestamp"] = timestamp
        }
        return try? SupermuxHarnessJSONObject(rawValue: event)
    }
}
