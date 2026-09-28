import Foundation
import Testing

import CmuxFoundation
import SupermuxKit

/// Ways resolving a project's `origin` URL (the cross-Mac repo identity) could fail:
/// 1. The trailing newline git prints leaks into the URL, so identities never match.
/// 2. A repo without an origin (git exits 1) or a non-repo yields a bogus URL instead of nil.
/// 3. Empty output becomes "" instead of nil.
/// 4. Every projects.list call re-runs git for every project (no cache).
/// 5. A definitive "no origin" answer is not cached, so it re-runs git forever.
/// 6. A transient failure (git missing, timed out, cancelled) is cached as "no origin" for good.
/// 7. Concurrent requests for one root spawn several git processes (actor reentrancy).
/// 8. Two spellings of one root (trailing slash, `..`) are cached separately.
/// 9. An origin changed on disk is never picked up (no invalidation / no expiry).
/// 10. The batch API keys results by a normalized path, so callers cannot look up by the
///     project's own `rootPath`, or it drops roots that have an origin.
/// 11. The command is not `git -C <root> config --get remote.origin.url` (e.g. `remote -v`
///     parsing, or it runs in the wrong directory).
struct SupermuxGitRemoteURLResolverTests {
    @Test func trimsGitOutputAndUsesTheOriginConfigCommand() async {
        let runner = ScriptedGitRunner(answers: ["/r/a": .origin("git@github.com:o/a.git\n")])
        let resolver = SupermuxGitRemoteURLResolver(runner: runner)
        #expect(await resolver.remoteURL(forRoot: "/r/a") == "git@github.com:o/a.git")
        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls.first?.directory == "/r/a")
        #expect(calls.first?.arguments == ["-C", "/r/a", "config", "--get", "remote.origin.url"])
    }

    @Test func noOriginNonRepoAndEmptyOutputAreNil() async {
        let runner = ScriptedGitRunner(answers: [
            "/r/no-origin": .exit(1),
            "/r/not-repo": .exit(128),
            "/r/empty": .origin("  \n"),
        ])
        let resolver = SupermuxGitRemoteURLResolver(runner: runner)
        #expect(await resolver.remoteURL(forRoot: "/r/no-origin") == nil)
        #expect(await resolver.remoteURL(forRoot: "/r/not-repo") == nil)
        #expect(await resolver.remoteURL(forRoot: "/r/empty") == nil)
    }

    @Test func definitiveAnswersAreCachedPerRoot() async {
        let runner = ScriptedGitRunner(answers: [
            "/r/a": .origin("https://github.com/o/a\n"),
            "/r/none": .exit(1),
        ])
        let resolver = SupermuxGitRemoteURLResolver(runner: runner)
        _ = await resolver.remoteURL(forRoot: "/r/a")
        _ = await resolver.remoteURL(forRoot: "/r/a")
        _ = await resolver.remoteURL(forRoot: "/r/none")
        _ = await resolver.remoteURL(forRoot: "/r/none")
        #expect(await runner.callCount(for: "/r/a") == 1)
        #expect(await runner.callCount(for: "/r/none") == 1)
    }

    @Test func transientFailuresAreRetried() async {
        let runner = ScriptedGitRunner(answers: ["/r/a": .launchFailure])
        let resolver = SupermuxGitRemoteURLResolver(runner: runner)
        #expect(await resolver.remoteURL(forRoot: "/r/a") == nil)
        await runner.setAnswer(.origin("https://github.com/o/a\n"), for: "/r/a")
        #expect(await resolver.remoteURL(forRoot: "/r/a") == "https://github.com/o/a")

        let timing = ScriptedGitRunner(answers: ["/r/t": .timedOut])
        let timingResolver = SupermuxGitRemoteURLResolver(runner: timing)
        _ = await timingResolver.remoteURL(forRoot: "/r/t")
        _ = await timingResolver.remoteURL(forRoot: "/r/t")
        #expect(await timing.callCount(for: "/r/t") == 2)
    }

    @Test func concurrentRequestsForOneRootShareOneGitRun() async {
        let runner = ScriptedGitRunner(answers: ["/r/a": .origin("https://github.com/o/a\n")], delay: .milliseconds(80))
        let resolver = SupermuxGitRemoteURLResolver(runner: runner)
        async let first = resolver.remoteURL(forRoot: "/r/a")
        async let second = resolver.remoteURL(forRoot: "/r/a")
        async let third = resolver.remoteURL(forRoot: "/r/a/")
        let results = await [first, second, third]
        #expect(results == Array(repeating: "https://github.com/o/a", count: 3))
        #expect(await runner.callCount(for: "/r/a") == 1)
    }

    @Test func rootSpellingsShareOneCacheEntry() async {
        let runner = ScriptedGitRunner(answers: ["/r/a": .origin("https://github.com/o/a\n")])
        let resolver = SupermuxGitRemoteURLResolver(runner: runner)
        #expect(await resolver.remoteURL(forRoot: "/r/a/") == "https://github.com/o/a")
        #expect(await resolver.remoteURL(forRoot: "/r/b/../a") == "https://github.com/o/a")
        #expect(await runner.callCount(for: "/r/a") == 1)
    }

    @Test func invalidationAndExpiryPickUpAChangedOrigin() async {
        let clock = TestClock()
        let runner = ScriptedGitRunner(answers: ["/r/a": .origin("https://github.com/o/a\n")])
        let resolver = SupermuxGitRemoteURLResolver(runner: runner, timeToLive: 60, now: { clock.now })
        #expect(await resolver.remoteURL(forRoot: "/r/a") == "https://github.com/o/a")

        await runner.setAnswer(.origin("https://github.com/o/renamed\n"), for: "/r/a")
        #expect(await resolver.remoteURL(forRoot: "/r/a") == "https://github.com/o/a", "still cached")
        await resolver.invalidate(root: "/r/a/")
        #expect(await resolver.remoteURL(forRoot: "/r/a") == "https://github.com/o/renamed")

        await runner.setAnswer(.origin("https://github.com/o/third\n"), for: "/r/a")
        clock.advance(by: 30)
        #expect(await resolver.remoteURL(forRoot: "/r/a") == "https://github.com/o/renamed")
        clock.advance(by: 31)
        #expect(await resolver.remoteURL(forRoot: "/r/a") == "https://github.com/o/third", "expired entries re-resolve")

        await runner.setAnswer(.origin("https://github.com/o/fourth\n"), for: "/r/a")
        await resolver.invalidateAll()
        #expect(await resolver.remoteURL(forRoot: "/r/a") == "https://github.com/o/fourth")
    }

    @Test func batchResultsAreKeyedByTheCallersRootSpelling() async {
        let runner = ScriptedGitRunner(answers: [
            "/r/a": .origin("https://github.com/o/a\n"),
            "/r/none": .exit(1),
        ])
        let resolver = SupermuxGitRemoteURLResolver(runner: runner)
        let urls = await resolver.remoteURLs(forRoots: ["/r/a/", "/r/none", "/r/a/"])
        #expect(urls == ["/r/a/": "https://github.com/o/a"])
    }
}

