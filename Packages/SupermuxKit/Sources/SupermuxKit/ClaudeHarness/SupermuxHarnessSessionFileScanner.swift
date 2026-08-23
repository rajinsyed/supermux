import Darwin
import Foundation

/// Streams JSONL prefixes and targeted ranges without loading whole files.
struct SupermuxHarnessSessionFileScanner: Sendable {
    private struct PreparedScan: Sendable {
        let descriptor: Int32
        let observation: SupermuxHarnessSessionFileObservation
    }

    private let recordMapper = SupermuxHarnessSessionRecordMapper()

    func observe(_ fileURL: URL) async throws -> SupermuxHarnessSessionFileObservation {
        try await Task.detached(priority: .utility) {
            var status = stat()
            guard Darwin.lstat(fileURL.path, &status) == 0 else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            guard (status.st_mode & S_IFMT) == S_IFREG else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            return SupermuxHarnessSessionFileObservation(fileURL: fileURL, status: status)
        }.value
    }

    func scan(
        _ fileURL: URL,
        plan: SupermuxHarnessSessionScanPlan,
        observer: (@Sendable (URL) async -> Void)?
    ) async throws -> SupermuxHarnessSessionScanResult {
        let prepared = try await Task.detached(priority: .utility) {
            try Self.prepareScan(fileURL)
        }.value
        if let observer {
            await observer(fileURL)
        }
        if Task.isCancelled {
            Darwin.close(prepared.descriptor)
            throw CancellationError()
        }
        return try await Task.detached(priority: .utility) {
            try Self.scanSynchronously(fileURL, prepared: prepared, plan: plan)
        }.value
    }

    func readSelectedRecords(
        _ fileURL: URL,
        expected: SupermuxHarnessSessionFileObservation,
        expectedFingerprint: SupermuxHarnessSessionContinuityFingerprint,
        selections: [SupermuxHarnessSessionRecordSelection],
        fallbackSessionID: String,
        chunkSize: Int
    ) async throws -> SupermuxHarnessSessionSelectedRead {
        let recordMapper = self.recordMapper
        return try await Task.detached(priority: .utility) {
            try Self.readSelectedRecordsSynchronously(
                fileURL,
                expected: expected,
                expectedFingerprint: expectedFingerprint,
                selections: selections,
                fallbackSessionID: fallbackSessionID,
                chunkSize: max(1, chunkSize),
                recordMapper: recordMapper
            )
        }.value
    }

