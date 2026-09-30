public import Foundation

/// Project roots this Mac's user removed from Projects, so cross-Mac project
/// sync never registers them again (another Mac that still has the project
/// reads this through `project.probe`'s `is_suppressed`). Adding the folder
/// again by hand clears it. Stored in this app's defaults domain.
public final class SupermuxProjectSyncSuppression: @unchecked Sendable {
    /// The defaults key holding the standardized roots.
    public static let defaultsKey = "supermux.devices.syncProjects.suppressedRoots.v1"
    /// Oldest entries are dropped past this many roots.
    public static let capacity = 256

    private let defaults: UserDefaults
    private let lock = NSLock()

    /// Creates the store over a defaults domain.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether sync must skip `rootPath`.
    public func isSuppressed(rootPath: String) -> Bool {
        lock.withLock { roots().contains(Self.key(rootPath)) }
    }

    /// Records that the user removed the project at `rootPath`.
    public func suppress(rootPath: String) {
        lock.withLock {
            var list = roots().filter { $0 != Self.key(rootPath) }
            list.append(Self.key(rootPath))
            defaults.set(Array(list.suffix(Self.capacity)), forKey: Self.defaultsKey)
        }
    }

    /// Forgets a suppression (the user registered the folder again).
    public func clear(rootPath: String) {
        lock.withLock {
            let list = roots()
            let next = list.filter { $0 != Self.key(rootPath) }
            guard next.count != list.count else { return }
            defaults.set(next, forKey: Self.defaultsKey)
        }
    }

    private func roots() -> [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    private static func key(_ rootPath: String) -> String {
        (rootPath as NSString).standardizingPath
    }
}
