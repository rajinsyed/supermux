// SUPERMUX:begin runtime-auth-rate-limit-regressions
import CMUXAuthCore
import Foundation
import StackAuth
import Testing
@testable import CmuxAuthRuntime

@MainActor
@Suite struct RuntimeAuthRateLimitRecoveryTests {
    @Test func teamTimeoutRetainsBackoffAndSuppressesActivationUntilRetry() async throws {
        let clock = RuntimeAuthRecoveryClock()
        let client = RuntimeAuthRecoveryClient(holdSecondTeamFetch: true)
        let coordinator = makeCoordinator(client: client, clock: clock)
        defer { coordinator.cancelTeamScopeRecovery() }
        await coordinator.checkExistingSession()
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.teamScopeRateLimit?.streak == 1)
        let firstWait = await clock.requests.waitForDeadline(after: .seconds(5))
        clock.base.advance(by: firstWait - clock.now.offset)
        await client.teamsStarted.waitUntilStarted()
        let timeoutAt = clock.now.offset + .seconds(5)
        await clock.requests.waitForExactDeadline(timeoutAt)
        clock.base.advance(by: .seconds(5))
        let nextWait = await clock.requests.waitForDeadline(after: timeoutAt)
        let pending = Array(coordinator.activeTokenTouchingPhases.values)
        await client.teamsRelease.release()
        for work in pending { await work.completion.value }

        #expect(coordinator.teamScopeRateLimit?.streak == 1)
        #expect(coordinator.teamScopeRateLimit?.retryAfter == .seconds(60))
        #expect(nextWait - timeoutAt >= .seconds(60))
        #expect(await client.counts() == [2, 2])
        clock.base.advance(by: .seconds(59))
        await coordinator.recoverTeamScopeIfNeeded()
        #expect(await client.counts() == [2, 2])
        #expect(coordinator.authenticatedTeamScope == nil)

        clock.base.advance(by: .seconds(31))
        for await scope in coordinator.authenticatedTeamScopes() where scope != nil { break }
        #expect(await client.counts() == [3, 3])
        #expect(coordinator.availableTeams.map(\.id) == ["team-1"])
        #expect(coordinator.teamScopeRateLimit == nil)
        #expect(await client.refreshToken() == "refresh")
    }

    @Test(arguments: RuntimeAuthTransientFailure.allCases)
    func transientFailuresRetainRateLimitAndActivationGate(failure: RuntimeAuthTransientFailure) async {
        let clock = RuntimeAuthRecoveryClock()
        let client = RuntimeAuthRecoveryClient()
        let coordinator = makeCoordinator(client: client, clock: clock)
        defer { coordinator.cancelTeamScopeRecovery() }
        await coordinator.checkExistingSession()
        coordinator.noteTeamScopeFailure(failure.error)
        await coordinator.recoverTeamScopeIfNeeded()
        #expect(coordinator.teamScopeRateLimit?.streak == 1)
        #expect(coordinator.teamScopeRecoveryWait(afterAttempt: 0) >= .seconds(60))
        #expect(await client.counts() == [1, 1])
    }

    @Test func tokenProbeDeadlinePreservesPriorRateLimit() async {
        let clock = RuntimeAuthRecoveryClock()
        let client = RuntimeAuthRecoveryClient()
        let coordinator = makeCoordinator(client: client, clock: clock)
        defer { coordinator.cancelTeamScopeRecovery() }
        await coordinator.checkExistingSession()
        await client.holdAccessProbe()
        let check = Task { await coordinator.checkExistingSession() }
        await client.accessStarted.waitUntilStarted()
        await clock.requests.waitForExactDeadline(.seconds(5))
        clock.base.advance(by: .seconds(5))
        await check.value
        await client.accessRelease.release()
        await coordinator.recoverTeamScopeIfNeeded()
        #expect(coordinator.teamScopeRateLimit?.streak == 1)
        #expect(await client.counts() == [1, 1])
        #expect(coordinator.isAuthenticated)
    }

    @Test func classifiedFailureClearsBackoffAndAllowsActivation() async {
        let clock = RuntimeAuthRecoveryClock()
        let client = FakeAuthClient(access: "access", refresh: "refresh", user: RuntimeAuthRecoveryClient.user)
        await client.setThrowOnListTeams(Self.rateLimit())
        let coordinator = makeCoordinator(client: client, clock: clock)
        defer { coordinator.cancelTeamScopeRecovery() }
        await coordinator.checkExistingSession()
        #expect(coordinator.teamScopeRateLimit != nil)
        coordinator.noteTeamScopeFailure(AuthError.serverError(503, "unavailable"))
        #expect(coordinator.teamScopeRateLimit == nil)
        await client.setThrowOnListTeams(nil)
        await client.setTeams([RuntimeAuthRecoveryClient.team])
        await coordinator.recoverTeamScopeIfNeeded()
        #expect(coordinator.authenticatedTeamScope?.teamID == "team-1")
    }

    @Test func repeatedRateLimitExtendsStreakAndExplicitCancellationClearsIt() async {
        let clock = RuntimeAuthRecoveryClock()
        let client = RuntimeAuthRecoveryClient()
        let coordinator = makeCoordinator(client: client, clock: clock)
        await coordinator.checkExistingSession()
        coordinator.noteTeamScopeFailure(Self.rateLimit())
        #expect(coordinator.teamScopeRateLimit?.streak == 2)
        coordinator.cancelTeamScopeRecovery()
        #expect(coordinator.teamScopeRateLimit == nil)
        #expect(!coordinator.hasPendingTeamScopeRecovery)
    }

    private func makeCoordinator(client: any AuthClient, clock: RuntimeAuthRecoveryClock) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        let sessionCache = CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens")
        let userCache = CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user")
        sessionCache.setHasTokens(true)
        try? userCache.save(RuntimeAuthRecoveryClient.user)
        return AuthCoordinator(
            client: client,
            sessionCache: sessionCache,
            userCache: userCache,
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            timeouts: AuthTimeouts(interactiveFlow: .seconds(5), network: .seconds(5), sessionRestore: .seconds(5)),
            clock: clock
        )
    }

    fileprivate static func rateLimit() -> StackAuthError {
        StackAuthError(code: "RATE_LIMITED", message: "Too many requests", details: [StackAuthError.retryAfterSecondsKey: 60.0])
    }
}

