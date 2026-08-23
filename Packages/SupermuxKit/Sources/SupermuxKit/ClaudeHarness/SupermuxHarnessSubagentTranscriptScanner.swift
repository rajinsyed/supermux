import Foundation

/// Reads one stable incremental snapshot of a validated transcript file.
struct SupermuxHarnessSubagentTranscriptScanner: Sendable {
    struct RetainedEvent: Equatable, Sendable {
        let event: SupermuxHarnessJSONObject
        let sourceByteCount: Int
    }

    struct ContinuitySample: Equatable, Sendable {
        let offset: UInt64
        let data: Data
    }

    struct Fingerprint: Equatable, Sendable {
        let systemNumber: UInt64?
        let fileNumber: UInt64?
        let creationDate: Date?
        let modificationDate: Date?
        let byteCount: UInt64

        func hasSameIdentity(as other: Fingerprint) -> Bool {
            guard let systemNumber,
                  let fileNumber,
                  let otherSystemNumber = other.systemNumber,
                  let otherFileNumber = other.fileNumber else {
                return false
            }
            return systemNumber == otherSystemNumber
                && fileNumber == otherFileNumber
                && creationDate == other.creationDate
        }
    }

    struct State: Sendable {
        let retainedEvents: [RetainedEvent]
        let retainedEventByteCount: Int
        let truncated: Bool
        let missing: Bool
        let metadata: SupermuxHarnessSubagentTranscriptMetadata?
        let fingerprint: Fingerprint?
        let pendingTail: Data
        let isSkippingOverlongLine: Bool
        let pendingTailWasEmitted: Bool
        let continuitySamples: [ContinuitySample]
        let foundRecordedDirectory: Bool
        let foundMatchingDirectory: Bool

        static let missing = State(
            retainedEvents: [],
            retainedEventByteCount: 0,
            truncated: false,
            missing: true,
            metadata: nil,
            fingerprint: nil,
            pendingTail: Data(),
            isSkippingOverlongLine: false,
            pendingTailWasEmitted: false,
            continuitySamples: [],
            foundRecordedDirectory: false,
            foundMatchingDirectory: false
        )

        var cacheByteCount: Int {
            retainedEventByteCount
                + pendingTail.count
                + continuitySamples.reduce(0) { $0 + $1.data.count }
        }

        var events: [SupermuxHarnessJSONObject] {
            retainedEvents.map(\.event)
        }

        /// Forces a dirty rerun to establish continuity from a fresh full scan.
        var invalidatingFileSnapshot: State {
            State(
                retainedEvents: retainedEvents,
                retainedEventByteCount: retainedEventByteCount,
                truncated: truncated,
                missing: missing,
                metadata: metadata,
                fingerprint: nil,
                pendingTail: pendingTail,
                isSkippingOverlongLine: isSkippingOverlongLine,
                pendingTailWasEmitted: pendingTailWasEmitted,
                continuitySamples: [],
                foundRecordedDirectory: foundRecordedDirectory,
                foundMatchingDirectory: foundMatchingDirectory
            )
        }
    }

    struct Change: Sendable {
        let replace: Bool
        let droppedEventCount: Int
        let events: [SupermuxHarnessJSONObject]
        let metadata: SupermuxHarnessSubagentTranscriptMetadataUpdate
    }

    struct Result: Sendable {
        let state: State
        let change: Change?
        let requiresRerun: Bool
    }

    private enum Mode {
        case full
        case append
        case metadataOnly
    }

    private struct ParsedBytes {
        let retainedEvents: [RetainedEvent]
        let retainedEventByteCount: Int
        let truncated: Bool
        let droppedInitialEventCount: Int
        let appendedEvents: [SupermuxHarnessJSONObject]
        let pendingTail: Data
        let isSkippingOverlongLine: Bool
        let pendingTailWasEmitted: Bool
        let foundRecordedDirectory: Bool
        let foundMatchingDirectory: Bool
    }

    private struct LineAccumulator {
        private(set) var buffer: Data
        private(set) var isSkippingOverlongLine: Bool
        private var skipsPreviouslyEmittedTail: Bool
        private let initialTailByteCount: Int
        private var isFirstCompletedLine = true

        init(
            pendingTail: Data,
            isSkippingOverlongLine: Bool,
            pendingTailWasEmitted: Bool
        ) {
            buffer = pendingTail
            self.isSkippingOverlongLine = isSkippingOverlongLine
            skipsPreviouslyEmittedTail = pendingTailWasEmitted
            initialTailByteCount = pendingTail.count
        }

