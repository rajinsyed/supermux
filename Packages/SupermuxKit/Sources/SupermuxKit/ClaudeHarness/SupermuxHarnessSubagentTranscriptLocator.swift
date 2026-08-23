import Foundation

/// Resolves one validated logical transcript address to safe on-disk files.
struct SupermuxHarnessSubagentTranscriptLocator: Sendable {
    struct Location: Sendable {
        let transcriptURL: URL
        let sessionDirectoryURL: URL

        var metadataURL: URL {
            URL(fileURLWithPath: transcriptURL.deletingPathExtension().path + ".meta.json")
        }
    }

    private let projectsRootURL: URL
    /// Foundation supports independent `FileManager` operations concurrently; this reference is immutable.
    nonisolated(unsafe) private let fileManager: FileManager

    init(projectsRootURL: URL, fileManager: FileManager) {
        self.projectsRootURL = projectsRootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func locate(
        _ address: SupermuxHarnessSubagentTranscriptAddress
    ) throws -> Location? {
        guard address.identifiers.allSatisfy(isSafeIdentifier) else {
            throw SupermuxHarnessSubagentTranscriptReaderError.invalidIdentifier
        }
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projectsRootURL,
            fileManager: fileManager
        )
        for projectDirectory in discovery.projectDirectoryURLs(
            for: address.workingDirectoryURL
        ) {
            guard fileManager.fileExists(atPath: projectDirectory.path) else { continue }
            guard safeDirectory(projectDirectory, beneath: projectsRootURL) else {
                throw SupermuxHarnessSubagentTranscriptReaderError.unsafeTranscriptPath
            }
            let sessionDirectory = projectDirectory
                .appendingPathComponent(address.sessionID, isDirectory: true)
            guard fileManager.fileExists(atPath: sessionDirectory.path) else { continue }
            guard safeDirectory(sessionDirectory, beneath: projectDirectory) else {
                throw SupermuxHarnessSubagentTranscriptReaderError.unsafeTranscriptPath
            }
            let transcriptURL: URL
            switch address {
            case .localAgent(_, _, let taskID):
                transcriptURL = sessionDirectory
                    .appendingPathComponent("subagents", isDirectory: true)
                    .appendingPathComponent("agent-\(taskID).jsonl")
            case .workflowAgent(_, _, let workflowRunID, let agentID):
                transcriptURL = sessionDirectory
                    .appendingPathComponent("subagents", isDirectory: true)
                    .appendingPathComponent("workflows", isDirectory: true)
                    .appendingPathComponent(workflowRunID, isDirectory: true)
                    .appendingPathComponent("agent-\(agentID).jsonl")
            }
            guard fileManager.fileExists(atPath: transcriptURL.path) else { continue }
            guard safeRegularFile(transcriptURL, beneath: sessionDirectory) else {
                throw SupermuxHarnessSubagentTranscriptReaderError.unsafeTranscriptPath
            }
            return Location(
                transcriptURL: transcriptURL,
                sessionDirectoryURL: sessionDirectory
            )
        }
        return nil
    }

    func readMetadata(
        beside location: Location
    ) throws -> SupermuxHarnessSubagentTranscriptMetadata? {
        let metadataURL = location.metadataURL
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        guard safeRegularFile(metadataURL, beneath: location.sessionDirectoryURL) else {
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

    func recordedDirectory(
        _ recordedDirectory: String,
        matches address: SupermuxHarnessSubagentTranscriptAddress
    ) -> Bool {
        SupermuxHarnessSessionDiscovery(
            projectsRootURL: projectsRootURL,
            fileManager: fileManager
        ).recordedDirectory(
            recordedDirectory,
            matches: address.workingDirectoryURL
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
