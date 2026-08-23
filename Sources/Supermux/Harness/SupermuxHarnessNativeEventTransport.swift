import CoreFoundation
import Foundation

struct SupermuxHarnessNativeEventTransportConfiguration {
    var maximumEventCountPerBatch: Int
    var maximumEncodedBatchBytes: Int
    var maximumBacklogBytes: Int

    init(
        maximumEventCountPerBatch: Int = 64,
        maximumEncodedBatchBytes: Int = 8 * 1024 * 1024,
        maximumBacklogBytes: Int = 32 * 1024 * 1024
    ) {
        self.maximumEventCountPerBatch = max(1, maximumEventCountPerBatch)
        self.maximumEncodedBatchBytes = max(1, maximumEncodedBatchBytes)
        self.maximumBacklogBytes = max(1, maximumBacklogBytes)
    }
}

enum SupermuxHarnessNativeEventEnqueueResult: Equatable {
    case accepted
    case recoveryRequired
    case eventTooLarge
}

struct SupermuxHarnessNativeEventEnvelope {
    static let currentVersion = 1

    let documentEpoch: String
    let firstSequence: UInt64
    let highestSequence: UInt64
    let events: [[String: Any]]

    var dictionary: [String: Any] {
        [
            "version": Self.currentVersion,
            "documentEpoch": documentEpoch,
            "firstSequence": firstSequence,
            "highestSequence": highestSequence,
            "events": events,
        ]
    }

    var encodedData: Data? {
        try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
    }
}

struct SupermuxHarnessNativeEventAcknowledgement {
    private static let maximumJavaScriptInteger = 9_007_199_254_740_991.0

    let version: Int
    let documentEpoch: String
    let highestSequence: UInt64

    init?(body: Any?) {
        guard let body = body as? [String: Any],
              let version = Self.integer(body["version"]),
              let documentEpoch = body["documentEpoch"] as? String,
              !documentEpoch.isEmpty,
              let highestSequence = Self.uint64(body["highestSequence"]) else {
            return nil
        }
        self.version = version
        self.documentEpoch = documentEpoch
        self.highestSequence = highestSequence
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value) else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min),
              double <= Double(Int.max) else {
            return nil
        }
        return Int(double)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        guard let number = number(value) else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= 0,
              double <= maximumJavaScriptInteger else {
            return nil
        }
        return UInt64(double)
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number
    }
}

/// One-document, one-in-flight native event queue.
///
/// The queue retains every event until JavaScript returns the exact epoch and
/// highest sequence for the current envelope. `recoveryRequired` is flow
/// control: the producer waits for an acknowledgement and retries the enqueue,
/// so the byte budget never turns into event loss.
@MainActor
final class SupermuxHarnessNativeEventTransport {
    private struct PendingEvent {
        var sequence: UInt64
        let event: [String: Any]
        let encodedByteCount: Int
    }

    private let configuration: SupermuxHarnessNativeEventTransportConfiguration
    private let epochGenerator: () -> String
    private(set) var documentEpoch: String
    private(set) var nextSequence: UInt64 = 1
    private var pending: [PendingEvent?] = []
    private var pendingStartIndex = 0
    private var pendingEncodedByteCount = 0
    private var inFlightEnvelope: SupermuxHarnessNativeEventEnvelope?
    private var inFlightEventCount = 0

    init(
        configuration: SupermuxHarnessNativeEventTransportConfiguration = .init(),
        epochGenerator: @escaping () -> String = { UUID().uuidString }
    ) {
        self.configuration = configuration
        self.epochGenerator = epochGenerator
        documentEpoch = epochGenerator()
    }

    var pendingEventCount: Int { pending.count - pendingStartIndex }
    var hasInFlightEnvelope: Bool { inFlightEnvelope != nil }
    var backlogByteCount: Int { pendingEncodedByteCount }
    var highestEnqueuedSequence: UInt64 { nextSequence &- 1 }

    @discardableResult
    func beginDocumentNavigation() -> String {
        let liveEvents = pending[pendingStartIndex...].compactMap { $0 }
        documentEpoch = epochGenerator()
        pending = liveEvents.enumerated().map { index, item in
            PendingEvent(
                sequence: UInt64(index + 1),
                event: item.event,
                encodedByteCount: item.encodedByteCount
            )
        }
        pendingStartIndex = 0
        nextSequence = UInt64(pending.count + 1)
        inFlightEnvelope = nil
        inFlightEventCount = 0
        return documentEpoch
    }

