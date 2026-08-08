import Foundation

/// What one scanned log file contributed, plus the stat signature that says
/// whether it needs re-reading.
///
/// Both scanners are per-file idempotent: a file's contribution is stored
/// whole, so a changed file simply replaces its own entry and no cross-file
/// bookkeeping is needed. That costs a full reparse of the (few) files that
/// grow each day, and buys immunity to the partial-tail and rewritten-line
/// hazards that a byte-offset cursor would have to handle.
struct SupermuxScannedFile: Codable, Sendable, Equatable {
    /// Absolute path, the cache key.
    var path: String
    var size: Int64
    /// Modification time in whole milliseconds since 1970. Stored as an
    /// integer so a JSON round trip reproduces it exactly — a tolerance window
    /// would let a same-size rewrite within the window serve stale numbers
    /// forever, which is worse than an unnecessary reparse.
    var modifiedAtMilliseconds: Int64
    /// Per-day, per-model token counts this file contributed.
    var entries: [SupermuxUsageAnalyticsEntry]

    init(path: String, size: Int64, modifiedAt: Date, entries: [SupermuxUsageAnalyticsEntry]) {
        self.path = path
        self.size = size
        self.modifiedAtMilliseconds = Self.milliseconds(modifiedAt)
        self.entries = entries
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Whether the file on disk still matches what was scanned.
    func matches(size: Int64, modifiedAt: Date) -> Bool {
        self.size == size && modifiedAtMilliseconds == Self.milliseconds(modifiedAt)
    }
}

/// Bounds shared by both scanners.
enum SupermuxUsageScanWindow {
    /// The longest range the popover offers, plus a day of slack for logs
    /// whose modification time trails their newest entry.
    static let dayCount = 91

    /// Files untouched since this instant cannot contain usage the popover can
    /// display, so they are never opened. Without the cutoff every cold scan
    /// reads the user's entire session history — gigabytes of it — to produce
    /// rows that are then filtered out by the range.
    static func earliestRelevantModification(now: Date = Date()) -> Date {
        now.addingTimeInterval(-Double(dayCount) * 24 * 60 * 60)
    }
}

/// The file-walking plumbing both log scanners share.
///
/// The two scanners parse completely different formats but walk their files
/// identically, so this is the single place that decides what a file's stat
/// signature is, how entries are ordered, and when progress is published.
enum SupermuxUsageLogScanSupport {
    static let resourceKeys: Set<URLResourceKey> = [
        .contentModificationDateKey,
        .fileSizeKey,
        .isRegularFileKey,
    ]

    struct FileSignature {
        var size: Int64
        var modifiedAt: Date
    }

    static func fileSignature(for url: URL) -> FileSignature? {
        guard let values = try? url.resourceValues(forKeys: resourceKeys),
              values.isRegularFile == true,
              let size = values.fileSize,
              let modifiedAt = values.contentModificationDate
        else {
            return nil
        }
        return FileSignature(size: Int64(size), modifiedAt: modifiedAt)
    }

    static func entriesSortBefore(
        _ lhs: SupermuxUsageAnalyticsEntry,
        _ rhs: SupermuxUsageAnalyticsEntry
    ) -> Bool {
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        if lhs.model != rhs.model { return lhs.model < rhs.model }
        return lhs.provider < rhs.provider
    }

    static func sortedEntries(
        in files: [String: SupermuxScannedFile]
    ) -> [SupermuxUsageAnalyticsEntry] {
        files.values.flatMap(\.entries).sorted(by: entriesSortBefore)
    }

    /// Entries as found, unordered. Progress consumers fold everything into
    /// dictionaries and never read the order, so a cold scan must not re-sort
    /// tens of thousands of entries four times a second just to publish them.
    static func flattenedEntries(
        in files: [String: SupermuxScannedFile]
    ) -> [SupermuxUsageAnalyticsEntry] {
        files.values.flatMap(\.entries)
    }

    /// Publishes at most four times a second, and always on the final file.
    ///
    /// Every file must reach here — including ones skipped as too old or
    /// unreadable — or a run whose last files are all skipped never publishes
    /// `scanned == total` and the popover's bar stops short of full.
    static func publishProgress(
        _ callback: (@Sendable (Int, Int, [SupermuxUsageAnalyticsEntry]) -> Void)?,
        scanned: Int,
        total: Int,
        files: [String: SupermuxScannedFile],
        lastPublishedAt: inout Date
    ) {
        guard let callback else { return }
        let now = Date()
        guard scanned >= total || now.timeIntervalSince(lastPublishedAt) > 0.25 else { return }
        lastPublishedAt = now
        callback(scanned, total, flattenedEntries(in: files))
    }
}

/// The persisted index for one provider's logs.
struct SupermuxUsageAnalyticsCache: Codable, Sendable {
    /// Bumped when the parsing rules change in a way that invalidates stored
    /// aggregates — an old cache is then discarded instead of trusted.
    static let currentVersion = 1

    var version: Int
    var files: [String: SupermuxScannedFile]

    init(version: Int = Self.currentVersion, files: [String: SupermuxScannedFile] = [:]) {
        self.version = version
        self.files = files
    }

