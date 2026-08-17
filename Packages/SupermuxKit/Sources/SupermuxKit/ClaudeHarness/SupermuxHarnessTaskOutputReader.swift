public import Foundation

/// Securely tails output for task identifiers observed in Claude protocol frames.
public struct SupermuxHarnessTaskOutputReader {
    private let lexicalRootURL: URL
    private let canonicalRootURL: URL
    private let fileManager: FileManager
    private let maximumBytes: Int

    /// Creates a task-output reader scoped to one Claude temporary root.
    ///
    /// The normal root is `/tmp/claude-<uid>`. Its symlink-resolved form is also accepted lexically,
    /// while every final path must remain beneath the resolved root.
    ///
    /// - Parameters:
    ///   - temporaryRootURL: The unresolved Claude temporary root for the current user.
    ///   - canonicalRootURL: The trusted physical root, normally `/private/tmp/claude-<uid>`.
    ///   - fileManager: The filesystem implementation to use.
    ///   - maximumBytes: The approximate maximum output tail size, defaulting to 64 KiB.
    public init(
        temporaryRootURL: URL,
        canonicalRootURL: URL,
        fileManager: FileManager,
        maximumBytes: Int = 64 << 10
    ) {
        lexicalRootURL = temporaryRootURL.standardizedFileURL
        self.canonicalRootURL = Self.trustedCanonicalRootURL(canonicalRootURL)
        self.fileManager = fileManager
        self.maximumBytes = max(0, maximumBytes)
    }

    /// Reads the bounded tail for one known task using only its native-cached output path.
    ///
    /// - Parameters:
    ///   - taskID: The task identifier received from the bridge.
    ///   - observedTaskIDs: Task identifiers previously observed in protocol frames.
    ///   - outputFilePath: The output path cached or derived by native controller state, never web input.
    ///   - expectedOutputFilePath: An optional independently derived path for the current cwd and session.
    /// - Returns: A bounded output tail, or a calm missing result when no valid file exists yet.
    /// - Throws: ``SupermuxHarnessTaskOutputReaderError`` or a file-reading error.
    public func read(
        taskID: String,
        observedTaskIDs: Set<String>,
        outputFilePath: String?,
        expectedOutputFilePath: String? = nil
    ) throws -> SupermuxHarnessTaskOutputPage {
        guard observedTaskIDs.contains(taskID) else {
            throw SupermuxHarnessTaskOutputReaderError.unknownTaskID
        }
        guard isSafeTaskID(taskID) else {
            throw SupermuxHarnessTaskOutputReaderError.invalidTaskID
        }
        guard let candidatePath = outputFilePath ?? expectedOutputFilePath else {
            return SupermuxHarnessTaskOutputPage(text: "", truncated: false, missing: true)
        }
        let candidateURL = try validatedCanonicalURL(
            for: candidatePath,
            taskID: taskID
        )
        if let expectedOutputFilePath {
            let expectedURL = try validatedCanonicalURL(
                for: expectedOutputFilePath,
                taskID: taskID
            )
            guard candidateURL.pathComponents == expectedURL.pathComponents else {
                throw SupermuxHarnessTaskOutputReaderError.unsafeOutputPath
            }
        }
        guard fileManager.fileExists(atPath: candidateURL.path) else {
            return SupermuxHarnessTaskOutputPage(text: "", truncated: false, missing: true)
        }
        let attributes = try fileManager.attributesOfItem(atPath: candidateURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SupermuxHarnessTaskOutputReaderError.outputIsNotRegularFile
        }

        let handle = try FileHandle(forReadingFrom: candidateURL)
        defer { try? handle.close() }
        let endOffset = try handle.seekToEnd()
        let retainedByteCount = min(UInt64(maximumBytes), endOffset)
        let startOffset = endOffset - retainedByteCount
        try handle.seek(toOffset: startOffset)
        let data = try handle.read(upToCount: maximumBytes) ?? Data()
        return SupermuxHarnessTaskOutputPage(
            text: String(decoding: data, as: UTF8.self),
            truncated: startOffset > 0,
            missing: false
        )
    }

    private func validatedCanonicalURL(
        for rawPath: String,
        taskID: String
    ) throws -> URL {
        guard (rawPath as NSString).isAbsolutePath,
              !rawPath.unicodeScalars.contains("\0"),
              !hasTraversalComponent(rawPath) else {
            throw SupermuxHarnessTaskOutputReaderError.unsafeOutputPath
        }
        let rawComponents = (rawPath as NSString).pathComponents
        let acceptedRoots = [lexicalRootURL, canonicalRootURL]
        guard acceptedRoots.contains(where: { root in
            hasStrictPrefix(rawComponents, prefix: root.pathComponents)
        }), hasExpectedSuffix(rawComponents, taskID: taskID) else {
            throw SupermuxHarnessTaskOutputReaderError.unsafeOutputPath
        }

        let canonicalURL = Self.canonicalizedFileURL(
            URL(fileURLWithPath: rawPath)
        )
        let canonicalComponents = canonicalURL.pathComponents
        guard hasStrictPrefix(canonicalComponents, prefix: canonicalRootURL.pathComponents),
              hasExpectedSuffix(canonicalComponents, taskID: taskID) else {
            throw SupermuxHarnessTaskOutputReaderError.unsafeOutputPath
        }
        return canonicalURL
    }

    /// Preserves the caller's trusted physical root without following a root
    /// symlink that could redefine the security boundary.
    private static func trustedCanonicalRootURL(_ url: URL) -> URL {
        let path = (url.path as NSString).standardizingPath
        guard path == "/tmp" || path.hasPrefix("/tmp/") else {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: "/private\(path)", isDirectory: true)
    }

    /// macOS 14 Foundation may preserve or reintroduce the `/tmp` alias while
    /// Claude records the physical `/private/tmp` path. Normalize it explicitly.
    private static func canonicalizedFileURL(_ url: URL) -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        guard path == "/tmp" || path.hasPrefix("/tmp/") else { return resolved }
        return URL(fileURLWithPath: "/private\(path)")
    }

    private func hasTraversalComponent(_ path: String) -> Bool {
        (path as NSString).pathComponents.contains { $0 == "." || $0 == ".." }
    }

    private func hasStrictPrefix(_ components: [String], prefix: [String]) -> Bool {
        components.count > prefix.count && components.prefix(prefix.count).elementsEqual(prefix)
    }

    private func hasExpectedSuffix(_ components: [String], taskID: String) -> Bool {
        components.count >= 2 &&
            components.suffix(2).elementsEqual(["tasks", "\(taskID).output"])
    }

    private func isSafeTaskID(_ taskID: String) -> Bool {
        guard !taskID.isEmpty else { return false }
        return taskID.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }
}
