public import Foundation
public import SupermuxClaudeHarness

/// One persisted harness session record, keyed by the panel's stable surface ID.
///
/// Never contains tokens, environment, PIDs, or unredacted stderr. There is no
/// permission mode: sessions always run with permissions skipped.
public struct SupermuxHarnessSessionRecord: Codable, Sendable, Equatable {
    public var stableSurfaceID: UUID
    /// The provider session ID from `system.init` (the `--resume` identity).
    public var claudeSessionID: String?
    public var launcher: ClaudeLauncher
    public var workingDirectory: String
    public var model: String?
    public var effortLevel: String?
    public var fastMode: Bool
    public var maxThinkingTokens: Int?
    public var derivedTitle: String?
    public var lastActiveAt: Date
    /// Queue entries with delivery states (uncertain entries preserved).
    public var queueEntries: [ClaudeQueuedInput]
    public var lastTotalCostUSD: Double?
    public var lastInputTokens: Int?
    public var lastOutputTokens: Int?
    /// Redacted startup/process diagnostic (e.g. launcher stderr tail).
    public var redactedDiagnostic: String?

    public init(
        stableSurfaceID: UUID,
        claudeSessionID: String? = nil,
        launcher: ClaudeLauncher,
        workingDirectory: String,
        model: String? = nil,
        effortLevel: String? = nil,
        fastMode: Bool = false,
        maxThinkingTokens: Int? = nil,
        derivedTitle: String? = nil,
        lastActiveAt: Date = Date(),
        queueEntries: [ClaudeQueuedInput] = [],
        lastTotalCostUSD: Double? = nil,
        lastInputTokens: Int? = nil,
        lastOutputTokens: Int? = nil,
        redactedDiagnostic: String? = nil
    ) {
        self.stableSurfaceID = stableSurfaceID
        self.claudeSessionID = claudeSessionID
        self.launcher = launcher
        self.workingDirectory = workingDirectory
        self.model = model
        self.effortLevel = effortLevel
        self.fastMode = fastMode
        self.maxThinkingTokens = maxThinkingTokens
        self.derivedTitle = derivedTitle
        self.lastActiveAt = lastActiveAt
        self.queueEntries = queueEntries
        self.lastTotalCostUSD = lastTotalCostUSD
        self.lastInputTokens = lastInputTokens
        self.lastOutputTokens = lastOutputTokens
        self.redactedDiagnostic = redactedDiagnostic
    }
}

/// JSON persistence for harness session records under the cmux state directory
/// (the same home the fork's APNs key uses; the caller injects the base URL
/// from `CmuxSettings.CmuxStateDirectory`).
///
/// Writes are atomic and owner-only (`0o600` files in an `0o700` directory).
public actor SupermuxHarnessSessionStore {
    public static let directoryName = "supermux-claude-harness"

    private let directoryURL: URL
    private let fileManager: FileManager

    /// - Parameter baseDirectory: The cmux state directory.
    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.directoryURL = baseDirectory
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        self.fileManager = fileManager
    }

    /// Loads one record, or `nil` when absent or undecodable.
    public func load(stableSurfaceID: UUID) -> SupermuxHarnessSessionRecord? {
        guard let data = try? Data(contentsOf: fileURL(for: stableSurfaceID)) else { return nil }
        return try? decoder().decode(SupermuxHarnessSessionRecord.self, from: data)
    }

    /// All persisted records.
    public func loadAll() -> [SupermuxHarnessSessionRecord] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return []
        }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let url = directoryURL.appendingPathComponent(name, isDirectory: false)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder().decode(SupermuxHarnessSessionRecord.self, from: data)
        }
    }

    /// Atomically saves one record with owner-only permissions.
    public func save(_ record: SupermuxHarnessSessionRecord) throws {
        try ensureDirectory()
        let url = fileURL(for: record.stableSurfaceID)
        let data = try encoder().encode(record)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// Removes one record.
    public func remove(stableSurfaceID: UUID) {
        try? fileManager.removeItem(at: fileURL(for: stableSurfaceID))
    }

    private func fileURL(for stableSurfaceID: UUID) -> URL {
        directoryURL.appendingPathComponent(
            "\(stableSurfaceID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // `createDirectory` applies attributes only on creation; repair a
        // pre-existing directory so the owner-only invariant always holds.
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
