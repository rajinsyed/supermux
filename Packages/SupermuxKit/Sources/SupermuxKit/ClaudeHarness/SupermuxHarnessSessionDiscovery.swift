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

    private struct SessionSummary {
        let metadata: SessionMetadata
        let belongsToWorkingDirectory: Bool
    }

    private struct SessionRecordLink {
        let parentUUID: String?
        let isVisible: Bool
    }

    private struct SessionHistoryIndex {
        let fileURL: URL
        let linksByUUID: [String: SessionRecordLink]
        let preferredLeafUUIDs: [String]
    }

    private let projectsRootURL: URL
    private let fileManager: FileManager
    private let recordMapper = SupermuxHarnessSessionRecordMapper()

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
        let resolved = claudeResolvedDirectoryURL(unresolved)
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
    /// Malformed and overlong JSONL records are skipped without buffering the full file.
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
        for candidateDirectory in projectDirectoryURLs(for: workingDirectoryURL) {
            guard let directory = safeProjectDirectory(candidateDirectory) else { continue }
            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            )
            for file in files where file.pathExtension.lowercased() == "jsonl" {
                let sessionID = file.deletingPathExtension().lastPathComponent
                guard isValidSessionID(sessionID), safeSessionFile(file, in: directory) else {
                    continue
                }
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
                let updatedAt = values.contentModificationDate ?? .distantPast
                if let existing = sessionsByID[sessionID], existing.updatedAt >= updatedAt {
                    continue
                }
                let summary = try sessionSummary(
                    from: file,
                    workingDirectoryURL: workingDirectoryURL
                )
                guard summary.belongsToWorkingDirectory else { continue }
                let metadata = summary.metadata
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
    /// The file is scanned in bounded chunks; malformed and overlong records are omitted.
    /// Record and byte limits are applied in that order and retain one newest contiguous suffix.
    /// The byte budget is the sum of each retained event's compact JSON representation; it excludes
    /// the caller's response envelope. Either limit sets `truncated`, including when no event fits.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The working directory whose project folders should be probed.
    ///   - sessionID: The persisted session filename without `.jsonl`.
    ///   - recordLimit: Optional maximum number of newest visible records to return.
    ///   - maximumEventBytes: Optional serialized-byte budget for returned protocol events.
    /// - Returns: Root-to-leaf protocol-shaped events and a truncation flag.
    /// - Throws: ``SupermuxHarnessSessionDiscoveryError`` or a file-reading error.
    public func loadHistory(
        for workingDirectoryURL: URL,
        sessionID: String,
        recordLimit: Int? = nil,
        maximumEventBytes: Int? = nil
    ) throws -> SupermuxHarnessHistoryPage {
        guard isValidSessionID(sessionID) else {
            throw SupermuxHarnessSessionDiscoveryError.invalidSessionID
        }
        guard let index = try sessionHistoryIndex(
            for: workingDirectoryURL,
            sessionID: sessionID
        ) else {
            throw SupermuxHarnessSessionDiscoveryError.sessionNotFound(sessionID)
        }
        var chainUUIDs: [String] = []
        var cursor = index.preferredLeafUUIDs.first { index.linksByUUID[$0] != nil }
        var visited: Set<String> = []
        while let uuid = cursor,
              visited.insert(uuid).inserted,
              let link = index.linksByUUID[uuid] {
            if link.isVisible {
                chainUUIDs.append(uuid)
            }
            cursor = link.parentUUID
        }
        chainUUIDs.reverse()

        var truncated: Bool
        if let recordLimit {
            let boundedLimit = max(0, recordLimit)
            truncated = chainUUIDs.count > boundedLimit
            if truncated {
                chainUUIDs = Array(chainUUIDs.suffix(boundedLimit))
            }
        } else {
            truncated = false
        }
        let selectedUUIDs = Set(chainUUIDs)
        var eventsByUUID: [String: SupermuxHarnessJSONObject] = [:]
        try forEachRecord(in: index.fileURL) { record in
            guard let uuid = nonemptyString(record["uuid"]), selectedUUIDs.contains(uuid),
                  let event = recordMapper.protocolEvent(
                      from: record,
                      fallbackSessionID: sessionID
                  ) else {
                return
            }
            eventsByUUID[uuid] = event
        }
        return try SupermuxHarnessHistoryPage(
            events: chainUUIDs.compactMap { eventsByUUID[$0] },
            truncated: truncated
        ).limitingSerializedEventBytes(maximumEventBytes)
    }

    /// Returns the on-disk file for one persisted session, or nil when no
    /// candidate project directory holds it.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The working directory whose project folders should be probed.
    ///   - sessionID: The persisted session filename without `.jsonl`.
    /// - Returns: The session file URL, or nil when missing or unsafe.
    public func sessionFileURL(
        for workingDirectoryURL: URL,
        sessionID: String
    ) -> URL? {
        guard isValidSessionID(sessionID) else { return nil }
        for candidateDirectory in projectDirectoryURLs(for: workingDirectoryURL) {
            guard let directory = safeProjectDirectory(candidateDirectory) else { continue }
            let file = directory.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
            guard safeSessionFile(file, in: directory),
                  let summary = try? sessionSummary(
                    from: file,
                    workingDirectoryURL: workingDirectoryURL
                  ),
                  summary.belongsToWorkingDirectory else {
                continue
            }
            return file
        }
        return nil
    }

    /// Returns the current display title for one persisted session, or nil when
    /// the session has no title-bearing records yet.
    ///
    /// Precedence matches ``listSessions(for:limit:)``: custom title, then the
    /// CLI's auto-generated topic title, then summary, then the first prompt.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The working directory whose project folders should be probed.
    ///   - sessionID: The persisted session filename without `.jsonl`.
    /// - Returns: The resolved title, or nil when the file is missing or untitled.
    public func sessionTitle(
        for workingDirectoryURL: URL,
        sessionID: String
    ) -> String? {
        guard isValidSessionID(sessionID) else { return nil }
        for candidateDirectory in projectDirectoryURLs(for: workingDirectoryURL) {
            guard let directory = safeProjectDirectory(candidateDirectory) else { continue }
            let file = directory.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
            guard safeSessionFile(file, in: directory),
                  let summary = try? sessionSummary(
                    from: file,
                    workingDirectoryURL: workingDirectoryURL
                  ),
                  summary.belongsToWorkingDirectory else {
                continue
            }
            return summary.metadata.customTitle
                ?? summary.metadata.aiTitle
                ?? summary.metadata.summary
                ?? summary.metadata.firstPrompt
        }
        return nil
    }

    /// Claude records `/tmp` beneath its physical macOS path even on Foundation
    /// versions where `resolvingSymlinksInPath()` leaves the `/tmp` alias intact.
    private func claudeResolvedDirectoryURL(_ directory: URL) -> URL {
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        guard path == "/tmp" || path.hasPrefix("/tmp/") else { return resolved }
        // Do not call `standardizedFileURL` on the explicit physical path:
        // macOS 14 Foundation aliases `/private/tmp` back to `/tmp` there.
        return URL(fileURLWithPath: "/private\(path)", isDirectory: true)
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

    private func sessionHistoryIndex(
        for workingDirectoryURL: URL,
        sessionID: String
    ) throws -> SessionHistoryIndex? {
        let expectedPaths = canonicalPaths(for: workingDirectoryURL)
        for candidateDirectory in projectDirectoryURLs(for: workingDirectoryURL) {
            guard let directory = safeProjectDirectory(candidateDirectory) else { continue }
            let file = directory.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
            guard safeSessionFile(file, in: directory) else { continue }
            var linksByUUID: [String: SessionRecordLink] = [:]
            var summaryLeaf: String?
            var lastPromptLeaf: String?
            var lastMainUUID: String?
            var foundRecordedDirectory = false
            var foundMatchingDirectory = false
            try forEachRecord(in: file) { record in
                let type = record["type"] as? String
                if type == "summary", let leaf = nonemptyString(record["leafUuid"]) {
                    summaryLeaf = leaf
                }
                if type == "last-prompt", let leaf = nonemptyString(record["leafUuid"]) {
                    lastPromptLeaf = leaf
                }
                if let path = nonemptyString(record["cwd"]) {
                    foundRecordedDirectory = true
                    foundMatchingDirectory = foundMatchingDirectory ||
                        recordedDirectory(path, matches: expectedPaths)
                }
                // Every uuid-bearing record joins the index: real parentUuid chains
                // route through attachment/system/file-history records, and dropping
                // those from the index used to sever the walk a step or two in.
                guard let uuid = nonemptyString(record["uuid"]) else {
                    return
                }
                let isConversation = type == "user" || type == "assistant"
                let isSidechain = record["isSidechain"] as? Bool == true
                // A message the user queued mid-turn persists ONLY as a
                // `queued_command` attachment (the CLI consumes it inside the
                // running turn and writes no `user` record); it joins the
                // replay chain so the record mapper can resurface it. Other
                // commandModes refeed machine-authored payloads and stay out.
                let attachment = record["attachment"] as? [String: Any]
                let isQueuedPrompt = type == "attachment" &&
                    attachment?["type"] as? String == "queued_command" &&
                    attachment?["commandMode"] as? String == "prompt"
                let queuedPrompt = attachment?["prompt"]
                let hasQueuedPromptContent = nonemptyString(queuedPrompt) != nil ||
                    (queuedPrompt as? [[String: Any]])?.isEmpty == false
                let isVisible = (isConversation &&
                    record["isMeta"] as? Bool != true &&
                    !isSidechain &&
                    record["message"] is [String: Any]) ||
                    (isQueuedPrompt && hasQueuedPromptContent && !isSidechain)
                if linksByUUID[uuid] == nil || isVisible {
                    linksByUUID[uuid] = SessionRecordLink(
                        parentUUID: nonemptyString(record["parentUuid"]),
                        isVisible: isVisible
                    )
                }
                if isConversation, !isSidechain {
                    lastMainUUID = uuid
                }
            }
            guard !foundRecordedDirectory || foundMatchingDirectory else { continue }
            // The leaf pointers exist to pick a BRANCH, not to cut the tail: a
            // `last-prompt` written before a CLI restart can point mid-chain, and
            // preferring it would silently drop every record after the restart.
            // A leaf that is an ancestor of the newest main-chain record selects
            // the same branch that record already terminates, so it loses to it.
            let preferred = [lastPromptLeaf, summaryLeaf].compactMap { $0 }.filter { leaf in
                !isAncestor(leaf, ofDescendant: lastMainUUID, in: linksByUUID)
            }
            return SessionHistoryIndex(
                fileURL: file,
                linksByUUID: linksByUUID,
                preferredLeafUUIDs: preferred + [lastMainUUID].compactMap { $0 }
            )
        }
        return nil
    }

    /// Whether `leaf` sits strictly above `descendant` on its parent chain.
    private func isAncestor(
        _ leaf: String,
        ofDescendant descendant: String?,
        in linksByUUID: [String: SessionRecordLink]
    ) -> Bool {
        guard let descendant, descendant != leaf else { return false }
        var cursor = linksByUUID[descendant]?.parentUUID
        var visited: Set<String> = [descendant]
        while let uuid = cursor, visited.insert(uuid).inserted {
            if uuid == leaf { return true }
            cursor = linksByUUID[uuid]?.parentUUID
        }
        return false
    }

    private func safeProjectDirectory(_ directory: URL) -> URL? {
        guard let values = try? directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]),
        values.isDirectory == true,
        values.isSymbolicLink != true else {
            return nil
        }
        let resolvedRoot = projectsRootURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(resolvedDirectory, of: resolvedRoot) else { return nil }
        return directory
    }

    private func safeSessionFile(_ file: URL, in directory: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true else {
            return false
        }
        return isDescendant(
            file.resolvingSymlinksInPath().standardizedFileURL,
            of: directory.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let directoryComponents = directory.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > directoryComponents.count else { return false }
        return candidateComponents.prefix(directoryComponents.count).elementsEqual(directoryComponents)
    }

    private func sessionSummary(
        from file: URL,
        workingDirectoryURL: URL
    ) throws -> SessionSummary {
        let expectedPaths = canonicalPaths(for: workingDirectoryURL)
        var metadata = SessionMetadata()
        var foundRecordedDirectory = false
        var foundMatchingDirectory = false
        try forEachRecord(in: file) { record in
            updateMetadata(&metadata, with: record)
            if let path = nonemptyString(record["cwd"]) {
                foundRecordedDirectory = true
                foundMatchingDirectory = foundMatchingDirectory ||
                    recordedDirectory(path, matches: expectedPaths)
            }
        }
        return SessionSummary(
            metadata: metadata,
            belongsToWorkingDirectory: !foundRecordedDirectory || foundMatchingDirectory
        )
    }

    /// Checks a persisted absolute cwd against the same canonical aliases used by discovery.
    func recordedDirectory(_ path: String, matches workingDirectoryURL: URL) -> Bool {
        recordedDirectory(path, matches: canonicalPaths(for: workingDirectoryURL))
    }

    private func recordedDirectory(_ path: String, matches expectedPaths: Set<String>) -> Bool {
        guard (path as NSString).isAbsolutePath else { return false }
        return !canonicalPaths(for: URL(fileURLWithPath: path, isDirectory: true))
            .isDisjoint(with: expectedPaths)
    }

    private func canonicalPaths(for directory: URL) -> Set<String> {
        let standardized = directory.standardizedFileURL
        return [
            standardized.path,
            claudeResolvedDirectoryURL(standardized).path,
        ]
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

    private func forEachRecord(
        in file: URL,
        handle: ([String: Any]) -> Void
    ) throws {
        let didRead = SupermuxLineReader.forEachLine(in: file) { line in
            guard let value = try? JSONSerialization.jsonObject(with: Data(line)),
                  let object = value as? [String: Any] else {
                return
            }
            handle(object)
        }
        guard didRead else { throw CocoaError(.fileReadNoSuchFile) }
    }

    private func updateMetadata(
        _ metadata: inout SessionMetadata,
        with record: [String: Any]
    ) {
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
            return
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

    private func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