        mutating func consume(
            _ chunk: Data,
            handle: (Data.SubSequence) -> Bool
        ) {
            buffer.append(chunk)
            var consumed = 0
            let newline = UInt8(ascii: "\n")
            while consumed < buffer.count {
                let start = buffer.index(buffer.startIndex, offsetBy: consumed)
                guard let newlineIndex = buffer[start...].firstIndex(of: newline) else { break }
                let line = buffer[start..<newlineIndex]
                let skipsEmittedLine = isFirstCompletedLine
                    && skipsPreviouslyEmittedTail
                    && line.count == initialTailByteCount
                if isSkippingOverlongLine {
                    isSkippingOverlongLine = false
                } else if !skipsEmittedLine,
                          !line.isEmpty,
                          line.count <= SupermuxLineReader.maximumLineBytes {
                    _ = handle(line)
                }
                isFirstCompletedLine = false
                skipsPreviouslyEmittedTail = false
                consumed = buffer.distance(from: buffer.startIndex, to: newlineIndex) + 1
            }
            if consumed > 0 {
                buffer.removeFirst(consumed)
            }
            if buffer.count > SupermuxLineReader.maximumLineBytes {
                buffer.removeAll(keepingCapacity: false)
                isSkippingOverlongLine = true
                skipsPreviouslyEmittedTail = false
            }
        }

        mutating func finish(
            handle: (Data.SubSequence) -> Bool
        ) -> Bool {
            guard !isSkippingOverlongLine,
                  !buffer.isEmpty,
                  buffer.count <= SupermuxLineReader.maximumLineBytes else {
                return false
            }
            if skipsPreviouslyEmittedTail,
               buffer.count == initialTailByteCount {
                return true
            }
            return handle(buffer[buffer.startIndex...])
        }
    }

    private let locator: SupermuxHarnessSubagentTranscriptLocator
    /// Foundation supports independent `FileManager` operations concurrently; this reference is immutable.
    nonisolated(unsafe) private let fileManager: FileManager
    private let maximumTranscriptBytes: Int
    private let chunkSize: Int
    private let instrumentation: SupermuxHarnessSubagentTranscriptService.ScanInstrumentation?
    private let mapper = SupermuxHarnessSessionRecordMapper()
    private let continuitySampleByteCount = 4 << 10

    init(
        projectsRootURL: URL,
        fileManager: FileManager,
        maximumTranscriptBytes: Int,
        chunkSize: Int = 64 << 10,
        instrumentation: SupermuxHarnessSubagentTranscriptService.ScanInstrumentation?
    ) {
        locator = SupermuxHarnessSubagentTranscriptLocator(
            projectsRootURL: projectsRootURL,
            fileManager: fileManager
        )
        self.fileManager = fileManager
        self.maximumTranscriptBytes = maximumTranscriptBytes
        self.chunkSize = max(1, chunkSize)
        self.instrumentation = instrumentation
    }

