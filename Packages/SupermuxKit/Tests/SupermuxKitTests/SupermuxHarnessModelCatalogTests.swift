import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized)
struct SupermuxHarnessModelCatalogTests {
    @Test func initializeCatalogExtractsModelsAndNamedCapabilities() throws {
        let response = try SupermuxHarnessJSONObject(rawValue: [
            "models": [
                [
                    "value": "claude-sonnet-5",
                    "displayName": "Claude Sonnet 5",
                    "supportsEffort": true,
                ],
                [
                    "value": "claude-opus-5",
                    "displayName": "Claude Opus 5",
                    "supportsEffort": true,
                ],
            ],
            "agents": ["Explore", ["name": "Plan"], ["id": "ignored"]],
            "available_output_styles": ["default", ["name": "concise"]],
            "commands": [
                ["name": "compact", "description": "Compact context"],
                ["name": "clear"],
                ["description": "missing name"],
            ],
        ])

        let catalog = SupermuxHarnessInitializeCatalog(response: response)

        #expect(catalog.models.compactMap { $0.string(forKey: "value") } == [
            "claude-sonnet-5",
            "claude-opus-5",
        ])
        #expect(catalog.agents == ["Explore", "Plan"])
        #expect(catalog.availableOutputStyles == ["default", "concise"])
        #expect(catalog.commandNames == ["compact", "clear"])
    }

    @Test func catalogPersistsPerBinaryPathAndInvalidatesWithoutTouchingOtherDefaults() throws {
        let suiteName = "SupermuxHarnessModelCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("keep", forKey: "unrelated")
        let store = SupermuxHarnessModelCatalogStore(defaults: defaults)
        let firstModels = [try model(value: "claude-sonnet-5")]
        let secondModels = [try model(value: "claude-opus-5")]
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(60)

        try store.store(firstModels, forBinaryPath: "/opt/claude-a", storedAt: firstDate)
        try store.store(secondModels, forBinaryPath: "/opt/claude-b", storedAt: secondDate)

        let first = try #require(store.snapshot(forBinaryPath: "/opt/claude-a"))
        let second = try #require(store.snapshot(forBinaryPath: "/opt/claude-b"))
        #expect(first.models == firstModels)
        #expect(first.storedAt == firstDate)
        #expect(second.models == secondModels)
        #expect(second.storedAt == secondDate)
        #expect(store.snapshot(forBinaryPath: "/opt/claude-missing") == nil)

        store.invalidateAll()

        #expect(store.snapshot(forBinaryPath: "/opt/claude-a") == nil)
        #expect(store.snapshot(forBinaryPath: "/opt/claude-b") == nil)
        #expect(defaults.string(forKey: "unrelated") == "keep")
    }

    @Test func staleCatalogDataIsIgnored() throws {
        let suiteName = "SupermuxHarnessModelCatalogTests.stale.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SupermuxHarnessModelCatalogStore(defaults: defaults)

        try store.store(
            [try model(value: "claude-obsolete")],
            forBinaryPath: "/opt/claude",
            storedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(store.snapshot(forBinaryPath: "/opt/claude") == nil)
    }

    @Test func corruptCatalogDataIsIgnored() throws {
        let suiteName = "SupermuxHarnessModelCatalogTests.corrupt.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SupermuxHarnessModelCatalogStore(defaults: defaults)
        defaults.set(Data("not-json".utf8), forKey: store.modelsKey(forBinaryPath: "/opt/claude"))

        #expect(store.snapshot(forBinaryPath: "/opt/claude") == nil)
    }

    private func model(value: String) throws -> SupermuxHarnessJSONObject {
        try SupermuxHarnessJSONObject(rawValue: ["value": value, "displayName": value])
    }
}
