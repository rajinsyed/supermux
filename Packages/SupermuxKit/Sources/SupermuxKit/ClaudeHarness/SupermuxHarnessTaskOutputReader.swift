import Darwin
public import Foundation

/// Securely tails output for task identifiers observed in Claude protocol frames.
public struct SupermuxHarnessTaskOutputReader {
    private let lexicalRootURL: URL
    private let canonicalRootURL: URL
    private let maximumBytes: Int

    /// Creates a task-output reader scoped to one Claude temporary root.
    ///
    /// The normal root is `/tmp/claude-<uid>`. Its symlink-resolved form is also accepted lexically,
    /// while every final path must remain beneath the resolved root.
    ///
    /// - Parameters:
    ///   - temporaryRootURL: The unresolved Claude temporary root for the current user.
    ///   - canonicalRootURL: The trusted physical root, normally `/private/tmp/claude-<uid>`.
    ///   - maximumBytes: The approximate maximum output tail size, defaulting to 64 KiB.
    public init(
        temporaryRootURL: URL,
        canonicalRootURL: URL,
        maximumBytes: Int = 64 << 10
    ) {
        lexicalRootURL = temporaryRootURL.standardizedFileURL
        self.canonicalRootURL = Self.trustedCanonicalRootURL(canonicalRootURL)
        self.maximumBytes = max(0, maximumBytes)
    }

    /// Reads the bounded tail for one known task using only its native-cached output path.
    ///
    /// - Parameters:
    ///   - taskID: The task identifier received from the bridge.
    ///   - observedTaskIDs: Task identifiers previously observed in protocol frames.
    ///   - outputFilePath: The output path cached or derived by native controller state, never web input.
    ///   - expectedOutputFilePaths: Independently derived lexical and physical paths for the cwd/session.
    /// - Returns: A bounded output tail, or a calm missing result when no valid file exists yet.
    /// - Throws: ``SupermuxHarnessTaskOutputReaderError`` or a file-reading error.
    public func read(
        taskID: String,
        observedTaskIDs: Set<String>,
        outputFilePath: String?,
        expectedOutputFilePaths: [String] = []
    ) throws -> SupermuxHarnessTaskOutputPage {
        guard observedTaskIDs.contains(taskID) else {
            throw SupermuxHarnessTaskOutputReaderError.unknownTaskID
        }
        guard isSafeTaskID(taskID) else {
            throw SupermuxHarnessTaskOutputReaderError.invalidTaskID
        }
        guard let candidatePath = outputFilePath ?? expectedOutputFilePaths.first else {
            return SupermuxHarnessTaskOutputPage(text: "", truncated: false, missing: true)
        }
        let candidateURL = try validatedCanonicalURL(
            for: candidatePath,
            taskID: taskID
        )
        if !expectedOutputFilePaths.isEmpty {
            let expectedURLs = try expectedOutputFilePaths.map {
                try validatedCanonicalURL(for: $0, taskID: taskID)
            }
            guard expectedURLs.contains(where: {
                candidateURL.pathComponents == $0.pathComponents
            }) else {
                throw SupermuxHarnessTaskOutputReaderError.unsafeOutputPath
            }
        }
        // Normalize only the system's /tmp alias, then require every remaining
        // component to be the canonical spelling validated above. Component-wise
        // openat with O_NOFOLLOW binds the final descriptor without following an
        // intermediate or final symlink between validation and open.
        let openURL = Self.lexicalPhysicalURL(for: candidatePath, matching: candidateURL)
        guard openURL.pathComponents == candidateURL.pathComponents else {
            throw SupermuxHarnessTaskOutputReaderError.unsafeOutputPath
        }
        guard let descriptor = try Self.openWithoutFollowingSymlinks(openURL) else {
            return SupermuxHarnessTaskOutputPage(text: "", truncated: false, missing: true)
        }
        do {
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard (status.st_mode & S_IFMT) == S_IFREG else {
                throw SupermuxHarnessTaskOutputReaderError.outputIsNotRegularFile
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let endOffset = try handle.seekToEnd()
        let retainedByteCount = min(UInt64(maximumBytes), endOffset)
        let startOffset = endOffset - retainedByteCount
        try handle.seek(toOffset: startOffset)
        let data = try handle.read(upToCount: maximumBytes) ?? Data()
        let alignedData = Self.droppingLeadingUTF8ContinuationBytes(data)
        return SupermuxHarnessTaskOutputPage(
            text: String(decoding: alignedData, as: UTF8.self),
            truncated: startOffset > 0,
            missing: false
        )
    }

    private static func lexicalPhysicalURL(for rawPath: String, matching canonicalURL: URL) -> URL {
        let standardized = (rawPath as NSString).standardizingPath
        let lexicalURL = URL(fileURLWithPath: standardized)
        if lexicalURL.pathComponents == canonicalURL.pathComponents {
            return lexicalURL
        }
        let aliases = ["/tmp", "/var", "/etc"]
        let usesSystemAlias = aliases.contains { alias in
            standardized == alias || standardized.hasPrefix("\(alias)/")
        }
        guard usesSystemAlias else { return lexicalURL }
        return URL(fileURLWithPath: "/private\(standardized)")
    }

    private static func openWithoutFollowingSymlinks(_ fileURL: URL) throws -> Int32? {
        let components = fileURL.pathComponents.dropFirst()
        guard let fileName = components.last else {
            throw SupermuxHarnessTaskOutputReaderError.unsafeOutputPath
        }
        var parentDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(parentDescriptor) }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else {
                let code = errno
                if code == ENOENT { return nil }
                if code == ELOOP || code == ENOTDIR {
                    throw SupermuxHarnessTaskOutputReaderError.unsafeOutputPath
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            Darwin.close(parentDescriptor)
            parentDescriptor = nextDescriptor
        }
        let descriptor = fileName.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            if code == ELOOP {
                throw SupermuxHarnessTaskOutputReaderError.outputIsNotRegularFile
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return descriptor
    }

    private static func droppingLeadingUTF8ContinuationBytes(_ data: Data) -> Data {
        let firstScalar = data.firstIndex { byte in
            byte & 0b1100_0000 != 0b1000_0000
        }
        guard let firstScalar else { return Data() }
        guard firstScalar != data.startIndex else { return data }
        return Data(data[firstScalar...])
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
        let path = physicalSystemAliasPath((url.path as NSString).standardizingPath)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Foundation differs across macOS releases on whether it preserves the
    /// `/tmp`, `/var`, and `/etc` aliases. Normalize their physical spellings.
    private static func canonicalizedFileURL(_ url: URL) -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        return URL(fileURLWithPath: physicalSystemAliasPath(resolved.path))
    }

    private static func physicalSystemAliasPath(_ path: String) -> String {
        let aliases = ["/tmp", "/var", "/etc"]
        return aliases.contains(where: { alias in
            path == alias || path.hasPrefix("\(alias)/")
        }) ? "/private\(path)" : path
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
