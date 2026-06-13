import Foundation
import Testing
@testable import SupermuxKit

/// Behavior tests for the global terminal presets owned by
/// ``SupermuxProjectsModel``: first-run default seeding, honoring an explicitly
/// cleared list, in-memory CRUD, and persistence across a reload.
///
/// The model is `@MainActor`, so the suite is too. Each test uses a throwaway
/// on-disk store.
@MainActor
struct SupermuxPresetsModelTests {
    private func freshFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("projects.json")
    }

    private func makeModel(store: SupermuxProjectStore) -> SupermuxProjectsModel {
        SupermuxProjectsModel(store: store, worktreeService: SupermuxGitWorktreeService())
    }

    /// Polls the store until its persisted preset count matches `expected`, so
    /// the model's fire-and-forget persistence Task has a chance to flush.
    private func waitForPersistedPresetCount(
        _ store: SupermuxProjectStore,
        expected: Int
    ) async -> [SupermuxTerminalPreset]? {
        for _ in 0..<200 {
            let file = await store.load()
            if file.presets?.count == expected { return file.presets }
            await Task.yield()
        }
        return await store.load().presets
    }

    @Test func seedsDefaultsWhenDocumentHasNoPresets() async throws {
        let url = freshFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SupermuxProjectStore(fileURL: url)
        let model = makeModel(store: store)

        await model.loadIfNeeded()

        #expect(model.presets == SupermuxTerminalPreset.defaults)
        // The seed is written back so it is stable across launches.
        let persisted = await waitForPersistedPresetCount(store, expected: SupermuxTerminalPreset.defaults.count)
        #expect(persisted == SupermuxTerminalPreset.defaults)
    }

    @Test func honorsAnExplicitlyEmptyPresetList() async throws {
        let url = freshFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SupermuxProjectStore(fileURL: url)
        try await store.save(SupermuxProjectsFile(version: 2, projects: [], isSectionCollapsed: false, presets: []))
        let model = makeModel(store: store)

        await model.loadIfNeeded()

        #expect(model.presets.isEmpty)
    }

    @Test func loadsStoredPresetsVerbatim() async throws {
        let url = freshFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stored = [
            SupermuxTerminalPreset(name: "amp", command: "amp"),
            SupermuxTerminalPreset(name: "aider", command: "aider"),
        ]
        let store = SupermuxProjectStore(fileURL: url)
        try await store.save(SupermuxProjectsFile(version: 2, projects: [], isSectionCollapsed: false, presets: stored))
        let model = makeModel(store: store)

        await model.loadIfNeeded()

        #expect(model.presets == stored)
    }

    @Test func crudMutatesInMemoryList() async throws {
        let url = freshFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SupermuxProjectStore(fileURL: url)
        try await store.save(SupermuxProjectsFile(version: 2, projects: [], isSectionCollapsed: false, presets: []))
        let model = makeModel(store: store)
        await model.loadIfNeeded()

        let preset = SupermuxTerminalPreset(name: "claude", command: "claude")
        model.addPreset(preset)
        #expect(model.presets == [preset])

        var edited = preset
        edited.command = "claude --resume"
        model.updatePreset(edited)
        #expect(model.presets.first?.command == "claude --resume")

        model.addPreset(SupermuxTerminalPreset(name: "codex", command: "codex"))
        model.removePreset(id: preset.id)
        #expect(model.presets.map(\.name) == ["codex"])

        model.resetPresetsToDefaults()
        #expect(model.presets == SupermuxTerminalPreset.defaults)

        let replacement = [SupermuxTerminalPreset(name: "only", command: "only")]
        model.setPresets(replacement)
        #expect(model.presets == replacement)
    }

    @Test func presetsPersistAcrossReload() async throws {
        let url = freshFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SupermuxProjectStore(fileURL: url)
        let model = makeModel(store: store)
        await model.loadIfNeeded()

        let custom = [
            SupermuxTerminalPreset(name: "claude", command: "claude", iconSymbol: "sparkle", colorHex: "#f97316"),
            SupermuxTerminalPreset(name: "gemini", command: "gemini"),
        ]
        model.setPresets(custom)
        _ = await waitForPersistedPresetCount(store, expected: custom.count)

        // A fresh store + model on the same file must observe the saved presets.
        let reloadedStore = SupermuxProjectStore(fileURL: url)
        let reloaded = makeModel(store: reloadedStore)
        await reloaded.loadIfNeeded()
        #expect(reloaded.presets == custom)
    }
}