    func scan(
        address: SupermuxHarnessSubagentTranscriptAddress,
        baseline: State?
    ) async throws -> Result {
        await instrumentation?.willStartScan?()
        guard let location = try locator.locate(address) else {
            return missingResult(from: baseline)
        }
        guard let before = fingerprint(of: location.transcriptURL) else {
            return missingResult(from: baseline)
        }

        let mode = try scanMode(
            transcriptURL: location.transcriptURL,
            fingerprint: before,
            baseline: baseline
        )
        let metadataBefore = fingerprint(of: location.metadataURL)
        let metadata = try locator.readMetadata(beside: location)
        let result: Result
        switch mode {
        case .full:
            result = try fullResult(
                address: address,
                transcriptURL: location.transcriptURL,
                fingerprint: before,
                metadata: metadata
            )
        case .append:
            guard let baseline else {
                result = try fullResult(
                    address: address,
                    transcriptURL: location.transcriptURL,
                    fingerprint: before,
                    metadata: metadata
                )
                break
            }
            result = try appendResult(
                address: address,
                transcriptURL: location.transcriptURL,
                fingerprint: before,
                metadata: metadata,
                baseline: baseline
            )
        case .metadataOnly:
            guard let baseline else {
                result = try fullResult(
                    address: address,
                    transcriptURL: location.transcriptURL,
                    fingerprint: before,
                    metadata: metadata
                )
                break
            }
            let metadataUpdate = metadataChange(from: baseline.metadata, to: metadata)
            let state = State(
                retainedEvents: baseline.retainedEvents,
                retainedEventByteCount: baseline.retainedEventByteCount,
                truncated: baseline.truncated,
                missing: false,
                metadata: metadata,
                fingerprint: before,
                pendingTail: baseline.pendingTail,
                isSkippingOverlongLine: baseline.isSkippingOverlongLine,
                pendingTailWasEmitted: baseline.pendingTailWasEmitted,
                continuitySamples: baseline.continuitySamples,
                foundRecordedDirectory: baseline.foundRecordedDirectory,
                foundMatchingDirectory: baseline.foundMatchingDirectory
            )
            result = Result(
                state: state,
                change: metadataUpdate == .unchanged
                    ? nil
                    : Change(
                        replace: false,
                        droppedEventCount: 0,
                        events: [],
                        metadata: metadataUpdate
                    ),
                requiresRerun: false
            )
        }

        let after = fingerprint(of: location.transcriptURL)
        let metadataAfter = fingerprint(of: location.metadataURL)
        let transcriptChangedDuringScan = after != before
        return Result(
            state: transcriptChangedDuringScan
                ? result.state.invalidatingFileSnapshot
                : result.state,
            change: result.change,
            requiresRerun: result.requiresRerun
                || transcriptChangedDuringScan
                || metadataAfter != metadataBefore
        )
    }

    private func missingResult(from baseline: State?) -> Result {
        let changed = baseline == nil || baseline?.missing == false
        return Result(
            state: .missing,
            change: changed
                ? Change(
                    replace: true,
                    droppedEventCount: 0,
                    events: [],
                    metadata: .deleted
                )
                : nil,
            requiresRerun: false
        )
    }

    private func scanMode(
        transcriptURL: URL,
        fingerprint: Fingerprint,
        baseline: State?
    ) throws -> Mode {
        guard let baseline,
              !baseline.missing,
              let previous = baseline.fingerprint,
              previous.hasSameIdentity(as: fingerprint) else {
            return .full
        }
        if fingerprint == previous {
            return .metadataOnly
        }
        guard fingerprint.byteCount > previous.byteCount,
              try continuityMatches(
                transcriptURL: transcriptURL,
                samples: baseline.continuitySamples
              ) else {
            return .full
        }
        if baseline.pendingTailWasEmitted {
            let nextByte = try readData(
                from: transcriptURL,
                offset: previous.byteCount,
                count: 1
            )
            guard nextByte.first == UInt8(ascii: "\n") else { return .full }
        }
        return .append
    }

    private func fullResult(
        address: SupermuxHarnessSubagentTranscriptAddress,
        transcriptURL: URL,
        fingerprint: Fingerprint,
        metadata: SupermuxHarnessSubagentTranscriptMetadata?
    ) throws -> Result {
        let parsed = try scanBytes(
            address: address,
            transcriptURL: transcriptURL,
            offset: 0,
            byteCount: fingerprint.byteCount,
            pendingTail: Data(),
            isSkippingOverlongLine: false,
            pendingTailWasEmitted: false,
            foundRecordedDirectory: false,
            foundMatchingDirectory: false,
            initialRetainedEvents: [],
            initialRetainedEventByteCount: 0,
            initialTruncated: false
        )
        let state = State(
            retainedEvents: parsed.retainedEvents,
            retainedEventByteCount: parsed.retainedEventByteCount,
            truncated: parsed.truncated,
            missing: false,
            metadata: metadata,
            fingerprint: fingerprint,
            pendingTail: parsed.pendingTail,
            isSkippingOverlongLine: parsed.isSkippingOverlongLine,
            pendingTailWasEmitted: parsed.pendingTailWasEmitted,
            continuitySamples: try makeContinuitySamples(
                transcriptURL: transcriptURL,
                byteCount: fingerprint.byteCount
            ),
            foundRecordedDirectory: parsed.foundRecordedDirectory,
            foundMatchingDirectory: parsed.foundMatchingDirectory
        )
        return Result(
            state: state,
            change: Change(
                replace: true,
                droppedEventCount: 0,
                events: state.events,
                metadata: metadata.map(
                    SupermuxHarnessSubagentTranscriptMetadataUpdate.value
                ) ?? .deleted
            ),
            requiresRerun: false
        )
    }

