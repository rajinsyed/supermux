public import Foundation

/// Scans Claude Code session transcripts into normalized per-day, per-model
/// token usage.
///
/// Transcripts live at `~/.claude/projects/<slug>/<sessionId>.jsonl`, one JSON
/// object per line, and only `type: "assistant"` lines carry usage. They also
/// carry it *repeatedly*: streaming flushes rewrite an assistant entry several
/// times, so roughly half of all usage lines are restatements of one already
/// seen. Counting them naively doubles every number, which is why the scanner
/// keys on `message.id` and keeps the last occurrence — the final flush is the
/// one holding the completed output count.
public struct SupermuxClaudeUsageLogScanner: Sendable {
    private static let assistantNeedle = Array("\"type\":\"assistant\"".utf8)
    private static let assistantSpacedNeedle = Array("\"type\": \"assistant\"".utf8)

    private let projectsDirectory: URL
    private let cacheStore: SupermuxUsageAnalyticsCacheStore
    private let calendar: Calendar

    /// Creates a scanner rooted at Claude Code's projects directory.
    ///
    /// - Parameter projectsDirectory: The directory holding per-project
    ///   session transcripts. The default is `~/.claude/projects`.
    public init(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    ) {
        self.projectsDirectory = projectsDirectory
        self.cacheStore = SupermuxUsageAnalyticsCacheStore()
        self.calendar = .current
    }

    init(
        projectsDirectory: URL,
        cacheStore: SupermuxUsageAnalyticsCacheStore,
        calendar: Calendar
    ) {
        self.projectsDirectory = projectsDirectory
        self.cacheStore = cacheStore
        self.calendar = calendar
    }

    /// Whether Claude Code's projects directory exists.
    public var isAvailable: Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(
            atPath: projectsDirectory.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    /// Scans every transcript, reusing unchanged per-file cache entries.
    ///
    /// - Parameter onProgress: Called as files complete with the scanned
    ///   count, total count, and all entries available so far. Throttled, so a
    ///   cold scan does not pay to re-sort its results once per file.
    /// - Returns: Per-file aggregates across every readable transcript.
    public func scan(
        onProgress: (@Sendable (Int, Int, [SupermuxUsageAnalyticsEntry]) -> Void)? = nil
    ) -> [SupermuxUsageAnalyticsEntry] {
        let files = transcriptFiles()
        // No files at all almost always means the directory is gone or
        // unreadable, not that the user's history vanished. Persisting the
        // empty map would destroy a cache that took minutes to build and can
        // never be rebuilt from logs that are no longer there.
        guard !files.isEmpty else { return [] }
        let cached = cacheStore.load(.claudeCode)
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
                // Parsing one transcript churns through thousands of transient
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
            cacheStore.save(cache, for: .claudeCode)
        }
        return SupermuxUsageLogScanSupport.sortedEntries(in: updatedFiles)
    }

    private func transcriptFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: Array(SupermuxUsageLogScanSupport.resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            files.append(file)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func scanFile(
        _ url: URL,
        decoder: JSONDecoder,
        fractionalDateFormatter: ISO8601DateFormatter,
        standardDateFormatter: ISO8601DateFormatter
    ) -> [SupermuxUsageAnalyticsEntry]? {
        // Last write per message id wins. Duplicates have not been observed to
        // cross transcript files, so deduping within one file is enough — and
        // it keeps each file's contribution self-contained, which is what lets
        // the cache replace a single changed file without re-reading the rest.
        var usageByMessage: [String: Measurement] = [:]

        let didRead = SupermuxLineReader.forEachLine(in: url) { line in
            guard SupermuxLineReader.contains(line, Self.assistantNeedle)
                || SupermuxLineReader.contains(line, Self.assistantSpacedNeedle),
                let record = try? decoder.decode(LogRecord.self, from: line),
                record.type == "assistant",
                let message = record.message,
                let usage = message.usage,
                let model = message.model,
                !SupermuxModelPricing.isSynthetic(model),
                let timestamp = record.timestamp,
                let date = fractionalDateFormatter.date(from: timestamp)
                    ?? standardDateFormatter.date(from: timestamp)
            else {
                return
            }

            let key = message.id ?? record.uuid ?? UUID().uuidString
            usageByMessage[key] = Measurement(
                day: calendar.startOfDay(for: date),
                model: model,
                tokens: usage.normalized
            )
        }

        guard didRead else { return nil }

        // Summing is commutative, so the dictionary's arbitrary iteration order
        // cannot change a bucket's total; no insertion order needs tracking.
        var tokensByBucket: [BucketKey: SupermuxTokenCounts] = [:]
        for measurement in usageByMessage.values {
            let bucket = BucketKey(day: measurement.day, model: measurement.model)
            tokensByBucket[bucket, default: .zero] += measurement.tokens
        }

        return tokensByBucket
            .map { key, tokens in
                SupermuxUsageAnalyticsEntry(
                    day: key.day,
                    provider: .claudeCode,
                    model: key.model,
                    tokens: tokens
                )
            }
            .sorted(by: SupermuxUsageLogScanSupport.entriesSortBefore)
    }

    private struct BucketKey: Hashable {
        var day: Date
        var model: String
    }

    private struct Measurement {
        var day: Date
        var model: String
        var tokens: SupermuxTokenCounts
    }

    /// The slice of a transcript line the scanner needs; everything else,
    /// including message content, is left undecoded.
    private struct LogRecord: Decodable {
        var type: String?
        var timestamp: String?
        var uuid: String?
        var message: Message?

        struct Message: Decodable {
            var id: String?
            var model: String?
            var usage: Usage?
        }

        struct Usage: Decodable {
            var inputTokens: Int?
            var cacheCreationInputTokens: Int?
            var cacheReadInputTokens: Int?
            var outputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case outputTokens = "output_tokens"
            }

            /// Claude's `input_tokens` already excludes cache reads and cache
            /// writes, so the three prompt classes map across directly.
            var normalized: SupermuxTokenCounts {
                SupermuxTokenCounts(
                    uncachedInput: max(0, inputTokens ?? 0),
                    cacheWrite: max(0, cacheCreationInputTokens ?? 0),
                    cacheRead: max(0, cacheReadInputTokens ?? 0),
                    output: max(0, outputTokens ?? 0)
                )
            }
        }
    }
}
