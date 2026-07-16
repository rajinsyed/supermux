import Foundation
import SupermuxKit
import SupermuxMobileCore
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Logic-only coverage of ``SupermuxMobileProjectsObserver``'s preset
/// visibility contract (m2-f5): the observer's summary hash watches
/// `SupermuxProjectsModel.presets`, so every preset write — add, update,
/// remove, whether it came from the phone's `mobile.supermux.preset.*`
/// handlers or the desktop editor sheet — pokes `supermux.projects.updated`
/// and the phone refetches the presets now carried by `projects.list`.
///
/// Modeled on `SupermuxMobileAuthorizationTests`: pure model + injected emit
/// sink — no Ghostty surfaces, no `Workspace`/`TabManager` construction, no
/// real config (the projects file lives in a per-test temp directory).
@Suite(.serialized)
@MainActor
struct SupermuxMobileObserversTests {
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

    /// A loaded model backed by a fresh temp projects file.
    private func makeLoadedModel(tempDir: URL) async -> SupermuxProjectsModel {
        let model = SupermuxProjectsModel(
            store: SupermuxProjectStore(fileURL: tempDir.appendingPathComponent("projects.json")),
            worktreeService: SupermuxGitWorktreeService()
        )
        await model.loadIfNeeded()
        return model
    }

    @Test func presetMutationsEachPokeProjectsUpdated() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-mobile-observer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = await makeLoadedModel(tempDir: tempDir)
        let recorder = EmitRecorder()
        let observer = SupermuxMobileProjectsObserver(model: model) { topic, payload in
            recorder.record(topic: topic, payload: payload)
        }
        defer { _ = observer } // keep the observer alive across the awaits

        // Construction emits the initial snapshot unconditionally.
        #expect(recorder.topics == [SupermuxMobileTopic.projectsUpdated.rawValue])

        // add → one throttled poke.
        let preset = SupermuxTerminalPreset(name: "claude", command: "claude")
        model.addPreset(preset)
        try await waitUntil { recorder.topics.count == 2 }

        // update → another poke.
        var renamed = preset
        renamed.command = "claude --resume"
        model.updatePreset(renamed)
        try await waitUntil { recorder.topics.count == 3 }

        // remove → another poke.
        model.removePreset(id: preset.id)
        try await waitUntil { recorder.topics.count == 4 }

        #expect(recorder.topics.allSatisfy {
            $0 == SupermuxMobileTopic.projectsUpdated.rawValue
        })
    }

    @Test func noOpPresetUpdateDoesNotPoke() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-mobile-observer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = await makeLoadedModel(tempDir: tempDir)
        let recorder = EmitRecorder()
        let observer = SupermuxMobileProjectsObserver(model: model) { topic, payload in
            recorder.record(topic: topic, payload: payload)
        }
        defer { _ = observer }
        #expect(recorder.topics.count == 1)

        // Updating a preset the model does not contain is a model no-op, so
        // the summary hash is unchanged and no poke may fire — wait past the
        // 80 ms throttle window to prove silence rather than racing it.
        model.updatePreset(SupermuxTerminalPreset(name: "ghost", command: "true"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.topics.count == 1)
    }
}
