import Foundation
import Observation
import SupermuxKit
import SupermuxMobileCore
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Logic-only coverage of ``SupermuxMobileRunObserver`` — the event half of
/// RPC-RUN-01: every run transition (start, stop) pokes
/// `supermux.run.updated` exactly once, and a no-op re-publish stays silent.
///
/// Modeled on `SupermuxMobileObserversTests`: the observer's snapshot reader
/// is injected with a fake `@Observable` source instead of the real
/// `SupermuxRunCoordinator.mobileRunSnapshots`, because the coordinator's
/// handle mutations require live terminal surfaces (documented seam — the
/// coordinator emits value snapshots; everything downstream consumes only
/// those). No Ghostty surfaces, no `Workspace`/`TabManager` construction,
/// no real config.
/// Stand-in for the run coordinator: an observable snapshot list the tests
/// mutate to simulate run transitions. File-scoped because the `@Observable`
/// macro's generated conformance extension cannot name a `private` nested
/// type.
@MainActor
@Observable
private final class FakeRunSource {
    var snapshots: [SupermuxMobileRunSnapshot] = []
}

@Suite(.serialized)
@MainActor
struct SupermuxMobileRunObserverTests {
    /// Captures every emitted topic (the observer is injected with
    /// ``record(topic:payload:)`` instead of the real MobileHostService sink).
    @MainActor
    private final class EmitRecorder {
        private(set) var topics: [String] = []
        func record(topic: String, payload: [String: Any]) {
            topics.append(topic)
        }
    }

    private struct TimedOut: Error {}

    /// Polls a main-actor condition until it holds or the deadline passes
    /// (the observer coalesces mutations behind an 80 ms trailing throttle).
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func sleepFixtureSnapshot() -> SupermuxMobileRunSnapshot {
        SupermuxMobileRunSnapshot(
            projectId: UUID(),
            workspaceId: UUID(),
            command: "sleep 60",
            startedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    // MARK: - RPC-RUN-01 (event emission on each transition)

    @Test func startAndStopTransitionsEachPokeRunUpdated() async throws {
        let source = FakeRunSource()
        let recorder = EmitRecorder()
        let observer = SupermuxMobileRunObserver(readSnapshots: { source.snapshots }) { topic, payload in
            recorder.record(topic: topic, payload: payload)
        }
        defer { _ = observer } // keep the observer alive across the awaits

        // Construction emits the initial snapshot unconditionally.
        #expect(recorder.topics == [SupermuxMobileTopic.runUpdated.rawValue])

        // run.start (a snapshot appears) → one throttled poke.
        source.snapshots = [sleepFixtureSnapshot()]
        try await waitUntil { recorder.topics.count == 2 }

        // run.stop (the snapshot disappears) → another poke.
        source.snapshots = []
        try await waitUntil { recorder.topics.count == 3 }

        #expect(recorder.topics.allSatisfy {
            $0 == SupermuxMobileTopic.runUpdated.rawValue
        })
    }

    @Test func identicalSnapshotRepublishDoesNotPoke() async throws {
        let source = FakeRunSource()
        let running = sleepFixtureSnapshot()
        source.snapshots = [running]
        let recorder = EmitRecorder()
        let observer = SupermuxMobileRunObserver(readSnapshots: { source.snapshots }) { topic, payload in
            recorder.record(topic: topic, payload: payload)
        }
        defer { _ = observer }
        #expect(recorder.topics.count == 1)

        // Re-assigning an equal value is a mutation for Observation but a
        // hash no-op, so no poke may fire — wait past the 80 ms throttle
        // window to prove silence rather than racing it.
        source.snapshots = [running]
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.topics.count == 1)
    }

    // MARK: - Authorization rows (run/launch/action methods are Mac-wide)

    @Test func runLaunchAndActionMethodsAreMacWide() {
        for method: SupermuxMobileMethod in [.runState, .runStart, .runStop, .presetLaunch, .actionRun] {
            #expect(
                SupermuxMobileAuthorization.scope(for: method) == .macWide,
                "\(method.rawValue) must require a Mac-wide ticket"
            )
        }
    }
}
