public import Foundation

/// Lists and replays Claude Code sessions stored beneath `~/.claude/projects`.
public struct SupermuxHarnessSessionDiscovery {
    private struct SessionMetadata {
        var customTitle: String?
        var aiTitle: String?
        var summary: String?
        var firstPrompt: String?
        var gitBranch: String?
        var messageCount = 0
    }

    private let projectsRootURL: URL
    private let fileManager: FileManager

    /// Creates a persisted-session discovery service.
    ///
    /// - Parameters:
    ///   - projectsRootURL: The Claude projects directory, normally `~/.claude/projects`.
    ///   - fileManager: The filesystem implementation to use.
    public init(projectsRootURL: URL, fileManager: FileManager) {
        self.projectsRootURL = projectsRootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    /// Returns resolved-first project directory names for a working directory.
    ///
    /// Every non-alphanumeric Unicode scalar in the absolute path becomes `-`. The symlink-resolved
    /// form is first, followed by the unresolved form when they differ.
    ///
    /// - Parameter workingDirectoryURL: The absolute working directory.
    /// - Returns: One or two Claude project directory names.
    public func mungedProjectDirectoryNames(for workingDirectoryURL: URL) -> [String] {
        let unresolved = workingDirectoryURL.standardizedFileURL
        let resolved = unresolved.resolvingSymlinksInPath().standardizedFileURL
        var names: [String] = []
        for path in [resolved.path, unresolved.path] {
            let name = mungedPath(path)
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// Returns resolved-first Claude project directories for a working directory.
    ///
    /// - Parameter workingDirectoryURL: The absolute working directory.
    /// - Returns: Candidate directories beneath the configured projects root.
    public func projectDirectoryURLs(for workingDirectoryURL: URL) -> [URL] {
        mungedProjectDirectoryNames(for: workingDirectoryURL).map {
            projectsRootURL.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Lists persisted sessions for one working directory, newest first.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The working directory whose project folders should be probed.
    ///   - limit: Optional maximum result count. Values at or below zero return an empty list.
    /// - Returns: Deduplicated session metadata sorted by modification date.
    /// - Throws: Filesystem or file-reading errors for discovered session files.
    public func listSessions(
        for workingDirectoryURL: URL,
        limit: Int? = nil
    ) throws -> [SupermuxHarnessDiscoveredSession] {
        if let limit, limit <= 0 { return [] }
        var sessionsByID: [String: SupermuxHarnessDiscoveredSession] = [:]
        for directory in projectDirectoryURLs(for: workingDirectoryURL) {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for file in files where file.pathExtension.lowercased() == "jsonl" {
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile != false else { continue }
                let sessionID = file.deletingPathExtension().lastPathComponent
                let updatedAt = values.contentModificationDate ?? .distantPast
                if let existing = sessionsByID[sessionID], existing.updatedAt >= updatedAt {
                    continue
                }
                let records = try readRecords(from: file)
                let metadata = metadata(from: records)
                let title = metadata.customTitle
                    ?? metadata.aiTitle
                    ?? metadata.summary
                    ?? metadata.firstPrompt
                    ?? sessionID
                sessionsByID[sessionID] = SupermuxHarnessDiscoveredSession(
                    sessionID: sessionID,
                    title: title,
                    firstPrompt: metadata.firstPrompt,
                    updatedAt: updatedAt,
                    gitBranch: metadata.gitBranch,
                    messageCount: metadata.messageCount
                )
            }
        }

        let sorted = sessionsByID.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.sessionID < $1.sessionID
        }
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }

    /// Loads one session by walking its UUID parent chain and mapping records to live wire shapes.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The working directory whose project folders should be probed.
    ///   - sessionID: The persisted session filename without `.jsonl`.
    ///   - recordLimit: Optional maximum number of newest visible records to return.
    /// - Returns: Root-to-leaf protocol-shaped events and a truncation flag.
    /// - Throws: ``SupermuxHarnessSessionDiscoveryError`` or a file-reading error.
    public func loadHistory(
        for workingDirectoryURL: URL,
        sessionID: String,
        recordLimit: Int? = nil
    ) throws -> SupermuxHarnessHistoryPage {
        guard isValidSessionID(sessionID) else {
            throw SupermuxHarnessSessionDiscoveryError.invalidSessionID
        }
        guard let file = sessionFile(
            for: workingDirectoryURL,
            sessionID: sessionID
        ) else {
            throw SupermuxHarnessSessionDiscoveryError.sessionNotFound(sessionID)
        }
        let records = try readRecords(from: file)
        var recordsByUUID: [String: [String: Any]] = [:]
        var summaryLeaf: String?
        var lastPromptLeaf: String?
        var lastMainUUID: String?
        for record in records {
            let type = record["type"] as? String
            if type == "summary", let leaf = nonemptyString(record["leafUuid"]) {
                summaryLeaf = leaf
            }
            if type == "last-prompt", let leaf = nonemptyString(record["leafUuid"]) {
                lastPromptLeaf = leaf
            }
            guard let uuid = nonemptyString(record["uuid"]), type == "user" || type == "assistant" else {
                continue
            }
            recordsByUUID[uuid] = record
            if record["isSidechain"] as? Bool != true {
                lastMainUUID = uuid
            }
        }

        var chain: [[String: Any]] = []
        var cursor = [lastPromptLeaf, summaryLeaf, lastMainUUID]
            .compactMap { $0 }
            .first { recordsByUUID[$0] != nil }
        var visited: Set<String> = []
        while let uuid = cursor, visited.insert(uuid).inserted, let record = recordsByUUID[uuid] {
            chain.append(record)
            cursor = nonemptyString(record["parentUuid"])
        }
        chain.reverse()

        var events = chain.compactMap { record -> SupermuxHarnessJSONObject? in
            guard record["isMeta"] as? Bool != true,
                  record["isSidechain"] as? Bool != true else {
                return nil
            }
            return protocolEvent(from: record, sessionID: sessionID)
        }
        let truncated: Bool
        if let recordLimit {
            let boundedLimit = max(0, recordLimit)
            truncated = events.count > boundedLimit
            if truncated {
                events = Array(events.suffix(boundedLimit))
            }
        } else {
            truncated = false
        }
        return SupermuxHarnessHistoryPage(events: events, truncated: truncated)
    }

    private func mungedPath(_ path: String) -> String {
        var result = ""
        for scalar in path.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("-")
            }
        }
        return result
    }

    private func sessionFile(for workingDirectoryURL: URL, sessionID: String) -> URL? {
        for directory in projectDirectoryURLs(for: workingDirectoryURL) {
            let candidate = directory.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private func isValidSessionID(_ sessionID: String) -> Bool {
        guard !sessionID.isEmpty,
              sessionID == URL(fileURLWithPath: sessionID).lastPathComponent else {
            return false
        }
        return sessionID.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private func readRecords(from file: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: file)
        return data.split(separator: 0x0A).compactMap { line in
            guard !line.isEmpty,
                  let value = try? JSONSerialization.jsonObject(with: Data(line)),
                  let object = value as? [String: Any] else {
                return nil
            }
            return object
        }
    }

    private func metadata(from records: [[String: Any]]) -> SessionMetadata {
        var metadata = SessionMetadata()
        for record in records {
            let type = record["type"] as? String
            if let value = nonemptyString(record["customTitle"]) {
                metadata.customTitle = value
            }
            if type == "custom-title", let value = nonemptyString(record["customTitle"]) {
                metadata.customTitle = value
            }
            if type == "ai-title", let value = nonemptyString(record["aiTitle"]) {
                metadata.aiTitle = value
            }
            if type == "summary", let value = nonemptyString(record["summary"]) {
                metadata.summary = value
            }
            guard type == "user" || type == "assistant",
                  record["isMeta"] as? Bool != true,
                  record["isSidechain"] as? Bool != true else {
                continue
            }
            metadata.messageCount += 1
            if let branch = nonemptyString(record["gitBranch"]) {
                metadata.gitBranch = branch
            }
            if type == "user", metadata.firstPrompt == nil,
               let message = record["message"] as? [String: Any],
               let prompt = messageText(message) {
                metadata.firstPrompt = prompt
            }
        }
        return metadata
    }

    private func messageText(_ message: [String: Any]) -> String? {
        if let text = nonemptyString(message["content"]) {
            return text
        }
        guard let blocks = message["content"] as? [Any] else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard let object = block as? [String: Any], object["type"] as? String == "text" else {
                return nil
            }
            return nonemptyString(object["text"])
        }.joined(separator: "\n")
        return nonemptyString(text)
    }

    private func protocolEvent(
        from record: [String: Any],
        sessionID: String
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
            "session_id": record["session_id"] ?? record["sessionId"] ?? sessionID,
        ]
        for key in ["uuid", "timestamp", "subagent_type", "task_description", "error", "aborted", "supersedes", "isReplay"] {
            if let value = record[key] {
                event[key] = value
            }
        }
        if type == "user", let toolResult = record["toolUseResult"] {
            event["tool_use_result"] = toolResult
        }
        return try? SupermuxHarnessJSONObject(rawValue: event)
    }

    private func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
