import Foundation
import Testing
@testable import SupermuxKit

/// Rebuilding this Mac's main endpoint after a long sleep (review finding
/// T1). Relay credentials last 30 min and the endpoint needs a live one to
/// bind, so after a night they have always expired; the rebuild was skipped
/// as `kept-expired-credentials` and never ran when it mattered most.
///
/// Ways it could get it wrong, written before the fix:
/// 1. Expired credentials skip the rebuild without asking the control plane
///    for fresh ones.
/// 2. A refresh that fails while the network is still coming back (right
///    after a wake) is not tried again inside the wait limit.
/// 3. A refresh that hangs holds dials past the wait limit.
/// 4. The endpoint is closed although no fresh credential came, so it cannot
///    bind again and every phone and Mac waits for the next credential.
/// 5. A refresh or a rebuild runs with no endpoint to rebuild.
/// 6. Usable credentials are refreshed anyway (a backend round trip for nothing).
struct SupermuxMainEndpointRebuildTests {
    typealias Rebuild = SupermuxMainEndpointRebuild

    /// A fake runtime: an endpoint, credentials that turn usable after the
    /// refreshes that `refreshWorksOn` names (1-based), and a record of calls.
    final class Runtime: @unchecked Sendable {
        private let lock = NSLock()
        private var usable: Bool
        private var refreshes = 0
        private var rebuilds = 0
        private let refreshWorksOn: Int?
        private let refreshHangs: Bool
        let hasEndpoint: Bool

        init(usable: Bool, refreshWorksOn: Int? = nil, refreshHangs: Bool = false, hasEndpoint: Bool = true) {
            self.usable = usable
            self.refreshWorksOn = refreshWorksOn
            self.refreshHangs = refreshHangs
            self.hasEndpoint = hasEndpoint
        }

        var refreshCount: Int { lock.withLock { refreshes } }
        var rebuildCount: Int { lock.withLock { rebuilds } }

        var steps: Rebuild.Steps {
            Rebuild.Steps(
                hasEndpoint: { self.hasEndpoint },
                credentialsUsable: { self.lock.withLock { self.usable } },
                refreshCredentials: {
                    if self.refreshHangs { try await Task.sleep(for: .seconds(3_600)) }
                    let attempt = self.lock.withLock { () -> Int in
                        self.refreshes += 1
                        return self.refreshes
                    }
                    guard let works = self.refreshWorksOn, attempt >= works else { throw URLError(.notConnectedToInternet) }
                    self.lock.withLock { self.usable = true }
                },
                rebuild: { self.lock.withLock { self.rebuilds += 1 } })
        }
    }

    private let limit: Duration = .milliseconds(400)
    private let retry: Duration = .milliseconds(20)

    @Test("6. usable credentials: rebuilt at once, no refresh")
    func usableCredentialsRebuildAtOnce() async {
        let runtime = Runtime(usable: true)
        #expect(await Rebuild.run(runtime.steps, limit: limit, retryDelay: retry) == .rebuilt)
        #expect(runtime.refreshCount == 0 && runtime.rebuildCount == 1)
    }

    @Test("1. expired credentials: refreshed, then rebuilt")
    func expiredCredentialsAreRefreshed() async {
        let runtime = Runtime(usable: false, refreshWorksOn: 1)
        #expect(await Rebuild.run(runtime.steps, limit: limit, retryDelay: retry) == .rebuiltAfterRefresh)
        #expect(runtime.refreshCount == 1 && runtime.rebuildCount == 1)
    }

    @Test("2. a refresh that fails while the network comes back is tried again inside the limit")
    func refreshIsRetried() async {
        let runtime = Runtime(usable: false, refreshWorksOn: 3)
        #expect(await Rebuild.run(runtime.steps, limit: limit, retryDelay: retry) == .rebuiltAfterRefresh)
        #expect(runtime.refreshCount == 3 && runtime.rebuildCount == 1)
    }

    @Test("3 and 4. no fresh credential within the limit: kept, never closed, and back within the limit")
    func noCredentialKeepsTheEndpoint() async {
        for runtime in [Runtime(usable: false), Runtime(usable: false, refreshHangs: true)] {
            let started = ContinuousClock.now
            #expect(await Rebuild.run(runtime.steps, limit: limit, retryDelay: retry) == .keptExpiredCredentials)
            let elapsed = started.duration(to: .now)
            #expect(runtime.rebuildCount == 0)
            #expect(elapsed >= limit - .milliseconds(50) && elapsed < limit + .milliseconds(300), "\(elapsed)")
        }
    }

    @Test("5. no endpoint: nothing refreshed or rebuilt")
    func noEndpoint() async {
        let runtime = Runtime(usable: false, refreshWorksOn: 1, hasEndpoint: false)
        #expect(await Rebuild.run(runtime.steps, limit: limit, retryDelay: retry) == .noEndpoint)
        #expect(runtime.refreshCount == 0 && runtime.rebuildCount == 0)
    }
}
