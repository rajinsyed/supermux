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
    /// The JSON the page receives, built once per envelope.
    let encodedData: Data?

    init(
        documentEpoch: String,
        firstSequence: UInt64,
        highestSequence: UInt64,
        events: [[String: Any]],
        encodedData: Data?
    ) {
        self.documentEpoch = documentEpoch
        self.firstSequence = firstSequence
        self.highestSequence = highestSequence
        self.events = events
        self.encodedData = encodedData
    }

    /// Encodes `events` from scratch; the transport instead joins the
    /// encodings it kept from enqueue.
    init(
        documentEpoch: String,
        firstSequence: UInt64,
        highestSequence: UInt64,
        events: [[String: Any]]
    ) {
        self.init(
            documentEpoch: documentEpoch,
            firstSequence: firstSequence,
            highestSequence: highestSequence,
            events: events,
            encodedData: SupermuxHarnessNativeEventEnvelopeEncoding.envelope(
                documentEpoch: documentEpoch,
                firstSequence: firstSequence,
                highestSequence: highestSequence,
                events: events
            )
        )
    }
}

/// The envelope's wire format:
/// `{"version":1,"documentEpoch":"…","firstSequence":N,"highestSequence":M,"events":[e1,e2,…]}`.
///
/// Each event is serialized once, at enqueue. A batch is sized by adding those
/// byte counts to the fixed frame and built by joining the kept bytes, so a
/// streaming event is never re-encoded on its way to the page.
enum SupermuxHarnessNativeEventEnvelopeEncoding {
    private static let separator = Data(",".utf8)
    private static let footer = Data("]}".utf8)

    /// Sorted keys keep tool input and permission previews, which the page
    /// shows with `JSON.stringify`, in a stable alphabetical order.
    static func encodedEvent(_ event: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
    }