    func enqueue(_ event: [String: Any]) -> SupermuxHarnessNativeEventEnqueueResult {
        guard nextSequence < UInt64.max,
              let encoded = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              encoded.count <= configuration.maximumBacklogBytes else {
            return .eventTooLarge
        }
        guard pendingEncodedByteCount <= configuration.maximumBacklogBytes - encoded.count else {
            return .recoveryRequired
        }
        let singleEnvelope = SupermuxHarnessNativeEventEnvelope(
            documentEpoch: documentEpoch,
            firstSequence: nextSequence,
            highestSequence: nextSequence,
            events: [event]
        )
        guard let singleEnvelopeBytes = singleEnvelope.encodedData?.count,
              singleEnvelopeBytes <= configuration.maximumEncodedBatchBytes else {
            return .eventTooLarge
        }

        pending.append(PendingEvent(
            sequence: nextSequence,
            event: event,
            encodedByteCount: encoded.count
        ))
        pendingEncodedByteCount += encoded.count
        nextSequence &+= 1
        return .accepted
    }

    func nextEnvelope() -> SupermuxHarnessNativeEventEnvelope? {
        if let inFlightEnvelope { return inFlightEnvelope }
        guard pendingEventCount > 0 else { return nil }

        let maximumCount = min(configuration.maximumEventCountPerBatch, pendingEventCount)
        let candidates = pending[pendingStartIndex..<(pendingStartIndex + maximumCount)].compactMap { $0 }
        guard let first = candidates.first else { return nil }

        var lowerBound = 1
        var upperBound = candidates.count
        var selectedCount = 0
        var selectedEnvelope: SupermuxHarnessNativeEventEnvelope?
        while lowerBound <= upperBound {
            let candidateCount = lowerBound + (upperBound - lowerBound) / 2
            let batch = candidates.prefix(candidateCount)
            guard let last = batch.last else { return nil }
            let envelope = SupermuxHarnessNativeEventEnvelope(
                documentEpoch: documentEpoch,
                firstSequence: first.sequence,
                highestSequence: last.sequence,
                events: batch.map(\.event)
            )
            guard let byteCount = envelope.encodedData?.count else { return nil }
            if byteCount <= configuration.maximumEncodedBatchBytes {
                selectedCount = candidateCount
                selectedEnvelope = envelope
                lowerBound = candidateCount + 1
            } else {
                upperBound = candidateCount - 1
            }
        }

        guard let selectedEnvelope, selectedCount > 0 else { return nil }
        inFlightEnvelope = selectedEnvelope
        inFlightEventCount = selectedCount
        return selectedEnvelope
    }

    @discardableResult
    func acknowledge(
        _ acknowledgement: SupermuxHarnessNativeEventAcknowledgement
    ) -> Bool {
        guard acknowledgement.version == SupermuxHarnessNativeEventEnvelope.currentVersion,
              acknowledgement.documentEpoch == documentEpoch,
              let inFlightEnvelope,
              acknowledgement.highestSequence == inFlightEnvelope.highestSequence,
              inFlightEventCount > 0 else {
            return false
        }

        let acknowledgedEndIndex = pendingStartIndex + inFlightEventCount
        for index in pendingStartIndex..<acknowledgedEndIndex {
            guard let item = pending[index] else { continue }
            pendingEncodedByteCount -= item.encodedByteCount
            pending[index] = nil
        }
        pendingStartIndex = acknowledgedEndIndex
        self.inFlightEnvelope = nil
        inFlightEventCount = 0
        compactPendingStorageIfNeeded()
        return true
    }

    func discardAll() {
        pending.removeAll(keepingCapacity: false)
        pendingStartIndex = 0
        pendingEncodedByteCount = 0
        inFlightEnvelope = nil
        inFlightEventCount = 0
        nextSequence = 1
    }

    /// A failed evaluation changes no queue state; `nextEnvelope()` returns the
    /// same epoch, range, and events for an at-least-once retry.
    func deliveryFailed() {}

    private func compactPendingStorageIfNeeded() {
        if pendingStartIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingStartIndex = 0
            return
        }
        guard pendingStartIndex >= 1_024 else { return }
        pending.removeFirst(pendingStartIndex)
        pendingStartIndex = 0
    }
}