enum RuntimeAuthTransientFailure: CaseIterable, Sendable {
    case phaseTimeout, phaseCancellation, swiftCancellation, transportTimeout, transportCancellation

    var error: any Error {
        switch self {
        case .phaseTimeout: AuthError.timedOut
        case .phaseCancellation: AuthError.cancelled
        case .swiftCancellation: CancellationError()
        case .transportTimeout: URLError(.timedOut)
        case .transportCancellation: URLError(.cancelled)
        }
    }
}

private struct RuntimeAuthRecoveryClock: Clock {
    let base = ManualTestClock()
    let requests = RuntimeAuthSleepRequests()
    var now: ManualTestClock.Instant { base.now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: ManualTestClock.Instant, tolerance: Duration?) async throws {
        await requests.record(deadline.offset)
        try await base.sleep(until: deadline, tolerance: tolerance)
    }
}

private actor RuntimeAuthSleepRequests {
    private var deadlines: [Duration] = []
    private var waiters: [(matches: @Sendable (Duration) -> Bool, continuation: CheckedContinuation<Duration, Never>)] = []

    func record(_ deadline: Duration) {
        deadlines.append(deadline)
        waiters.removeAll { waiter in
            guard waiter.matches(deadline) else { return false }
            waiter.continuation.resume(returning: deadline)
            return true
        }
    }

    func waitForDeadline(after instant: Duration) async -> Duration {
        await wait { $0 > instant }
    }

    func waitForExactDeadline(_ instant: Duration) async {
        _ = await wait { $0 == instant }
    }

    private func wait(matching predicate: @escaping @Sendable (Duration) -> Bool) async -> Duration {
        if let deadline = deadlines.first(where: predicate) { return deadline }
        return await withCheckedContinuation { waiters.append((predicate, $0)) }
    }
}

private actor RuntimeAuthRecoveryClient: AuthClient {
    static let user = CMUXAuthUser(id: "u1", primaryEmail: "user@example.test", displayName: "User")
    static let team = CMUXAuthTeam(id: "team-1", displayName: "Team")
    let teamsStarted = TestPhaseSignal()
    let teamsRelease = TestContinuationBlocker()
    let accessStarted = TestPhaseSignal()
    let accessRelease = TestContinuationBlocker()
    private var userFetches = 0
    private var teamFetches = 0
    private var parkAccess = false
    private let holdSecondTeamFetch: Bool

    init(holdSecondTeamFetch: Bool = false) {
        self.holdSecondTeamFetch = holdSecondTeamFetch
    }

    func counts() -> [Int] { [userFetches, teamFetches] }
    func holdAccessProbe() { parkAccess = true }

    func accessToken() async -> String? {
        if parkAccess {
            parkAccess = false
            await accessStarted.markStarted()
            await accessRelease.wait()
        }
        return "access"
    }
    func refreshToken() async -> String? { "refresh" }
    func forceRefreshAccessToken() async -> String? { "access" }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        userFetches += 1
        return Self.user
    }
    func listTeams() async throws -> [CMUXAuthTeam] {
        teamFetches += 1
        if teamFetches == 1 {
            throw StackAuthError(code: "RATE_LIMITED", message: "Too many requests", details: [StackAuthError.retryAfterSecondsKey: 60.0])
        }
        if teamFetches == 2, holdSecondTeamFetch {
            await teamsStarted.markStarted()
            await teamsRelease.wait()
            try Task.checkCancellation()
        }
        return [Self.team]
    }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { "access" }
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}
// SUPERMUX:end runtime-auth-rate-limit-regressions