/// A `CommandRunning` fake answering `git config --get remote.origin.url` per directory.
private actor ScriptedGitRunner: CommandRunning {
    enum Answer: Sendable {
        case origin(String)
        case exit(Int32)
        case launchFailure
        case timedOut
    }

    struct Call: Sendable {
        let directory: String
        let arguments: [String]
    }

    private var answers: [String: Answer]
    private let delay: Duration?
    private(set) var calls: [Call] = []

    init(answers: [String: Answer], delay: Duration? = nil) {
        self.answers = answers
        self.delay = delay
    }

    func setAnswer(_ answer: Answer, for directory: String) {
        answers[directory] = answer
    }

    func callCount(for directory: String) -> Int {
        calls.filter { $0.directory == directory }.count
    }

    func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
        calls.append(Call(directory: directory, arguments: arguments))
        if let delay { try? await Task.sleep(for: delay) }
        switch answers[directory] ?? .exit(128) {
        case .origin(let output):
            return CommandResult(stdout: output, stderr: nil, exitStatus: 0, timedOut: false, executionError: nil)
        case .exit(let status):
            return CommandResult(stdout: "", stderr: "fatal", exitStatus: status, timedOut: false, executionError: nil)
        case .launchFailure:
            return CommandResult(stdout: nil, stderr: nil, exitStatus: nil, timedOut: false, executionError: "git not found")
        case .timedOut:
            return CommandResult(stdout: nil, stderr: nil, exitStatus: nil, timedOut: true, executionError: nil)
        }
    }
}

/// A manually advanced clock shared with the resolver's `now` closure.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current.addTimeInterval(seconds) }
    }
}
