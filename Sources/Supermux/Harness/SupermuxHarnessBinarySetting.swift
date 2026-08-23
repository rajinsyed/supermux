import Foundation

/// Persists and validates the Claude executable override used only by harness panes.
struct SupermuxHarnessBinarySetting {
    static let defaultsKey = "supermux.harness.claudeExecutablePath"

    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    /// The stored override exactly as normalized when it was saved.
    var overridePath: String? {
        guard let expanded = expandedPath(defaults.string(forKey: Self.defaultsKey)),
              (expanded as NSString).isAbsolutePath else {
            return nil
        }
        return standardizedPath(expanded)
    }

    /// The stored override when it still names an executable regular file.
    var validOverridePath: String? {
        guard let overridePath, isExecutableFile(atPath: overridePath) else { return nil }
        return overridePath
    }

    /// Validates and saves a path, or clears the setting for nil and empty input.
    @discardableResult
    func setPath(_ rawPath: String?) throws -> String? {
        guard let expanded = expandedPath(rawPath) else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return nil
        }
        guard (expanded as NSString).isAbsolutePath else {
            throw SupermuxHarnessBridgeError.invalidBinaryPath
        }
        let path = standardizedPath(expanded)
        guard isExecutableFile(atPath: path) else {
            throw SupermuxHarnessBridgeError.invalidBinaryPath
        }
        defaults.set(path, forKey: Self.defaultsKey)
        return path
    }

    private func expandedPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
    }

    private func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: path)
    }
}
