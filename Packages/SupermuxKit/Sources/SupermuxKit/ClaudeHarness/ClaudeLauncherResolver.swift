public import Foundation
public import SupermuxClaudeHarness

/// Resolves the launcher executable used to start Claude Code.
///
/// Resolution happens once at session creation and the canonical path is
/// persisted; resume reuses the persisted record. The cmux claude wrapper is
/// rejected by content marker (same check as `AgentExecutableResolver`) so
/// harness sessions never double-report through the wrapper's hooks.
public struct ClaudeLauncherResolver: Sendable {
    public enum ResolutionError: Error, Sendable, Equatable {
        case notFound(name: String)
        case notExecutable(path: String)
        case cmuxWrapperRejected(path: String)
    }

    private let pathVariable: String
    private var fileManager: FileManager { .default }

    public init(
        pathVariable: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        self.pathVariable = pathVariable
    }

    /// Resolves a launcher of the given kind, optionally at an explicit path.
    public func resolve(
        kind: ClaudeLauncher.Kind,
        explicitPath: String? = nil
    ) throws -> ClaudeLauncher {
        let name: String
        let displayName: String
        switch kind {
        case .claude:
            name = "claude"
            displayName = "Claude Code"
        case .ccx:
            name = "ccx"
            displayName = "ccx"
        case .custom:
            guard let explicitPath else {
                throw ResolutionError.notFound(name: "custom launcher")
            }
            let canonical = try validate(path: explicitPath)
            return ClaudeLauncher(
                kind: .custom,
                executablePath: canonical,
                displayName: (canonical as NSString).lastPathComponent
            )
        }
        let path: String
        if let explicitPath {
            path = try validate(path: explicitPath)
        } else {
            path = try probe(name: name)
        }
        return ClaudeLauncher(kind: kind, executablePath: path, displayName: displayName)
    }

    private func probe(name: String) throws -> String {
        for directory in pathVariable.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .standardizedFileURL.path
            guard fileManager.isExecutableFile(atPath: candidate) else { continue }
            if isCmuxClaudeWrapper(path: candidate) { continue }
            return candidate
        }
        throw ResolutionError.notFound(name: name)
    }

    private func validate(path: String) throws -> String {
        let canonical = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
        guard fileManager.isExecutableFile(atPath: canonical) else {
            throw ResolutionError.notExecutable(path: canonical)
        }
        if isCmuxClaudeWrapper(path: canonical) {
            throw ResolutionError.cmuxWrapperRejected(path: canonical)
        }
        return canonical
    }

    /// Content-marker check copied from `AgentExecutableResolver`.
    private func isCmuxClaudeWrapper(path: String) -> Bool {
        guard let data = fileManager.contents(atPath: path),
              let prefix = String(data: data.prefix(512), encoding: .utf8) else {
            return false
        }
        return prefix.contains("cmux claude wrapper - injects hooks and session tracking")
    }
}