    /// Drops files that have aged out of the scan window or no longer exist,
    /// so the cache cannot grow without bound or keep serving deleted logs.
    mutating func prune(earliestRelevant: Date) {
        files = files.filter { path, file in
            file.modifiedAtMilliseconds >= SupermuxScannedFile.milliseconds(earliestRelevant)
                && FileManager.default.fileExists(atPath: path)
        }
    }
}

/// Reads and writes the scan caches under Application Support.
///
/// Cache loss is never fatal — a missing or unreadable file just means the
/// next scan is cold, so every failure path here degrades silently.
struct SupermuxUsageAnalyticsCacheStore: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support")
            self.directory = base.appendingPathComponent("cmux", isDirectory: true)
        }
    }

    private func url(for provider: SupermuxAnalyticsProvider) -> URL {
        directory.appendingPathComponent("supermux-usage-\(provider.rawValue).json")
    }

    func load(_ provider: SupermuxAnalyticsProvider) -> SupermuxUsageAnalyticsCache {
        guard let data = try? Data(contentsOf: url(for: provider)),
              let cache = try? JSONDecoder().decode(SupermuxUsageAnalyticsCache.self, from: data),
              cache.version == SupermuxUsageAnalyticsCache.currentVersion
        else {
            return SupermuxUsageAnalyticsCache()
        }
        return cache
    }

    func save(_ cache: SupermuxUsageAnalyticsCache, for provider: SupermuxAnalyticsProvider) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: provider), options: .atomic)
    }
}

/// Streams a file's lines without loading the whole thing into memory.
///
/// Session logs reach 170 MB; reading one as a single `String` would spike
/// hundreds of megabytes for a file the scanner discards >90% of.
enum SupermuxLineReader {
    /// A single line longer than this is treated as unusable and skipped.
    ///
    /// Session logs are one JSON object per line, so a span this large means
    /// the file is not what it claims to be (or a writer crashed mid-line).
    /// Without the ceiling, a 170 MB newline-free file would be buffered whole.
    static let maximumLineBytes = 8 << 20

    /// Calls `handle` once per newline-terminated line. Returns false if the
    /// file could not be opened.
    @discardableResult
    static func forEachLine(
        in url: URL,
        chunkSize: Int = 1 << 20,
        handle: (Data.SubSequence) -> Void
    ) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }

        var buffer = Data()
        // Consume in place rather than reslicing: dropping the prefix per line
        // would recopy the rest of the chunk every time, which is quadratic in
        // the number of lines and made a 1 MB chunk of short lines take
        // seconds.
        var consumed = 0
        var searched = 0
        /// Set when the current line already exceeded the ceiling; the rest of
        /// it is discarded up to the next newline.
        var isSkippingOverlongLine = false
        let newline = UInt8(ascii: "\n")

        func drainLines() {
            while let index = buffer[(buffer.startIndex + searched)...].firstIndex(of: newline) {
                // Slices share the buffer's storage, so a line costs nothing
                // to hand out. Copying each one into a fresh `Data` churned
                // through every byte of a multi-gigabyte scan.
                let line = buffer[(buffer.startIndex + consumed)..<index]
                if isSkippingOverlongLine {
                    isSkippingOverlongLine = false
                } else if !line.isEmpty, line.count <= maximumLineBytes {
                    handle(line)
                }
                consumed = index - buffer.startIndex + 1
                searched = consumed
            }
            searched = buffer.count
        }

        while let chunk = autoreleasepool(invoking: { try? file.read(upToCount: chunkSize) }),
              !chunk.isEmpty {
            // Each chunk creates thousands of short-lived Foundation objects
            // (line slices, decoded records). Without draining per chunk they
            // accumulate for the whole multi-gigabyte scan — measured at
            // several GB of resident memory before this pool was added.
            autoreleasepool {
                buffer.append(chunk)
                drainLines()
                if consumed > 0 {
                    buffer.removeFirst(consumed)
                    searched -= consumed
                    consumed = 0
                }
            }
            // Still no newline after the ceiling: this is not a line-oriented
            // log. Drop what has accumulated and resume at the next newline,
            // instead of buffering the whole file.
            if buffer.count > maximumLineBytes {
                buffer.removeAll(keepingCapacity: false)
                searched = 0
                isSkippingOverlongLine = true
            }
        }
        let tail = buffer[(buffer.startIndex + consumed)...]
        if !isSkippingOverlongLine, !tail.isEmpty, tail.count <= maximumLineBytes {
            handle(tail)
        }
        return true
    }

    /// Cheap substring test used to skip lines before paying for JSON
    /// decoding — the overwhelming majority of log lines are not usage lines.
    static func contains(_ data: Data.SubSequence, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, data.count >= needle.count else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let limit = data.count - needle.count
            var i = 0
            while i <= limit {
                if base[i] == needle[0] {
                    var j = 1
                    while j < needle.count, base[i + j] == needle[j] { j += 1 }
                    if j == needle.count { return true }
                }
                i += 1
            }
            return false
        }
    }
}