    static func encodedEpoch(_ documentEpoch: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: documentEpoch, options: [.fragmentsAllowed])
    }

    /// The exact size of the joined envelope for these fields, without building it.
    static func envelopeByteCount(
        encodedEpoch: Data,
        firstSequence: UInt64,
        highestSequence: UInt64,
        eventByteCount: Int,
        eventCount: Int
    ) -> Int {
        let frameByteCount = header(
            encodedEpoch: encodedEpoch,
            firstSequence: firstSequence,
            highestSequence: highestSequence
        ).count + footer.count
        return frameByteCount + eventByteCount + max(0, eventCount - 1) * separator.count
    }

    static func envelope(
        encodedEpoch: Data,
        firstSequence: UInt64,
        highestSequence: UInt64,
        encodedEvents: [Data]
    ) -> Data {
        let head = header(
            encodedEpoch: encodedEpoch,
            firstSequence: firstSequence,
            highestSequence: highestSequence
        )
        let eventByteCount = encodedEvents.reduce(0) { $0 + $1.count }
        var data = Data(capacity: head.count + eventByteCount + encodedEvents.count + footer.count)
        data.append(head)
        for (index, event) in encodedEvents.enumerated() {
            if index > 0 { data.append(separator) }
            data.append(event)
        }
        data.append(footer)
        return data
    }

    static func envelope(
        documentEpoch: String,
        firstSequence: UInt64,
        highestSequence: UInt64,
        events: [[String: Any]]
    ) -> Data? {
        guard let encodedEpoch = encodedEpoch(documentEpoch) else { return nil }
        var encodedEvents: [Data] = []
        encodedEvents.reserveCapacity(events.count)
        for event in events {
            guard let encoded = encodedEvent(event) else { return nil }
            encodedEvents.append(encoded)
        }
        return envelope(
            encodedEpoch: encodedEpoch,
            firstSequence: firstSequence,
            highestSequence: highestSequence,
            encodedEvents: encodedEvents
        )
    }

    private static func header(
        encodedEpoch: Data,
        firstSequence: UInt64,
        highestSequence: UInt64
    ) -> Data {
        let version = SupermuxHarnessNativeEventEnvelope.currentVersion
        var header = Data(#"{"version":\#(version),"documentEpoch":"#.utf8)
        header.append(encodedEpoch)
        header.append(contentsOf: #","firstSequence":\#(firstSequence),"highestSequence":\#(highestSequence),"events":["#.utf8)
        return header
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
        return Int(exactly: double)
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
    private typealias Encoding = SupermuxHarnessNativeEventEnvelopeEncoding

    private struct PendingEvent {
        var sequence: UInt64
        let event: [String: Any]
        /// The event's only serialization; every batch joins these bytes.
        let encoded: Data
    }

    private let configuration: SupermuxHarnessNativeEventTransportConfiguration
    private let epochGenerator: () -> String
    private(set) var documentEpoch: String
    private var encodedDocumentEpoch: Data?
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
        encodedDocumentEpoch = Encoding.encodedEpoch(documentEpoch)
    }

    var pendingEventCount: Int { pending.count - pendingStartIndex }
    var hasInFlightEnvelope: Bool { inFlightEnvelope != nil }
    var backlogByteCount: Int { pendingEncodedByteCount }
    var highestEnqueuedSequence: UInt64 { nextSequence &- 1 }

    @discardableResult
    func beginDocumentNavigation() -> String {
        let liveEvents = pending[pendingStartIndex...].compactMap { $0 }
        documentEpoch = epochGenerator()
        encodedDocumentEpoch = Encoding.encodedEpoch(documentEpoch)
        pending = liveEvents.enumerated().map { index, item in
            PendingEvent(
                sequence: UInt64(index + 1),
                event: item.event,
                encoded: item.encoded
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
              let encodedDocumentEpoch,
              let encoded = Encoding.encodedEvent(event),
              encoded.count <= configuration.maximumBacklogBytes else {
            return .eventTooLarge
        }
        guard pendingEncodedByteCount <= configuration.maximumBacklogBytes - encoded.count else {
            return .recoveryRequired
        }
        let singleEnvelopeBytes = Encoding.envelopeByteCount(
            encodedEpoch: encodedDocumentEpoch,
            firstSequence: nextSequence,
            highestSequence: nextSequence,
            eventByteCount: encoded.count,
            eventCount: 1
        )
        guard singleEnvelopeBytes <= configuration.maximumEncodedBatchBytes else {
            return .eventTooLarge
        }

        pending.append(PendingEvent(
            sequence: nextSequence,
            event: event,
            encoded: encoded
        ))
        pendingEncodedByteCount += encoded.count
        nextSequence &+= 1
        return .accepted
    }

    /// The envelope to deliver: the in-flight one again after a failed
    /// evaluation, otherwise the longest pending prefix within
    /// `maximumEventCount` (the configured batch size when `nil`) and the
    /// encoded byte cap.
    func nextEnvelope(maximumEventCount: Int? = nil) -> SupermuxHarnessNativeEventEnvelope? {
        if let inFlightEnvelope { return inFlightEnvelope }
        guard pendingEventCount > 0, let encodedDocumentEpoch else { return nil }

        let countLimit = max(1, maximumEventCount ?? configuration.maximumEventCountPerBatch)
        let maximumCount = min(countLimit, pendingEventCount)
        let candidates = pending[pendingStartIndex..<(pendingStartIndex + maximumCount)].compactMap { $0 }
        guard let first = candidates.first else { return nil }

        var selectedCount = 0
        var selectedEventBytes = 0
        for candidate in candidates {
            let eventBytes = selectedEventBytes + candidate.encoded.count
            let envelopeBytes = Encoding.envelopeByteCount(
                encodedEpoch: encodedDocumentEpoch,
                firstSequence: first.sequence,
                highestSequence: candidate.sequence,
                eventByteCount: eventBytes,
                eventCount: selectedCount + 1
            )
            guard envelopeBytes <= configuration.maximumEncodedBatchBytes else { break }
            selectedCount += 1
            selectedEventBytes = eventBytes
        }
        let batch = candidates.prefix(selectedCount)
        guard let last = batch.last else { return nil }

        let envelope = SupermuxHarnessNativeEventEnvelope(
            documentEpoch: documentEpoch,
            firstSequence: first.sequence,
            highestSequence: last.sequence,
            events: batch.map(\.event),
            encodedData: Encoding.envelope(
                encodedEpoch: encodedDocumentEpoch,
                firstSequence: first.sequence,
                highestSequence: last.sequence,
                encodedEvents: batch.map(\.encoded)
            )
        )
        inFlightEnvelope = envelope
        inFlightEventCount = selectedCount
        return envelope
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
            pendingEncodedByteCount -= item.encoded.count
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
