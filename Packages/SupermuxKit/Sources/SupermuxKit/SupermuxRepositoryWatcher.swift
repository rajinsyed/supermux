public import Foundation
import CoreServices

/// Watches a directory subtree for file-system changes and yields a debounced
/// change signal as an `AsyncStream`.
///
/// This is the change source for the git Changes panel: instead of polling git
/// on a timer, the model iterates ``changes()`` and refreshes only when the
/// working tree (or `.git`) actually changes. Backed by FSEvents, which
/// coalesces bursts within its latency window into a single callback, so edits,
/// stages, and commits surface promptly without a busy loop.
///
/// ```swift
/// let watcher = SupermuxRepositoryWatcher(path: repoRoot)
/// for await _ in watcher.changes() {
///     await model.refresh()
/// }
/// ```
public final class SupermuxRepositoryWatcher: Sendable {
    /// FSEvents filters at most this many directories; past it, none apply.
    static let maxExcludedPaths = 8
    /// Git bookkeeping directories under a repository root whose writes never
    /// change the root's status: other worktrees' admin dirs (their index and
    /// `HEAD`), object writes and reflogs. Excluded in the kernel, so they do
    /// not even wake this process; ``isGitNoise(path:)`` still drops them if
    /// the exclusion could not be applied.
    static let gitBookkeepingSubpaths = [".git/worktrees", ".git/objects", ".git/logs"]

    private let path: String
    private let excludedPaths: [String]
    private let latency: TimeInterval

    /// Creates a watcher for a directory subtree.
    /// - Parameters:
    ///   - path: Absolute path of the directory to watch recursively.
    ///   - excludedPaths: Directories under `path` whose changes never matter
    ///     here (a project root's container of nested worktrees). Added to
    ///     ``gitBookkeepingSubpaths``; a path that is missing, not a directory
    ///     or not strictly inside `path` is ignored.
    ///   - latency: FSEvents coalescing window in seconds; bursts within it
    ///     collapse to one event. Defaults to `0.3`.
    public init(path: String, excludedPaths: [String] = [], latency: TimeInterval = 0.3) {
        self.path = path
        self.excludedPaths = excludedPaths
        self.latency = latency
    }

    /// An `AsyncStream` that yields once per coalesced batch of file-system
    /// changes under the watched path.
    ///
    /// The FSEvents stream starts eagerly when this method returns (callers
    /// rely on that: creating the stream *before* an initial refresh means a
    /// change landing during the refresh is buffered, not dropped) and tears
    /// down when the consumer's task is cancelled or the stream is finished.
    /// `bufferingNewest(1)` keeps exactly one pending signal while the consumer
    /// is busy refreshing, so a burst of batches drains as a single catch-up
    /// instead of a queue of redundant back-to-back refreshes.
    public func changes() -> AsyncStream<Void> {
        let path = self.path
        let latency = self.latency
        let exclusions = Self.exclusionPaths(watching: path, extra: excludedPaths)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let session = WatchSession(path: path, exclusions: exclusions, latency: latency) {
                continuation.yield(())
            }
            guard session.start() else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in
                session.stop()
            }
        }
    }

    /// Whether a coalesced FSEvents batch warrants a refresh: batches made up
    /// entirely of git's own bookkeeping noise are dropped, because the
    /// spawned `git status`/`fetch` behind every refresh writes exactly that
    /// noise and would otherwise re-trigger the watcher forever
    /// (`kFSEventStreamCreateFlagIgnoreSelf` cannot help — the writes come
    /// from child git processes, not this process). Real state changes —
    /// index, `HEAD`, refs, `packed-refs` — always pass through so external
    /// git commands still refresh the panel. An empty batch (defensive) is
    /// delivered.
    static func shouldDeliver(eventPaths: [String]) -> Bool {
        guard !eventPaths.isEmpty else { return true }
        return !eventPaths.allSatisfy(isGitNoise(path:))
    }

    /// Git bookkeeping noise: lock files, loose/packed object writes, reflogs,
    /// other worktrees' admin dirs, and `FETCH_HEAD` under `.git`. None of
    /// them change what the status snapshot or the ahead/behind counts show.
    static func isGitNoise(path: String) -> Bool {
        guard path.contains("/.git/") else { return false }
        return path.hasSuffix(".lock")
            || path.contains("/objects/")
            || path.hasSuffix("FETCH_HEAD")
            || path.contains("/logs/")
            || path.contains("/.git/worktrees/")
    }

    /// The directories FSEvents should filter out of a watch on `path`: the
    /// caller's `extra` paths first, then ``gitBookkeepingSubpaths``, each in
    /// its symlink-resolved form (FSEvents matches against canonical paths)
    /// and kept only when it is an existing directory strictly inside `path`,
    /// so a stray entry can never filter the watched tree itself. Capped at
    /// ``maxExcludedPaths``, past which FSEvents would apply none.
    static func exclusionPaths(watching path: String, extra: [String]) -> [String] {
        guard let root = resolvedPath(path) else { return [] }
        let candidates = extra + gitBookkeepingSubpaths.map { (path as NSString).appendingPathComponent($0) }
        var exclusions: [String] = []
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard let resolved = resolvedPath(candidate),
                  resolved.hasPrefix(root + "/"),
                  FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !exclusions.contains(resolved)
            else { continue }
            exclusions.append(resolved)
        }
        return Array(exclusions.prefix(maxExcludedPaths))
    }

    /// `realpath(3)`: the canonical path FSEvents reports events under (it
    /// resolves the watched path the same way), or `nil` when it is missing.
    private static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Owns one FSEventStream and forwards its callbacks to a yield closure.
///
/// A reference type so the `@convention(c)` FSEvents callback can recover it
/// through the stream's `info` context pointer. The session's lifetime is held
/// by the owning `AsyncStream` continuation's `onTermination` closure, so the
/// `info` pointer is unretained — no manual retain/release bookkeeping is
/// needed, and no callback fires after `stop()` because callbacks and `stop()`
/// are serialized on the same dispatch queue.
private final class WatchSession: @unchecked Sendable {
    private let path: String
    private let exclusions: [String]
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.supermux.repository-watcher")
    private var stream: FSEventStreamRef?

    init(path: String, exclusions: [String], latency: TimeInterval, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.exclusions = exclusions
        self.latency = latency
        self.onChange = onChange
    }

    func start() -> Bool {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // UseCFTypes makes the callback's eventPaths a CFArray of CFString,
        // so the .git-noise filter can inspect the batch's paths.
        // Deliberately NO kFSEventStreamCreateFlagIgnoreSelf: the app itself
        // mutates the worktree in-process (file-explorer create/rename/
        // duplicate/trash via FileManager), and those changes must refresh the
        // Changes panel too. The refresh loop that flag appeared to prevent
        // comes from child git processes it never covered anyway — the
        // .git-noise filter plus `--no-optional-locks` handles that.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return false
        }
        self.stream = stream
        // Must precede the start. A refusal is harmless: the callback's
        // .git-noise filter still drops the bookkeeping batches.
        if !exclusions.isEmpty {
            _ = FSEventStreamSetExclusionPaths(stream, exclusions as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return false
        }
        return true
    }

    func stop() {
        queue.async { [self] in
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
        guard let info else { return }
        let session = Unmanaged<WatchSession>.fromOpaque(info).takeUnretainedValue()
        // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray of
        // CFString (unretained here; the stream owns it for the callback).
        let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
        guard SupermuxRepositoryWatcher.shouldDeliver(eventPaths: paths) else { return }
        session.onChange()
    }
}
