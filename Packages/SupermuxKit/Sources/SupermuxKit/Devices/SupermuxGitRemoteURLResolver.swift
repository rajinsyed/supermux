public import CmuxFoundation
public import Foundation

/// Resolves a project root's `origin` URL — the identity two Macs share for
/// their own copies of one repository — with `git -C <root> config --get
/// remote.origin.url`, off the main actor.
///
/// Answers are cached per standardized root for `timeToLive` (so a changed
/// origin is picked up eventually, and immediately after ``invalidate(root:)``).
/// A definitive "no origin" is cached like a URL; a transient failure (git
/// missing, timed out, cancelled) is not. Concurrent requests for one root
/// share a single git run.
///
/// ```swift
/// let resolver = SupermuxGitRemoteURLResolver()
/// let url = await resolver.remoteURL(forRoot: project.rootPath)
/// ```
public actor SupermuxGitRemoteURLResolver {
    /// How long a resolved answer is reused before git is asked again.
    public static let defaultTimeToLive: TimeInterval = 600

    private struct Entry {
        let url: String?
        let resolvedAt: Date
    }

    private enum Resolution: Sendable {
        case definitive(String?)
        case transient

        var url: String? {
            if case .definitive(let url) = self { return url }
            return nil
        }
    }

    private struct Flight {
        let id: UUID
        let task: Task<Resolution, Never>
    }

    private let runner: any CommandRunning
    private let timeout: TimeInterval
    private let timeToLive: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Flight] = [:]

    /// Creates a resolver.
    /// - Parameters:
    ///   - runner: Runs git; tests inject a fake.
    ///   - timeout: Per-invocation git deadline in seconds.
    ///   - timeToLive: How long an answer stays cached.
    ///   - now: The clock used for expiry.
    public init(
        runner: any CommandRunning = CommandRunner(),
        timeout: TimeInterval = 5,
        timeToLive: TimeInterval = SupermuxGitRemoteURLResolver.defaultTimeToLive,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.timeout = timeout
        self.timeToLive = timeToLive
        self.now = now
    }

    /// The `origin` URL of the repository at `root`, or `nil` when it is not
    /// a git repository, has no origin, or git could not be run.
    public func remoteURL(forRoot root: String) async -> String? {
        let key = Self.normalizedRoot(root)
        if let entry = cache[key], now().timeIntervalSince(entry.resolvedAt) < timeToLive {
            return entry.url
        }
        if let flight = inFlight[key] {
            return await flight.task.value.url
        }
        let runner = self.runner
        let timeout = self.timeout
        let flight = Flight(id: UUID(), task: Task {
            await Self.resolve(root: key, runner: runner, timeout: timeout)
        })
        inFlight[key] = flight
        let resolution = await flight.task.value
        if inFlight[key]?.id == flight.id {
            inFlight[key] = nil
            if case .definitive(let url) = resolution {
                cache[key] = Entry(url: url, resolvedAt: now())
            }
        }
        return resolution.url
    }

    /// Origins for several roots, keyed by each root exactly as passed; roots
    /// without an origin are absent.
    public func remoteURLs(forRoots roots: [String]) async -> [String: String] {
        let unique = Array(Set(roots))
        return await withTaskGroup(of: (String, String?).self) { group in
            for root in unique {
                group.addTask { (root, await self.remoteURL(forRoot: root)) }
            }
            var urls: [String: String] = [:]
            for await (root, url) in group {
                if let url { urls[root] = url }
            }
            return urls
        }
    }

    /// Forgets one root's answer; the next request asks git again.
    public func invalidate(root: String) {
        let key = Self.normalizedRoot(root)
        cache[key] = nil
        inFlight[key] = nil
    }

    /// Forgets every answer.
    public func invalidateAll() {
        cache.removeAll()
        inFlight.removeAll()
    }

    private static func normalizedRoot(_ root: String) -> String {
        let expanded = (root as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardized.path
    }

    private static func resolve(root: String, runner: any CommandRunning, timeout: TimeInterval) async -> Resolution {
        let result = await runner.run(
            directory: root,
            executable: "git",
            arguments: ["-C", root, "config", "--get", "remote.origin.url"],
            timeout: timeout
        )
        guard result.executionError == nil, !result.timedOut else { return .transient }
        guard result.exitStatus == 0 else { return .definitive(nil) }
        let url = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .definitive(url.isEmpty ? nil : url)
    }
}
