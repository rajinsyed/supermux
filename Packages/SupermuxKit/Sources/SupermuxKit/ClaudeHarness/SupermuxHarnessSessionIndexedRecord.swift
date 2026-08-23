import Foundation

/// Parsed contribution from one valid JSONL object.
struct SupermuxHarnessSessionIndexedRecord: Sendable {
    var metadata = SupermuxHarnessSessionMetadataIndex()
    var uuid: String?
    var link: SupermuxHarnessSessionRecordLink?
    var eventRange: SupermuxHarnessSessionRecordRange?
    var summaryLeaf: String?
    var lastPromptLeaf: String?
    var lastMainUUID: String?

    init?(data: Data, range: SupermuxHarnessSessionRecordRange, includesHistory: Bool) {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let record = value as? [String: Any] else {
            return nil
        }
        let type = record["type"] as? String
        if let value = Self.nonemptyString(record["customTitle"]) {
            metadata.customTitle = value
        }
        if type == "custom-title",
           let value = Self.nonemptyString(record["customTitle"]) {
            metadata.customTitle = value
        }
        if type == "ai-title",
           let value = Self.nonemptyString(record["aiTitle"]) {
            metadata.aiTitle = value
        }
        if type == "summary" {
            metadata.summary = Self.nonemptyString(record["summary"])
            if includesHistory {
                summaryLeaf = Self.nonemptyString(record["leafUuid"])
            }
        }
        if includesHistory, type == "last-prompt" {
            lastPromptLeaf = Self.nonemptyString(record["leafUuid"])
        }
        if let path = Self.nonemptyString(record["cwd"]) {
            metadata.foundRecordedDirectory = true
            metadata.recordedCanonicalPaths = SupermuxHarnessSessionPathPolicy
                .canonicalPaths(forRecordedPath: path)
        }

        let isConversation = type == "user" || type == "assistant"
        let isSidechain = record["isSidechain"] as? Bool == true
        if isConversation,
           record["isMeta"] as? Bool != true,
           !isSidechain {
            metadata.messageCount = 1
            metadata.gitBranch = Self.nonemptyString(record["gitBranch"])
            if type == "user",
               let message = record["message"] as? [String: Any] {
                metadata.firstPrompt = Self.messageText(message)
            }
        }

        guard includesHistory else { return }
        if isConversation, !isSidechain {
            lastMainUUID = Self.nonemptyString(record["uuid"])
        }
        guard let uuid = Self.nonemptyString(record["uuid"]) else { return }
        self.uuid = uuid
        let attachment = record["attachment"] as? [String: Any]
        let isQueuedPrompt = type == "attachment" &&
            attachment?["type"] as? String == "queued_command" &&
            attachment?["commandMode"] as? String == "prompt"
        let hasConversationMessage = isConversation && record["message"] is [String: Any]
        let queuedPrompt = attachment?["prompt"]
        let hasQueuedPromptContent = (queuedPrompt as? String)?.isEmpty == false ||
            (queuedPrompt as? [[String: Any]])?.isEmpty == false
        if hasConversationMessage || (isQueuedPrompt && hasQueuedPromptContent) {
            eventRange = range
        }
        link = SupermuxHarnessSessionRecordLink(
            parentUUID: Self.nonemptyString(record["parentUuid"]),
            isVisible: (hasConversationMessage &&
                record["isMeta"] as? Bool != true &&
                !isSidechain) ||
                (isQueuedPrompt && hasQueuedPromptContent && !isSidechain)
        )
    }

    private static func messageText(_ message: [String: Any]) -> String? {
        if let text = nonemptyString(message["content"]) {
            return text
        }
        guard let blocks = message["content"] as? [Any] else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard let object = block as? [String: Any],
                  object["type"] as? String == "text" else {
                return nil
            }
            return nonemptyString(object["text"])
        }.joined(separator: "\n")
        return nonemptyString(text)
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
