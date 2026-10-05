import Foundation

/// Closing this Mac's main iroh endpoint and binding it again after a long
/// sleep (``SupermuxWakePolicy``), with a relay credential it can bind with.
///
/// A relay endpoint needs a live credential to bind, and credentials last
/// 30 min: after a night they have always expired. So expired credentials
/// are refreshed first, tried again every `retryDelay` while the network
/// comes back after the wake, all within `limit` (how long dials wait for
/// the rebuild). The endpoint is closed only once a usable credential is in
/// hand; without one it is kept, and the owner may run the rebuild later
/// (``SupermuxWakePolicy/rebuildPostponed(at:)``).
public enum SupermuxMainEndpointRebuild {
    /// What a run did, as the power journal's `main` field shows it.
    public enum Outcome: String, Equatable, Sendable {
        case rebuilt
        /// The credentials had expired; fresh ones came in time.
        case rebuiltAfterRefresh = "rebuilt-after-refresh"
        case noEndpoint = "no-endpoint"
        /// No usable credential within the limit: the endpoint was kept.
        case keptExpiredCredentials = "kept-expired-credentials"
    }

    /// The runtime it works on.
    public struct Steps: Sendable {
        /// Whether a main endpoint is bound.
        public var hasEndpoint: @Sendable () async -> Bool
        /// Whether a relay credential (or relay-less mode) lets it bind now.
        public var credentialsUsable: @Sendable () async -> Bool
        /// Asks the control plane for fresh credentials.
        public var refreshCredentials: @Sendable () async throws -> Void
        /// Closes the endpoint and binds the next one.
        public var rebuild: @Sendable () async -> Void

        public init(
            hasEndpoint: @escaping @Sendable () async -> Bool,
            credentialsUsable: @escaping @Sendable () async -> Bool,
            refreshCredentials: @escaping @Sendable () async throws -> Void,
            rebuild: @escaping @Sendable () async -> Void
        ) {
            self.hasEndpoint = hasEndpoint
            self.credentialsUsable = credentialsUsable
            self.refreshCredentials = refreshCredentials
            self.rebuild = rebuild
        }
    }

    /// Runs one rebuild; returns within about `limit` whatever the refresh does.
    public static func run(_ steps: Steps, limit: Duration, retryDelay: Duration = .milliseconds(500)) async -> Outcome {
        guard await steps.hasEndpoint() else { return .noEndpoint }
        if await steps.credentialsUsable() {
            await steps.rebuild()
            return .rebuilt
        }
        guard await refreshed(steps, limit: limit, retryDelay: retryDelay) else { return .keptExpiredCredentials }
        await steps.rebuild()
        return .rebuiltAfterRefresh
    }

    /// Refreshes until a credential is usable or `limit` passes; a refresh
    /// that hangs is left behind at the limit.
    private static func refreshed(_ steps: Steps, limit: Duration, retryDelay: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        let attempts = Task {
            while !Task.isCancelled {
                if (try? await steps.refreshCredentials()) != nil, await steps.credentialsUsable() { return true }
                guard ContinuousClock.now + retryDelay < deadline,
                      (try? await Task.sleep(for: retryDelay)) != nil else { return false }
            }
            return false
        }
        let refreshed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = SupermuxResumeOnce(continuation)
            Task { once.resume(await attempts.value) }
            Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                once.resume(false)
            }
        }
        attempts.cancel()
        return refreshed
    }
}

/// Resumes a continuation with the first value it is given.
private final class SupermuxResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