    private static func prepareScan(_ fileURL: URL) throws -> PreparedScan {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        do {
            let observation = try observation(fileURL: fileURL, descriptor: descriptor)
            return PreparedScan(descriptor: descriptor, observation: observation)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func scanSynchronously(
        _ fileURL: URL,
        prepared: PreparedScan,
        plan: SupermuxHarnessSessionScanPlan
    ) throws -> SupermuxHarnessSessionScanResult {
        let descriptor = prepared.descriptor
        defer { Darwin.close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let before = prepared.observation
        let chunkSize = max(1, plan.readChunkBytes)
        var maximumReadChunkBytes = 0
        let canAppend = !plan.forceReset &&
            plan.previousObservation?.identity == before.identity &&
            before.size >= (plan.previousObservation?.size ?? UInt64.max) &&
            validateContinuity(
                plan.previousFingerprint,
                expectedObservation: plan.previousObservation,
                before: before,
                handle: handle,
                chunkSize: chunkSize,
                maximumReadChunkBytes: &maximumReadChunkBytes
            )
        let didReset = !canAppend
        let readOffset = canAppend ? (plan.previousObservation?.size ?? 0) : 0
        let previousCursor = canAppend ? plan.previousCursor : nil
        var buffer = previousCursor?.isSkippingOverlongTail == true
            ? Data()
            : (previousCursor?.provisionalTail ?? Data())
        var committedOffset = previousCursor?.committedOffset ?? 0
        var bufferAbsoluteOffset = previousCursor?.isSkippingOverlongTail == true
            ? readOffset
            : committedOffset
        var isSkippingOverlongLine = previousCursor?.isSkippingOverlongTail ?? false
        var metadataDelta = SupermuxHarnessSessionMetadataIndex()
        var historyDelta = plan.includesHistory
            ? SupermuxHarnessSessionHistoryIndex()
            : nil
        var bytesRead: UInt64 = 0
        var parsedRecordCount = 0
        var remaining = before.size - readOffset
        let newline = UInt8(ascii: "\n")
        try handle.seek(toOffset: readOffset)

        while remaining > 0 {
            let requestCount = Int(min(UInt64(chunkSize), remaining))
            let chunk: Data = try autoreleasepool {
                try handle.read(upToCount: requestCount) ?? Data()
            }
            guard !chunk.isEmpty else { break }
            maximumReadChunkBytes = max(maximumReadChunkBytes, chunk.count)
            bytesRead += UInt64(chunk.count)
            remaining -= UInt64(chunk.count)
            autoreleasepool {
                buffer.append(chunk)
                var consumed = 0
                while let newlineIndex = buffer[(buffer.startIndex + consumed)...]
                    .firstIndex(of: newline) {
                    let lineRange = (buffer.startIndex + consumed)..<newlineIndex
                    let absoluteNewline = bufferAbsoluteOffset +
                        UInt64(newlineIndex - buffer.startIndex)
                    if isSkippingOverlongLine {
                        isSkippingOverlongLine = false
                    } else if !lineRange.isEmpty,
                              lineRange.count <= SupermuxLineReader.maximumLineBytes {
                        let range = SupermuxHarnessSessionRecordRange(
                            lowerBound: bufferAbsoluteOffset + UInt64(consumed),
                            upperBound: absoluteNewline
                        )
                        if let record = SupermuxHarnessSessionIndexedRecord(
                            data: Data(buffer[lineRange]),
                            range: range,
                            includesHistory: plan.includesHistory
                        ) {
                            metadataDelta.apply(record)
                            historyDelta?.apply(record)
                            parsedRecordCount += 1
                        }
                    }
                    consumed = newlineIndex - buffer.startIndex + 1
                    committedOffset = absoluteNewline + 1
                }
                if consumed > 0 {
                    buffer.removeFirst(consumed)
                    bufferAbsoluteOffset += UInt64(consumed)
                }
            }
            if buffer.count > SupermuxLineReader.maximumLineBytes {
                buffer.removeAll(keepingCapacity: false)
                bufferAbsoluteOffset = readOffset + bytesRead
                isSkippingOverlongLine = true
            }
        }

        let provisionalRecord: SupermuxHarnessSessionIndexedRecord?
        if !isSkippingOverlongLine,
           !buffer.isEmpty,
           buffer.count <= SupermuxLineReader.maximumLineBytes {
            provisionalRecord = autoreleasepool {
                SupermuxHarnessSessionIndexedRecord(
                    data: buffer,
                    range: SupermuxHarnessSessionRecordRange(
                        lowerBound: committedOffset,
                        upperBound: before.size
                    ),
                    includesHistory: plan.includesHistory
                )
            }
            if provisionalRecord != nil {
                parsedRecordCount += 1
            }
        } else {
            provisionalRecord = nil
        }
        let fingerprint = try makeFingerprint(
            handle: handle,
            size: before.size,
            byteBudget: max(1, plan.continuityValidationBytes),
            chunkSize: chunkSize,
            maximumReadChunkBytes: &maximumReadChunkBytes
        )
        let after = try observation(fileURL: fileURL, descriptor: descriptor)
        let pathAfter = try pathObservation(fileURL)
        return SupermuxHarnessSessionScanResult(
            before: before,
            after: after,
            pathAfter: pathAfter,
            metadataDelta: metadataDelta,
            historyDelta: historyDelta,
            provisionalRecord: provisionalRecord,
            cursor: SupermuxHarnessSessionScanCursor(
                committedOffset: committedOffset,
                provisionalTail: isSkippingOverlongLine ? Data() : buffer,
                isSkippingOverlongTail: isSkippingOverlongLine
            ),
            fingerprint: fingerprint,
            didReset: didReset,
            readOffset: readOffset,
            bytesRead: bytesRead,
            parsedRecordCount: parsedRecordCount,
            maximumReadChunkBytes: maximumReadChunkBytes
        )
    }

    private static func readSelectedRecordsSynchronously(
        _ fileURL: URL,
        expected: SupermuxHarnessSessionFileObservation,
        expectedFingerprint: SupermuxHarnessSessionContinuityFingerprint,
        selections: [SupermuxHarnessSessionRecordSelection],
        fallbackSessionID: String,
        chunkSize: Int,
        recordMapper: SupermuxHarnessSessionRecordMapper
    ) throws -> SupermuxHarnessSessionSelectedRead {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { Darwin.close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let before = try observation(fileURL: fileURL, descriptor: descriptor)
        var maximumReadChunkBytes = 0
        let preservesExpectedPrefix = before == expected || (
            before.isSameOrAppend(of: expected) &&
                validateContinuity(
                    expectedFingerprint,
                    expectedObservation: expected,
                    before: before,
                    handle: handle,
                    chunkSize: chunkSize,
                    maximumReadChunkBytes: &maximumReadChunkBytes
                )
        )
        guard preservesExpectedPrefix else {
            return SupermuxHarnessSessionSelectedRead(
                before: before,
                after: before,
                pathAfter: try pathObservation(fileURL),
                prefixValidated: false,
                events: [],
                recordCount: 0,
                bytesRead: 0,
                maximumReadChunkBytes: maximumReadChunkBytes
            )
        }

        var events: [SupermuxHarnessJSONObject] = []
        var bytesRead: UInt64 = 0
        for selection in selections {
            guard selection.range.upperBound <= before.size,
                  selection.range.count <= UInt64(SupermuxLineReader.maximumLineBytes) else {
                continue
            }
            try handle.seek(toOffset: selection.range.lowerBound)
            let data = try readExactly(
                handle,
                count: selection.range.count,
                chunkSize: chunkSize,
                maximumReadChunkBytes: &maximumReadChunkBytes
            )
            bytesRead += UInt64(data.count)
            guard UInt64(data.count) == selection.range.count else { continue }
            if let event = autoreleasepool(invoking: { () -> SupermuxHarnessJSONObject? in
                guard let value = try? JSONSerialization.jsonObject(with: data),
                      let record = value as? [String: Any] else {
                    return nil
                }
                return recordMapper.protocolEvent(
                    from: record,
                    fallbackSessionID: fallbackSessionID
                )
            }) {
                events.append(event)
            }
        }
        let after = try observation(fileURL: fileURL, descriptor: descriptor)
        let pathAfter = try pathObservation(fileURL)
        let prefixValidated = after.isSameOrAppend(of: before)
            && pathAfter.isSameOrAppend(of: before)
            && (
                after == expected || validateContinuity(
                    expectedFingerprint,
                    expectedObservation: expected,
                    before: after,
                    handle: handle,
                    chunkSize: chunkSize,
                    maximumReadChunkBytes: &maximumReadChunkBytes
                )
            )
        return SupermuxHarnessSessionSelectedRead(
            before: before,
            after: after,
            pathAfter: pathAfter,
            prefixValidated: prefixValidated,
            events: events,
            recordCount: selections.count,
            bytesRead: bytesRead,
            maximumReadChunkBytes: maximumReadChunkBytes
        )
    }

    private static func validateContinuity(
        _ fingerprint: SupermuxHarnessSessionContinuityFingerprint?,
        expectedObservation: SupermuxHarnessSessionFileObservation?,
        before: SupermuxHarnessSessionFileObservation,
        handle: FileHandle,
        chunkSize: Int,
        maximumReadChunkBytes: inout Int
    ) -> Bool {
        guard let fingerprint,
              let expectedObservation,
              fingerprint.observedSize == expectedObservation.size,
              before.size >= fingerprint.observedSize else {
            return false
        }
        for sample in fingerprint.samples {
            guard sample.offset + UInt64(sample.bytes.count) <= before.size else {
                return false
            }
            do {
                try handle.seek(toOffset: sample.offset)
                let bytes = try readExactly(
                    handle,
                    count: UInt64(sample.bytes.count),
                    chunkSize: chunkSize,
                    maximumReadChunkBytes: &maximumReadChunkBytes
                )
                guard bytes == sample.bytes else { return false }
            } catch {
                return false
            }
        }
        return true
    }

    private static func makeFingerprint(
        handle: FileHandle,
        size: UInt64,
        byteBudget: Int,
        chunkSize: Int,
        maximumReadChunkBytes: inout Int
    ) throws -> SupermuxHarnessSessionContinuityFingerprint {
        guard size > 0 else {
            return SupermuxHarnessSessionContinuityFingerprint(
                observedSize: 0,
                samples: []
            )
        }
        let budget = UInt64(max(1, byteBudget))
        let sampleRanges: [(offset: UInt64, count: UInt64)]
        if size <= budget {
            sampleRanges = [(0, size)]
        } else if budget < 4 {
            sampleRanges = [(0, budget)]
        } else {
            let window = budget / 4
            let lastOffset = size - window
            let offsets = [
                UInt64(0),
                min(lastOffset, size / 3),
                min(lastOffset, (size / 3) * 2),
                lastOffset,
            ]
            var uniqueOffsets: [UInt64] = []
            for offset in offsets where !uniqueOffsets.contains(offset) {
                uniqueOffsets.append(offset)
            }
            sampleRanges = uniqueOffsets.map { offset in
                (offset, min(window, size - offset))
            }
        }
        var samples: [SupermuxHarnessSessionContinuityFingerprint.Sample] = []
        for range in sampleRanges {
            try handle.seek(toOffset: range.offset)
            let bytes = try readExactly(
                handle,
                count: range.count,
                chunkSize: chunkSize,
                maximumReadChunkBytes: &maximumReadChunkBytes
            )
            guard UInt64(bytes.count) == range.count else {
                throw CocoaError(.fileReadUnknown)
            }
            samples.append(.init(offset: range.offset, bytes: bytes))
        }
        return SupermuxHarnessSessionContinuityFingerprint(
            observedSize: size,
            samples: samples
        )
    }

    private static func readExactly(
        _ handle: FileHandle,
        count: UInt64,
        chunkSize: Int,
        maximumReadChunkBytes: inout Int
    ) throws -> Data {
        var result = Data()
        var remaining = count
        while remaining > 0 {
            let requestCount = Int(min(UInt64(max(1, chunkSize)), remaining))
            let chunk: Data = try autoreleasepool {
                try handle.read(upToCount: requestCount) ?? Data()
            }
            guard !chunk.isEmpty else { break }
            maximumReadChunkBytes = max(maximumReadChunkBytes, chunk.count)
            autoreleasepool {
                result.append(chunk)
            }
            remaining -= UInt64(chunk.count)
        }
        return result
    }

    private static func pathObservation(
        _ fileURL: URL
    ) throws -> SupermuxHarnessSessionFileObservation {
        var status = stat()
        guard Darwin.lstat(fileURL.path, &status) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return SupermuxHarnessSessionFileObservation(fileURL: fileURL, status: status)
    }

    private static func observation(
        fileURL: URL,
        descriptor: Int32
    ) throws -> SupermuxHarnessSessionFileObservation {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return SupermuxHarnessSessionFileObservation(fileURL: fileURL, status: status)
    }
}