    private func appendResult(
        address: SupermuxHarnessSubagentTranscriptAddress,
        transcriptURL: URL,
        fingerprint: Fingerprint,
        metadata: SupermuxHarnessSubagentTranscriptMetadata?,
        baseline: State
    ) throws -> Result {
        guard let previousFingerprint = baseline.fingerprint else {
            return try fullResult(
                address: address,
                transcriptURL: transcriptURL,
                fingerprint: fingerprint,
                metadata: metadata
            )
        }
        let parsed = try scanBytes(
            address: address,
            transcriptURL: transcriptURL,
            offset: previousFingerprint.byteCount,
            byteCount: fingerprint.byteCount - previousFingerprint.byteCount,
            pendingTail: baseline.pendingTail,
            isSkippingOverlongLine: baseline.isSkippingOverlongLine,
            pendingTailWasEmitted: baseline.pendingTailWasEmitted,
            foundRecordedDirectory: baseline.foundRecordedDirectory,
            foundMatchingDirectory: baseline.foundMatchingDirectory,
            initialRetainedEvents: baseline.retainedEvents,
            initialRetainedEventByteCount: baseline.retainedEventByteCount,
            initialTruncated: baseline.truncated
        )
        let metadataUpdate = metadataChange(from: baseline.metadata, to: metadata)
        let state = State(
            retainedEvents: parsed.retainedEvents,
            retainedEventByteCount: parsed.retainedEventByteCount,
            truncated: parsed.truncated,
            missing: false,
            metadata: metadata,
            fingerprint: fingerprint,
            pendingTail: parsed.pendingTail,
            isSkippingOverlongLine: parsed.isSkippingOverlongLine,
            pendingTailWasEmitted: parsed.pendingTailWasEmitted,
            continuitySamples: try makeContinuitySamples(
                transcriptURL: transcriptURL,
                byteCount: fingerprint.byteCount
            ),
            foundRecordedDirectory: parsed.foundRecordedDirectory,
            foundMatchingDirectory: parsed.foundMatchingDirectory
        )
        let changed = parsed.droppedInitialEventCount > 0
            || !parsed.appendedEvents.isEmpty
            || parsed.truncated != baseline.truncated
            || metadataUpdate != .unchanged
        return Result(
            state: state,
            change: changed
                ? Change(
                    replace: false,
                    droppedEventCount: parsed.droppedInitialEventCount,
                    events: parsed.appendedEvents,
                    metadata: metadataUpdate
                )
                : nil,
            requiresRerun: false
        )
    }

