public import CmuxFoundation
public import Foundation
public import SupermuxMobileCore

/// Why setting a project up on a Mac failed.
public enum SupermuxProjectSetupError: Error, LocalizedError, Equatable {
    /// The folder is not an absolute path.
    case invalidPath
    /// Clone target already exists and is not an empty folder.
    case destinationExists(String)
    /// The repository URL is empty or looks like a git option.
    case invalidRemote
    /// `git clone` failed (its message).
    case cloneFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            return String(localized: "supermux.projectSetup.error.invalidPath", defaultValue: "Enter an absolute folder path.")
        case .destinationExists(let path):
            return String(localized: "supermux.projectSetup.error.destinationExists", defaultValue: "“\(path)” already exists and is not empty.")
        case .invalidRemote:
            return String(localized: "supermux.projectSetup.error.invalidRemote", defaultValue: "The project has no repository URL to clone.")
        case .cloneFailed(let message):
            return message
        }
    }

    /// A stable wire code (`mobile.supermux.project.clone` errors).
    public var code: String {
        switch self {
        case .invalidPath, .invalidRemote: return "invalid_params"
        case .destinationExists: return "destination_exists"
        case .cloneFailed: return "clone_failed"
        }
    }
}

/// The filesystem and git side of cross-Mac project setup, run on the Mac
/// that will hold the copy: probe a folder (`project.probe`) and clone a
/// repository into a folder (`project.clone`). Registration itself stays with
/// `SupermuxProjectsModel.addProject`.
public struct SupermuxProjectSetupService: Sendable {
    /// `git clone` deadline (large repos over slow links).
    public static let cloneTimeout: TimeInterval = 900

    private let runner: any CommandRunning

    /// Creates the service; tests inject a fake runner.
    public init(runner: any CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    /// The folder's standardized absolute form, or `nil` when not absolute.
    public static func standardizedRoot(_ raw: String) -> String? {
        let expanded = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return (expanded as NSString).standardizingPath
    }

    /// What `rootPath` is on this Mac.
    public func probe(rootPath raw: String, isSuppressed: Bool) async -> SupermuxProjectProbeDTO {
        guard let root = Self.standardizedRoot(raw) else {
            return SupermuxProjectProbeDTO(rootPath: raw, exists: false, isDirectory: false, isGitRepo: false)
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            return SupermuxProjectProbeDTO(
                rootPath: root, exists: exists, isDirectory: false, isGitRepo: false, isSuppressed: isSuppressed
            )
        }
        let inside = await git(["rev-parse", "--is-inside-work-tree"], in: root)
        let isGitRepo = inside?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        let origin = isGitRepo ? await git(["config", "--get", "remote.origin.url"], in: root) : nil
        let url = origin?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SupermuxProjectProbeDTO(
            rootPath: root,
            exists: true,
            isDirectory: true,
            isGitRepo: isGitRepo,
            gitRemoteURL: url?.isEmpty == false ? url : nil,
            isSuppressed: isSuppressed
        )
    }

    /// Clones `remoteURL` into `rootPath` (creating missing parent folders).
    /// The target must not exist, or be an empty folder.
    /// - Returns: The standardized root the repository now lives at.
    public func clone(remoteURL raw: String, into rootPath: String) async throws -> String {
        let remote = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty, !remote.hasPrefix("-") else { throw SupermuxProjectSetupError.invalidRemote }
        guard let root = Self.standardizedRoot(rootPath) else { throw SupermuxProjectSetupError.invalidPath }
        let manager = FileManager.default
        if manager.fileExists(atPath: root) {
            let contents = (try? manager.contentsOfDirectory(atPath: root)) ?? [".unreadable"]
            guard contents.isEmpty else { throw SupermuxProjectSetupError.destinationExists(root) }
        }
        let parent = (root as NSString).deletingLastPathComponent
        do {
            try manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } catch {
            throw SupermuxProjectSetupError.cloneFailed(error.localizedDescription)
        }
        let result = await runner.run(
            directory: parent,
            executable: "git",
            arguments: ["clone", "--quiet", "--", remote, root],
            timeout: Self.cloneTimeout
        )
        guard result.exitStatus == 0 else {
            let message = result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? result.executionError
                ?? (result.timedOut ? "git clone timed out" : "git clone failed")
            throw SupermuxProjectSetupError.cloneFailed(message.isEmpty ? "git clone failed" : message)
        }
        return root
    }

    private func git(_ arguments: [String], in directory: String) async -> String? {
        let result = await runner.run(directory: directory, executable: "git", arguments: arguments, timeout: 10)
        return result.exitStatus == 0 ? result.stdout : nil
    }
}
