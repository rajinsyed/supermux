public import Foundation

/// Locates and replays Claude local-agent and workflow-agent transcripts.
public struct SupermuxHarnessSubagentTranscriptReader {
    private struct RetainedEvent {
        let event: SupermuxHarnessJSONObject
        let byteCount: Int
    }

    private let projectsRootURL: URL
    private let fileManager: FileManager
    private let maximumTranscriptBytes: Int
    private let mapper = SupermuxHarnessSessionRecordMapper()

    /// Creates a bounded subagent-transcript reader.
    ///
    /// - Parameters:
    ///   - projectsRootURL: The Claude projects directory, normally `~/.claude/projects`.
    ///   - fileManager: The filesystem implementation to use.
    ///   - maximumTranscriptBytes: The maximum combined source-record bytes retained in one replay.
    public init(
        projectsRootURL: URL,
        fileManager: FileManager,
        maximumTranscriptBytes: Int = 1 << 20
    ) {
        self.projectsRootURL = projectsRootURL.standardizedFileURL
        self.fileManager = fileManager
        self.maximumTranscriptBytes = max(0, maximumTranscriptBytes)
    }

    /// Loads a local subagent transcript for a protocol task identifier.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The session working directory used for Claude cwd munging.
    ///   - sessionID: The owning Claude session identifier.
    ///   - taskID: The local-agent task identifier.
    /// - Returns: A bounded replay page, with `missing` set when the file is not present yet.
    /// - Throws: ``SupermuxHarnessSubagentTranscriptReaderError`` or a file-reading error.
    public func loadLocalAgentTranscript(
        for workingDirectoryURL: URL,
        sessionID: String,
        taskID: String
    ) throws -> SupermuxHarnessSubagentTranscriptPage {
        guard isSafeIdentifier(sessionID), isSafeIdentifier(taskID) else {
            throw SupermuxHarnessSubagentTranscriptReaderError.invalidIdentifier
        }
        return try loadTranscript(
            workingDirectoryURL: workingDirectoryURL,
            sessionID: sessionID,
            relativeDirectoryComponents: ["subagents"],
            agentID: taskID
        )
    }

    /// Loads one agent transcript from a dynamic workflow run.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The session working directory used for Claude cwd munging.
    ///   - sessionID: The owning Claude session identifier.
    ///   - workflowRunID: The workflow run identifier, such as `wf_abc-123`.
    ///   - agentID: The workflow agent identifier.
    /// - Returns: A bounded replay page, with `missing` set when the file is not present yet.
    /// - Throws: ``SupermuxHarnessSubagentTranscriptReaderError`` or a file-reading error.
    public func loadWorkflowAgentTranscript(
        for workingDirectoryURL: URL,
        sessionID: String,
        workflowRunID: String,
        agentID: String
    ) throws -> SupermuxHarnessSubagentTranscriptPage {
        guard isSafeIdentifier(sessionID),
              isSafeIdentifier(workflowRunID),
              isSafeIdentifier(agentID) else {
            throw SupermuxHarnessSubagentTranscriptReaderError.invalidIdentifier
        }
        return try loadTranscript(
            workingDirectoryURL: workingDirectoryURL,
            sessionID: sessionID,
            relativeDirectoryComponents: ["subagents", "workflows", workflowRunID],
            agentID: agentID
        )
    }

