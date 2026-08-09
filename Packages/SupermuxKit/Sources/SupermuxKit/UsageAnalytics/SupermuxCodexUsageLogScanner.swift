public import Foundation

/// Scans Codex rollout logs into normalized per-day, per-model token usage.
public struct SupermuxCodexUsageLogScanner: Sendable {
    private static let tokenCountNeedle = Array("token_count".utf8)
    private static let turnContextNeedle = Array("turn_context".utf8)
    private static let unknownModel = "unknown"

    private let sessionsDirectory: URL
    private let cacheStore: SupermuxUsageAnalyticsCacheStore
    private let calendar: Calendar

    /// Creates a scanner rooted at the Codex state directory.
    ///
    /// - Parameter sessionsDirectory: The Codex state directory containing `sessions/` and
    ///   `archived_sessions/`. The default is `~/.codex`.
    public init(
        sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.cacheStore = SupermuxUsageAnalyticsCacheStore()
        self.calendar = .current
    }

    init(
        sessionsDirectory: URL,
        cacheStore: SupermuxUsageAnalyticsCacheStore,
        calendar: Calendar
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.cacheStore = cacheStore
        self.calendar = calendar
    }

    /// Whether either directory the scanner reads exists.
    ///
    /// Both are checked because ``rolloutFiles()`` reads both: a user whose
    /// current sessions were all archived still has data, and reporting Codex
    /// as "no logs found" while its rows render would contradict the popover.
    public var isAvailable: Bool {
        ["sessions", "archived_sessions"].contains { name in
            var isDirectory = ObjCBool(false)
            let path = sessionsDirectory.appendingPathComponent(name, isDirectory: true).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// Scans all current and archived rollout logs, reusing unchanged per-file cache entries.
    ///
    /// - Parameter onProgress: Called after each file with the completed count, total count,
    ///   and all entries available so far.
    /// - Returns: Per-file aggregates across every readable rollout log.
    public func scan(
        onProgress: (@Sendable (Int, Int, [SupermuxUsageAnalyticsEntry]) -> Void)? = nil
    ) -> [SupermuxUsageAnalyticsEntry] {
        let files = rolloutFiles()
        // No files at all almost always means the directory is gone or
        // unreadable, not that the user's history vanished. Persisting the
        // empty map would destroy a cache that took minutes to build and can
        // never be rebuilt from logs that are no longer there.
        guard !files.isEmpty else { return [] }
        let cached = cacheStore.load(.codex)
        var updatedFiles: [String: SupermuxScannedFile] = [:]
        updatedFiles.reserveCapacity(files.count)

        let decoder = JSONDecoder()
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardDateFormatter = ISO8601DateFormatter()
        standardDateFormatter.formatOptions = [.withInternetDateTime]

        let earliestRelevant = SupermuxUsageScanWindow.earliestRelevantModification()
        var lastPublishedAt = Date.distantPast
        for (index, file) in files.enumerated() {
            // A cold pass reads gigabytes; give up promptly when the caller
            // has, rather than finishing the walk in the background.
            if Task.isCancelled { break }
            defer {
                // Every file publishes, including the ones skipped below, or a
                // run whose tail is all skips never reports `scanned == total`.
                SupermuxUsageLogScanSupport.publishProgress(
                    onProgress,
                    scanned: index + 1,
                    total: files.count,
                    files: updatedFiles,
                    lastPublishedAt: &lastPublishedAt
                )
            }
            let path = file.standardizedFileURL.path
            guard let signature = SupermuxUsageLogScanSupport.fileSignature(for: file) else {
                if let prior = cached.files[path] {
                    updatedFiles[path] = prior
                }
                continue
            }
            // Older than every range the popover offers: nothing in it could
            // be displayed, so it is never opened.
            guard signature.modifiedAt >= earliestRelevant else { continue }

            if let prior = cached.files[path],
               prior.matches(size: signature.size, modifiedAt: signature.modifiedAt) {
                updatedFiles[path] = prior
            } else if let entries = autoreleasepool(invoking: {
                // Parsing one rollout churns through thousands of transient
                // Foundation objects. Draining per file keeps a multi-gigabyte
                // cold scan's footprint flat instead of letting it accumulate.
                scanFile(
                    file,
                    decoder: decoder,
                    fractionalDateFormatter: fractionalDateFormatter,
                    standardDateFormatter: standardDateFormatter
                )
            }) {
                updatedFiles[path] = SupermuxScannedFile(
                    path: path,
                    size: signature.size,
                    modifiedAt: signature.modifiedAt,
                    entries: entries
                )
            } else if let prior = cached.files[path] {
                updatedFiles[path] = prior
            }
        }

        // A cancelled pass stopped partway through the file list, so its map is
        // missing every file after the break. Persisting it would drop those
        // files' history until each one changed again.
        if !Task.isCancelled {
            var cache = SupermuxUsageAnalyticsCache(files: updatedFiles)
            cache.prune(earliestRelevant: earliestRelevant)
            cacheStore.save(cache, for: .codex)
        }
        return SupermuxUsageLogScanSupport.sortedEntries(in: updatedFiles)
    }

    private func rolloutFiles() -> [URL] {
        let fileManager = FileManager.default
        var filesByPath: [String: URL] = [:]

        let sessions = sessionsDirectory.appendingPathComponent("sessions", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: sessions,
            includingPropertiesForKeys: Array(SupermuxUsageLogScanSupport.resourceKeys),
            options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in enumerator where Self.isRolloutFile(file) {
                filesByPath[file.standardizedFileURL.path] = file
            }
        }

        let archived = sessionsDirectory.appendingPathComponent("archived_sessions", isDirectory: true)
        if let archivedFiles = try? fileManager.contentsOfDirectory(
            at: archived,
            includingPropertiesForKeys: Array(SupermuxUsageLogScanSupport.resourceKeys),
            options: [.skipsHiddenFiles]
        ) {
            for file in archivedFiles where Self.isRolloutFile(file) {
                filesByPath[file.standardizedFileURL.path] = file
            }
        }

        return filesByPath.values.sorted { $0.path < $1.path }
    }

    private static func isRolloutFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    private func scanFile(
        _ url: URL,
        decoder: JSONDecoder,
        fractionalDateFormatter: ISO8601DateFormatter,
        standardDateFormatter: ISO8601DateFormatter
    ) -> [SupermuxUsageAnalyticsEntry]? {
        var currentModel = Self.unknownModel
        var previousUsage: RawTokenUsage?
        var tokensByBucket: [BucketKey: SupermuxTokenCounts] = [:]

        let didRead = SupermuxLineReader.forEachLine(in: url) { line in
            let containsTurnContext = SupermuxLineReader.contains(line, Self.turnContextNeedle)
            let containsTokenCount = SupermuxLineReader.contains(line, Self.tokenCountNeedle)
            guard containsTurnContext || containsTokenCount,
                  let record = try? decoder.decode(LogRecord.self, from: line)
            else {
                return
            }

            if record.type == "turn_context" {
                currentModel = record.payload?.resolvedModel ?? Self.unknownModel
                return
            }

            guard record.type == "event_msg",
                  record.payload?.type == "token_count",
                  let totalUsage = record.payload?.info?.totalTokenUsage
            else {
                return
            }

            let usage = RawTokenUsage(totalUsage)
            let delta = usage.delta(from: previousUsage)
            previousUsage = usage
            guard !delta.isEmpty,
                  let timestamp = record.timestamp,
                  let date = Self.parseDate(
                      timestamp,
                      fractionalDateFormatter: fractionalDateFormatter,
                      standardDateFormatter: standardDateFormatter
                  )
            else {
                return
            }

            let key = BucketKey(day: calendar.startOfDay(for: date), model: currentModel)
            tokensByBucket[key, default: .zero] += delta.normalized
        }

        guard didRead else { return nil }
        return tokensByBucket
            .map { key, tokens in
                SupermuxUsageAnalyticsEntry(
                    day: key.day,
                    provider: .codex,
                    model: key.model,
                    tokens: tokens
                )
            }
            .sorted(by: SupermuxUsageLogScanSupport.entriesSortBefore)
    }

    private static func parseDate(
        _ value: String,
        fractionalDateFormatter: ISO8601DateFormatter,
        standardDateFormatter: ISO8601DateFormatter
    ) -> Date? {
        fractionalDateFormatter.date(from: value) ?? standardDateFormatter.date(from: value)
    }

    private struct BucketKey: Hashable {
        var day: Date
        var model: String
    }

    private struct RawTokenUsage {
        var input: Int
        var cachedInput: Int
        var cacheWriteInput: Int
        var output: Int
        var reasoningOutput: Int

        init(_ usage: LogRecord.Payload.TokenInfo.TotalTokenUsage) {
            input = max(0, usage.inputTokens)
            cachedInput = max(0, usage.cachedInputTokens)
            cacheWriteInput = max(0, usage.cacheWriteInputTokens ?? 0)
            output = max(0, usage.outputTokens)
            reasoningOutput = max(0, usage.reasoningOutputTokens)
        }

        var isEmpty: Bool {
            input == 0
                && cachedInput == 0
                && cacheWriteInput == 0
                && output == 0
                && reasoningOutput == 0
        }

        func delta(from previous: Self?) -> Self {
            guard let previous else { return self }
            return Self(
                input: Self.nonnegativeDifference(input, previous.input),
                cachedInput: Self.nonnegativeDifference(cachedInput, previous.cachedInput),
                cacheWriteInput: Self.nonnegativeDifference(cacheWriteInput, previous.cacheWriteInput),
                output: Self.nonnegativeDifference(output, previous.output),
                reasoningOutput: Self.nonnegativeDifference(reasoningOutput, previous.reasoningOutput)
            )
        }

        var normalized: SupermuxTokenCounts {
            let afterCacheRead = input > cachedInput ? input - cachedInput : 0
            let uncachedInput = afterCacheRead > cacheWriteInput
                ? afterCacheRead - cacheWriteInput
                : 0
            return SupermuxTokenCounts(
                uncachedInput: uncachedInput,
                cacheWrite: cacheWriteInput,
                cacheRead: cachedInput,
                output: output,
                reasoningOutput: reasoningOutput
            )
        }

        private init(
            input: Int,
            cachedInput: Int,
            cacheWriteInput: Int,
            output: Int,
            reasoningOutput: Int
        ) {
            self.input = input
            self.cachedInput = cachedInput
            self.cacheWriteInput = cacheWriteInput
            self.output = output
            self.reasoningOutput = reasoningOutput
        }

        private static func nonnegativeDifference(_ current: Int, _ previous: Int) -> Int {
            current > previous ? current - previous : 0
        }
    }

    private struct LogRecord: Decodable {
        var timestamp: String?
        var type: String
        var payload: Payload?

        struct Payload: Decodable {
            var type: String?
            var model: String?
            var collaborationMode: CollaborationMode?
            var info: TokenInfo?

            var resolvedModel: String? {
                let candidates = [model, collaborationMode?.settings?.model]
                for candidate in candidates {
                    let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !trimmed.isEmpty { return trimmed }
                }
                return nil
            }

            enum CodingKeys: String, CodingKey {
                case type
                case model
                case collaborationMode = "collaboration_mode"
                case info
            }

            struct CollaborationMode: Decodable {
                var settings: Settings?

                struct Settings: Decodable {
                    var model: String?
                }
            }

            struct TokenInfo: Decodable {
                var totalTokenUsage: TotalTokenUsage?

                enum CodingKeys: String, CodingKey {
                    case totalTokenUsage = "total_token_usage"
                }

                struct TotalTokenUsage: Decodable {
                    var inputTokens: Int
                    var cachedInputTokens: Int
                    var cacheWriteInputTokens: Int?
                    var outputTokens: Int
                    var reasoningOutputTokens: Int

                    enum CodingKeys: String, CodingKey {
                        case inputTokens = "input_tokens"
                        case cachedInputTokens = "cached_input_tokens"
                        case cacheWriteInputTokens = "cache_write_input_tokens"
                        case outputTokens = "output_tokens"
                        case reasoningOutputTokens = "reasoning_output_tokens"
                    }
                }
            }
        }
    }
}