    private func scanBytes(
        address: SupermuxHarnessSubagentTranscriptAddress,
        transcriptURL: URL,
        offset: UInt64,
        byteCount: UInt64,
        pendingTail: Data,
        isSkippingOverlongLine: Bool,
        pendingTailWasEmitted: Bool,
        foundRecordedDirectory: Bool,
        foundMatchingDirectory: Bool,
        initialRetainedEvents: [RetainedEvent],
        initialRetainedEventByteCount: Int,
        initialTruncated: Bool
    ) throws -> ParsedBytes {
        let handle = try FileHandle(forReadingFrom: transcriptURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var remaining = byteCount
        var accumulator = LineAccumulator(
            pendingTail: pendingTail,
            isSkippingOverlongLine: isSkippingOverlongLine,
            pendingTailWasEmitted: pendingTailWasEmitted
        )
        var retained = initialRetainedEvents.map { (event: $0, isAppended: false) }
        var retainedStartIndex = 0
        var retainedEventByteCount = initialRetainedEventByteCount
        var truncated = initialTruncated
        var droppedInitialEventCount = 0
        var foundRecordedDirectory = foundRecordedDirectory
        var foundMatchingDirectory = foundMatchingDirectory
        let processLine: (Data.SubSequence) -> Bool = { line in
            guard let value = try? JSONSerialization.jsonObject(with: Data(line)),
                  let record = value as? [String: Any] else {
                return false
            }
            if let recordedDirectory = record["cwd"] as? String {
                let trimmedDirectory = recordedDirectory.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !trimmedDirectory.isEmpty {
                    foundRecordedDirectory = true
                    foundMatchingDirectory = foundMatchingDirectory || locator.recordedDirectory(
                        trimmedDirectory,
                        matches: address
                    )
                }
            }
            if let event = mapper.protocolEvent(
                from: record,
                fallbackSessionID: address.sessionID
            ) {
                let retainedEvent = RetainedEvent(event: event, sourceByteCount: line.count)
                retained.append((event: retainedEvent, isAppended: true))
                retainedEventByteCount += retainedEvent.sourceByteCount
                while retainedStartIndex < retained.count,
                      retainedEventByteCount > maximumTranscriptBytes {
                    let dropped = retained[retainedStartIndex]
                    retainedEventByteCount -= dropped.event.sourceByteCount
                    if !dropped.isAppended { droppedInitialEventCount += 1 }
                    retainedStartIndex += 1
                    truncated = true
                }
                if retainedStartIndex > 0,
                   retainedStartIndex * 2 >= retained.count {
                    retained.removeFirst(retainedStartIndex)
                    retainedStartIndex = 0
                }
            }
            return true
        }

        while remaining > 0 {
            let requested = Int(min(UInt64(chunkSize), remaining))
            let chunk = try autoreleasepool {
                try handle.read(upToCount: requested) ?? Data()
            }
            guard !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count)
            autoreleasepool {
                instrumentation?.willProcessChunk?()
                accumulator.consume(chunk, handle: processLine)
            }
            instrumentation?.didDrainChunk?()
        }
        let tailWasEmitted = autoreleasepool {
            accumulator.finish(handle: processLine)
        }
        guard !foundRecordedDirectory || foundMatchingDirectory else {
            throw SupermuxHarnessSubagentTranscriptReaderError.unsafeTranscriptPath
        }
        let retainedSuffix = retained[retainedStartIndex...]
        return ParsedBytes(
            retainedEvents: retainedSuffix.map(\.event),
            retainedEventByteCount: retainedEventByteCount,
            truncated: truncated,
            droppedInitialEventCount: droppedInitialEventCount,
            appendedEvents: retainedSuffix.compactMap { entry in
                entry.isAppended ? entry.event.event : nil
            },
            pendingTail: accumulator.buffer,
            isSkippingOverlongLine: accumulator.isSkippingOverlongLine,
            pendingTailWasEmitted: tailWasEmitted,
            foundRecordedDirectory: foundRecordedDirectory,
            foundMatchingDirectory: foundMatchingDirectory
        )
    }

    private func metadataChange(
        from old: SupermuxHarnessSubagentTranscriptMetadata?,
        to new: SupermuxHarnessSubagentTranscriptMetadata?
    ) -> SupermuxHarnessSubagentTranscriptMetadataUpdate {
        guard old != new else { return .unchanged }
        return new.map(SupermuxHarnessSubagentTranscriptMetadataUpdate.value) ?? .deleted
    }

    private func continuityMatches(
        transcriptURL: URL,
        samples: [ContinuitySample]
    ) throws -> Bool {
        guard !samples.isEmpty else { return false }
        for sample in samples {
            let current = try readData(
                from: transcriptURL,
                offset: sample.offset,
                count: sample.data.count
            )
            guard current == sample.data else { return false }
        }
        return true
    }

    private func makeContinuitySamples(
        transcriptURL: URL,
        byteCount: UInt64
    ) throws -> [ContinuitySample] {
        guard byteCount > 0 else { return [] }
        let sampleLength = min(UInt64(continuitySampleByteCount), byteCount)
        let finalOffset = byteCount - sampleLength
        let halfSample = sampleLength / 2
        let centeredOffset = byteCount / 2 >= halfSample
            ? byteCount / 2 - halfSample
            : 0
        let middleOffset = byteCount > sampleLength
            ? min(finalOffset, centeredOffset)
            : 0
        let offsets = Array(Set([UInt64(0), middleOffset, finalOffset])).sorted()
        return try offsets.map { offset in
            ContinuitySample(
                offset: offset,
                data: try readData(
                    from: transcriptURL,
                    offset: offset,
                    count: Int(sampleLength)
                )
            )
        }
    }

    private func readData(
        from url: URL,
        offset: UInt64,
        count: Int
    ) throws -> Data {
        guard count > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    private func fingerprint(of url: URL) -> Fingerprint? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return Fingerprint(
            systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            creationDate: attributes[.creationDate] as? Date,
            modificationDate: attributes[.modificationDate] as? Date,
            byteCount: size.uint64Value
        )
    }
}
