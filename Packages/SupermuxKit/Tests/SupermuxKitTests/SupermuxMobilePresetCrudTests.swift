import Foundation
import Testing
@testable import SupermuxKit

/// CRUD tests for the mobile terminal-preset write flow (the preset-CRUD half
/// of validation contract RPC-PRE-01), driven through the exact package types
/// and ``SupermuxProjectsModel`` calls the `mobile.supermux.preset.*` handlers
/// use. Persistence is verified against the projects file on disk, decoded
/// from raw bytes. The launch half (preset.launch / action.run) is a later
/// feature and deliberately absent here.
@MainActor
struct SupermuxMobilePresetCrudTests {
    private func makeTempDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-mobile-preset-crud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// A loaded model whose on-disk document carries exactly `presets`
    /// (explicit, so the first-run default seeding never muddies assertions).
    private func makeLoadedModel(
        storeDir: String,
        presets: [SupermuxTerminalPreset]
    ) async throws -> (model: SupermuxProjectsModel, fileURL: URL) {
        let fileURL = URL(fileURLWithPath: storeDir).appendingPathComponent("projects.json")
        let store = SupermuxProjectStore(fileURL: fileURL)
        try await store.save(SupermuxProjectsFile(
            version: SupermuxProjectsFile.currentVersion,
            projects: [],
            isSectionCollapsed: false,
            presets: presets
        ))
        let model = SupermuxProjectsModel(store: store, worktreeService: SupermuxGitWorktreeService())
        await model.loadIfNeeded()
        return (model, fileURL)
    }

    private func decodeDiskFile(_ url: URL) -> SupermuxProjectsFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SupermuxProjectsFile.self, from: data)
    }

    private func waitForDisk(
        _ url: URL,
        until predicate: (SupermuxProjectsFile) -> Bool
    ) async -> SupermuxProjectsFile? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let file = decodeDiskFile(url), predicate(file) { return file }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return decodeDiskFile(url)
    }

    // MARK: - RPC-PRE-01 (CRUD half)

    @Test func createParsesWireParamsAndPersists() async throws {
        let storeDir = try makeTempDirectory()
        defer { cleanUp(storeDir) }
        let (model, fileURL) = try await makeLoadedModel(storeDir: storeDir, presets: [])

        // The exact parse + model call `mobile.supermux.preset.create` makes.
        let preset = try SupermuxMobilePresetPatch.createPreset(fromWire: [
            "name": "amp",
            "command": "amp --dangerously-allow-all",
            "icon_symbol": "bolt",
            "color_hex": "#22c55e",
        ])
        model.addPreset(preset)

        #expect(preset.name == "amp")
        #expect(preset.command == "amp --dangerously-allow-all")
        #expect(preset.iconSymbol == "bolt")
        #expect(preset.colorHex == "#22c55e")
        #expect(model.presets == [preset])

        let disk = await waitForDisk(fileURL) { $0.presets?.contains(preset) == true }
        #expect(disk?.presets == [preset])
    }

    @Test func createRejectsBlankNameOrCommand() {
        func createError(_ wire: [String: Any]) -> SupermuxMobilePatchError? {
            do {
                _ = try SupermuxMobilePresetPatch.createPreset(fromWire: wire)
                return nil
            } catch let error as SupermuxMobilePatchError {
                return error
            } catch {
                return nil
            }
        }
        #expect(createError(["command": "amp"]) == .missingKey("name"))
        #expect(createError(["name": "  ", "command": "amp"]) == .emptyValue(key: "name"))
        #expect(createError(["name": "amp"]) == .missingKey("command"))
        #expect(createError(["name": "amp", "command": ""]) == .emptyValue(key: "command"))
        #expect(createError(["name": "amp", "command": "amp", "icon_symbol": 7]) == .invalidValue(key: "icon_symbol"))
    }

    @Test func updateAppliesOnlyPresentKeysAndPersists() async throws {
        let storeDir = try makeTempDirectory()
        defer { cleanUp(storeDir) }
        let seeded = SupermuxTerminalPreset(
            name: "claude",
            command: "claude",
            iconSymbol: "sparkle",
            colorHex: "#f97316"
        )
        let bystander = SupermuxTerminalPreset(name: "codex", command: "codex")
        let (model, fileURL) = try await makeLoadedModel(storeDir: storeDir, presets: [seeded, bystander])

        // The exact parse + apply + model call `mobile.supermux.preset.update`
        // makes: present keys applied, `color_hex: null` clears, the rest stays.
        let patch = try SupermuxMobilePresetPatch(wire: [
            "command": "claude --resume",
            "color_hex": NSNull(),
        ])
        let updated = patch.applied(to: seeded)
        model.updatePreset(updated)

        #expect(updated.id == seeded.id)
        #expect(updated.name == "claude")
        #expect(updated.command == "claude --resume")
        #expect(updated.iconSymbol == "sparkle")
        #expect(updated.colorHex == nil)
        #expect(model.presets == [updated, bystander])

        let disk = await waitForDisk(fileURL) { $0.presets?.first?.command == "claude --resume" }
        #expect(disk?.presets == [updated, bystander])
    }

    @Test func updatePatchRejectsUnknownAndImmutableKeys() {
        func parseError(_ wire: [String: Any]) -> SupermuxMobilePatchError? {
            do {
                _ = try SupermuxMobilePresetPatch(wire: wire)
                return nil
            } catch let error as SupermuxMobilePatchError {
                return error
            } catch {
                return nil
            }
        }
        #expect(parseError(["id": UUID().uuidString]) == .immutableKey("id"))
        #expect(parseError(["preset_id": UUID().uuidString]) == .immutableKey("preset_id"))
        #expect(parseError(["future_key": true]) == .unknownKey("future_key"))
        #expect(parseError(["name": ""]) == .emptyValue(key: "name"))
        #expect(parseError(["command": NSNull()]) == .invalidValue(key: "command"))
    }

    @Test func deleteRemovesThePresetFromDisk() async throws {
        let storeDir = try makeTempDirectory()
        defer { cleanUp(storeDir) }
        let doomed = SupermuxTerminalPreset(name: "droid", command: "droid")
        let survivor = SupermuxTerminalPreset(name: "gemini", command: "gemini")
        let (model, fileURL) = try await makeLoadedModel(storeDir: storeDir, presets: [doomed, survivor])

        // The exact model call `mobile.supermux.preset.delete` makes.
        model.removePreset(id: doomed.id)

        #expect(model.presets == [survivor])
        let disk = await waitForDisk(fileURL) { $0.presets?.contains(doomed) == false }
        #expect(disk?.presets == [survivor])
    }
}
