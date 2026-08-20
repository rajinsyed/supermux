import Foundation

/// Resolves Claude project aliases and enforces the persisted-session boundary.
struct SupermuxHarnessSessionPathPolicy: Sendable {
    let projectsRootURL: URL

    init(projectsRootURL: URL) {
        self.projectsRootURL = projectsRootURL.standardizedFileURL
    }

    func mungedProjectDirectoryNames(for workingDirectoryURL: URL) -> [String] {
        let unresolved = workingDirectoryURL.standardizedFileURL
        let resolved = Self.claudeResolvedDirectoryURL(unresolved)
        var names: [String] = []
        for path in [resolved.path, unresolved.path] {
            let name = Self.mungedPath(path)
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    func projectDirectoryURLs(for workingDirectoryURL: URL) -> [URL] {
        mungedProjectDirectoryNames(for: workingDirectoryURL).map {
            projectsRootURL.appendingPathComponent($0, isDirectory: true)
        }
    }

    func safeProjectDirectory(_ directory: URL) -> URL? {
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
        guard Self.isDescendant(resolvedDirectory, of: resolvedRoot) else { return nil }
        return directory
    }

    func safeSessionFile(_ file: URL, in directory: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true else {
            return false
        }
        return Self.isDescendant(
            file.resolvingSymlinksInPath().standardizedFileURL,
            of: directory.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    func isValidSessionID(_ sessionID: String) -> Bool {
        guard !sessionID.isEmpty,
              sessionID == URL(fileURLWithPath: sessionID).lastPathComponent else {
            return false
        }
        return sessionID.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    static func canonicalPaths(for directory: URL) -> Set<String> {
        let standardized = directory.standardizedFileURL
        return [
            standardized.path,
            claudeResolvedDirectoryURL(standardized).path,
        ]
    }

    static func canonicalPaths(forRecordedPath path: String) -> Set<String> {
        guard (path as NSString).isAbsolutePath else { return [] }
        return canonicalPaths(for: URL(fileURLWithPath: path, isDirectory: true))
    }

    static func canonicalFileURL(_ fileURL: URL) -> URL {
        let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        guard path == "/tmp" || path.hasPrefix("/tmp/") else { return resolved }
        return URL(fileURLWithPath: "/private\(path)", isDirectory: false)
    }

    private static func claudeResolvedDirectoryURL(_ directory: URL) -> URL {
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        guard path == "/tmp" || path.hasPrefix("/tmp/") else { return resolved }
        // Standardizing this explicit physical path aliases it back to `/tmp` on macOS 14.
        return URL(fileURLWithPath: "/private\(path)", isDirectory: true)
    }

    private static func mungedPath(_ path: String) -> String {
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

    private static func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let directoryComponents = directory.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > directoryComponents.count else { return false }
        return candidateComponents.prefix(directoryComponents.count).elementsEqual(directoryComponents)
    }
}