    private func loadTranscript(
        workingDirectoryURL: URL,
        sessionID: String,
        relativeDirectoryComponents: [String],
        agentID: String
    ) throws -> SupermuxHarnessSubagentTranscriptPage {
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projectsRootURL,
            fileManager: fileManager
        )
        for projectDirectory in discovery.projectDirectoryURLs(for: workingDirectoryURL) {
            guard fileManager.fileExists(atPath: projectDirectory.path) else { continue }
            guard safeDirectory(projectDirectory, beneath: projectsRootURL) else {
                throw SupermuxHarnessSubagentTranscriptReaderError.unsafeTranscriptPath
            }
            let sessionDirectory = projectDirectory
                .appendingPathComponent(sessionID, isDirectory: true)
            guard fileManager.fileExists(atPath: sessionDirectory.path) else { continue }
            guard safeDirectory(sessionDirectory, beneath: projectDirectory) else {
                throw SupermuxHarnessSubagentTranscriptReaderError.unsafeTranscriptPath
            }
            let transcriptDirectory = relativeDirectoryComponents.reduce(sessionDirectory) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            let transcriptURL = transcriptDirectory
                .appendingPathComponent("agent-\(agentID)")
                .appendingPathExtension("jsonl")
            guard fileManager.fileExists(atPath: transcriptURL.path) else { continue }
            guard safeRegularFile(transcriptURL, beneath: sessionDirectory) else {
                throw SupermuxHarnessSubagentTranscriptReaderError.unsafeTranscriptPath
            }
            return try readTranscript(
                transcriptURL,
                sessionID: sessionID,
                workingDirectoryURL: workingDirectoryURL,
                discovery: discovery
            )
        }
        return SupermuxHarnessSubagentTranscriptPage(
            events: [],
            truncated: false,
            missing: true,
            metadata: nil
        )
    }

    private func readTranscript(
        _ transcriptURL: URL,
        sessionID: String,
        workingDirectoryURL: URL,
        discovery: SupermuxHarnessSessionDiscovery
    ) throws -> SupermuxHarnessSubagentTranscriptPage {
        var retained: [RetainedEvent] = []
        var retainedStartIndex = 0
        var retainedByteCount = 0
        var truncated = false
        var foundRecordedDirectory = false
        var foundMatchingDirectory = false
        let didRead = SupermuxLineReader.forEachLine(in: transcriptURL) { line in
            guard let value = try? JSONSerialization.jsonObject(with: Data(line)),
                  let record = value as? [String: Any] else {
                return
            }
            if let recordedDirectory = nonemptyString(record["cwd"]) {
                foundRecordedDirectory = true
                foundMatchingDirectory = foundMatchingDirectory || discovery.recordedDirectory(
                    recordedDirectory,
                    matches: workingDirectoryURL
                )
            }
            guard let event = mapper.protocolEvent(
                from: record,
                fallbackSessionID: sessionID
            ) else {
                return
            }
            retained.append(RetainedEvent(event: event, byteCount: line.count))
            retainedByteCount += line.count
            while retainedStartIndex < retained.count,
                  retainedByteCount > maximumTranscriptBytes {
                retainedByteCount -= retained[retainedStartIndex].byteCount
                retainedStartIndex += 1
                truncated = true
            }
            if retainedStartIndex >= 1_024,
               retainedStartIndex * 2 >= retained.count {
                retained.removeFirst(retainedStartIndex)
                retainedStartIndex = 0
            }
        }
        guard didRead else { throw CocoaError(.fileReadNoSuchFile) }
        guard !foundRecordedDirectory || foundMatchingDirectory else {
            throw SupermuxHarnessSubagentTranscriptReaderError.unsafeTranscriptPath
        }
        let events = retained[retainedStartIndex...].map(\.event)
        return SupermuxHarnessSubagentTranscriptPage(
            events: events,
            truncated: truncated,
            missing: false,
            metadata: try readMetadata(beside: transcriptURL)
        )
    }

    private func readMetadata(
        beside transcriptURL: URL
    ) throws -> SupermuxHarnessSubagentTranscriptMetadata? {
        let metadataURL = URL(
            fileURLWithPath: transcriptURL.deletingPathExtension().path + ".meta.json"
        )
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        let sessionDirectory = transcriptURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard safeRegularFile(metadataURL, beneath: sessionDirectory) else {
            throw SupermuxHarnessSubagentTranscriptReaderError.unsafeTranscriptPath
        }
        let handle = try FileHandle(forReadingFrom: metadataURL)
        defer { try? handle.close() }
        let maximumMetadataBytes = 64 << 10
        let data = try handle.read(upToCount: maximumMetadataBytes + 1) ?? Data()
        guard !data.isEmpty,
              data.count <= maximumMetadataBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return SupermuxHarnessSubagentTranscriptMetadata(
            agentType: nonemptyString(object["agentType"]),
            description: nonemptyString(object["description"]),
            spawnDepth: nonnegativeInteger(object["spawnDepth"])
        )
    }

    private func safeDirectory(_ directory: URL, beneath root: URL) -> Bool {
        guard let values = try? directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]),
        values.isDirectory == true,
        values.isSymbolicLink != true else {
            return false
        }
        return isDescendant(
            directory.resolvingSymlinksInPath().standardizedFileURL,
            of: root.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    private func safeRegularFile(_ file: URL, beneath root: URL) -> Bool {
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
            of: root.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        var decimal = number.decimalValue
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 0, .plain)
        guard rounded == decimal,
              decimal >= 0,
              decimal <= Decimal(Int.max) else {
            return nil
        }
        return number.intValue
    }

    private func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
