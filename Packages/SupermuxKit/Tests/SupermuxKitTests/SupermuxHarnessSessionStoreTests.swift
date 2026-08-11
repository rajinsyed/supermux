import Foundation
import SupermuxClaudeHarness
import Testing
@testable import SupermuxKit

/// Session record persistence: round-trip, permissions, and redaction.
struct SupermuxHarnessSessionStoreTests {
    private func temporaryBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRecord(id: UUID = UUID()) -> SupermuxHarnessSessionRecord {
        // Whole-second dates: ISO8601 persistence intentionally drops
        // sub-second precision.
        let date = Date(timeIntervalSince1970: 1_754_900_000)
        return SupermuxHarnessSessionRecord(
            stableSurfaceID: id,
            claudeSessionID: "prov-123",
            launcher: ClaudeLauncher(
                kind: .ccx,
                executablePath: "/Users/u/.local/bin/ccx",
                displayName: "ccx"
            ),
            workingDirectory: "/tmp/project",
            model: "claude-fable-5",
            effortLevel: "high",
            fastMode: true,
            maxThinkingTokens: 4096,
            derivedTitle: "Fix the parser",
            lastActiveAt: date,
            queueEntries: [
                ClaudeQueuedInput(text: "pending prompt", createdAt: date, state: .uncertain)
            ],
            lastTotalCostUSD: 0.42,
            lastInputTokens: 100,
            lastOutputTokens: 200,
            redactedDiagnostic: "launcher exited"
        )
    }

    @Test func roundTripsARecord() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = SupermuxHarnessSessionStore(baseDirectory: base)
        let record = makeRecord()
        try await store.save(record)

        let loaded = await store.load(stableSurfaceID: record.stableSurfaceID)
        #expect(loaded == record)

        let all = await store.loadAll()
        #expect(all == [record])

        await store.remove(stableSurfaceID: record.stableSurfaceID)
        #expect(await store.load(stableSurfaceID: record.stableSurfaceID) == nil)
    }

    @Test func writesOwnerOnlyPermissions() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = SupermuxHarnessSessionStore(baseDirectory: base)
        let record = makeRecord()
        try await store.save(record)

        let directory = base.appendingPathComponent(
            SupermuxHarnessSessionStore.directoryName, isDirectory: true
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.path
        )
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let file = directory.appendingPathComponent(
            "\(record.stableSurfaceID.uuidString.lowercased()).json",
            isDirectory: false
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func repairsPreexistingDirectoryToOwnerOnly() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        // Pre-create the harness directory group/world-readable.
        let directory = base.appendingPathComponent(
            SupermuxHarnessSessionStore.directoryName, isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let store = SupermuxHarnessSessionStore(baseDirectory: base)
        try await store.save(makeRecord())
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func missingAndCorruptRecordsLoadAsNil() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = SupermuxHarnessSessionStore(baseDirectory: base)
        #expect(await store.load(stableSurfaceID: UUID()) == nil)

        // A corrupted file is skipped rather than crashing.
        let directory = base.appendingPathComponent(
            SupermuxHarnessSessionStore.directoryName, isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("\(id.uuidString.lowercased()).json")
        )
        #expect(await store.load(stableSurfaceID: id) == nil)
        #expect(await store.loadAll().isEmpty)
    }

    @Test func recordHasNoPermissionModeField() throws {
        // Sessions always skip permissions; the record must not resurrect a
        // permission-mode field.
        let data = try JSONEncoder().encode(makeRecord())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("permissionMode"))
        #expect(!text.contains("permission_mode"))
    }

    @Test func secretRedactorStripsTokens() {
        let input = """
        ANTHROPIC_API_KEY=sk-ant-abc123def456 leaked
        export CCX_API_KEY=super-secret-value
        Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig
        api_key: hunter2hunter2
        plain text stays
        """
        let output = ClaudeSecretRedactor.redact(input)
        #expect(!output.contains("sk-ant-abc123def456"))
        #expect(!output.contains("super-secret-value"))
        #expect(!output.contains("eyJhbGciOiJIUzI1NiJ9"))
        #expect(!output.contains("hunter2hunter2"))
        #expect(output.contains("plain text stays"))
        #expect(output.contains("[redacted]"))
    }

    @Test func secretRedactorStripsSerializedJSONAndLowercaseBearer() {
        // Regression: JSON-serialized credentials and lowercase bearer tokens
        // must not pass through unchanged.
        let input = #"{"ANTHROPIC_AUTH_TOKEN":"secret-value-123456","authorization":"bearer abcdefghijklmnop"}"#
        let output = ClaudeSecretRedactor.redact(input)
        #expect(!output.contains("secret-value-123456"))
        #expect(!output.contains("abcdefghijklmnop"))
        #expect(output.contains("[redacted]"))
    }
}
