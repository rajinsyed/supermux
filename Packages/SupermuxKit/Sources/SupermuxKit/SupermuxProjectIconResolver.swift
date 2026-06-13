public import Foundation

/// Locates a project's logo on disk by probing the common locations where
/// repositories keep a favicon, logo, or app icon — mirroring t3code's favicon
/// resolver.
///
/// Probing is an ordered walk of relative paths under the project root; the
/// first path that resolves to a regular file wins. The type is a pure value so
/// it can be unit-tested and run off the main actor.
public struct SupermuxProjectIconResolver: Sendable {
    /// Relative candidate paths probed under the project root, in priority
    /// order. Vector art (`.svg`) is preferred within each directory group, and
    /// directories are searched root → `public/` → `app/` → `src/` →
    /// `src/app/` → `assets/` → `.idea/`, matching common web-project and IDE
    /// conventions.
    public static let candidatePaths: [String] = [
        "favicon.svg",
        "favicon.ico",
        "favicon.png",
        "logo.svg",
        "logo.png",
        "icon.svg",
        "icon.png",
        "icon.icns",
        "public/favicon.svg",
        "public/favicon.ico",
        "public/favicon.png",
        "public/logo.svg",
        "public/logo.png",
        "public/icon.svg",
        "public/icon.png",
        "app/favicon.ico",
        "app/favicon.png",
        "app/icon.svg",
        "app/icon.png",
        "app/icon.ico",
        "src/favicon.svg",
        "src/favicon.ico",
        "src/app/favicon.ico",
        "src/app/icon.svg",
        "src/app/icon.png",
        "assets/icon.svg",
        "assets/icon.png",
        "assets/logo.svg",
        "assets/logo.png",
        ".idea/icon.svg",
    ]

    /// Creates a resolver.
    public init() {}

    /// Returns the first existing logo file under `rootPath`, or `nil` when the
    /// project has no recognizable logo.
    ///
    /// Only regular files match: a directory that happens to be named like an
    /// icon candidate (e.g. an `assets/` folder containing many icons) is
    /// skipped so the avatar never points at a directory.
    /// - Parameter rootPath: Absolute path to the project root.
    /// - Returns: The resolved icon file URL, or `nil`.
    public func resolve(rootPath: String) -> URL? {
        let expanded = (rootPath as NSString).expandingTildeInPath
        let root = URL(fileURLWithPath: expanded, isDirectory: true)
        let fileManager = FileManager.default
        for relative in Self.candidatePaths {
            let candidate = root.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
                continue
            }
            if !isDirectory.boolValue {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }
}
