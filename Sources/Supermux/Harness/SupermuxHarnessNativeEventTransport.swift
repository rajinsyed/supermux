import Foundation

struct SupermuxHarnessNativeEventTransportConfiguration {
    var maximumEventCountPerBatch = 64
    var maximumEncodedBatchBytes = 256 * 1024
    var maximumBacklogBytes = 8 * 1024 * 1024
}

enum SupermuxHarnessNativeEventEnqueueResult: Equatable {
    case accepted
    case recoveryRequired
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
    let version: Int
    let documentEpoch: String
    let highestSequence: UInt64

    init?(body: Any?) {
        guard let body = body as? [String: Any],
              let version = Self.integer(body["version"]),
              let documentEpoch = body["documentEpoch"] as? String,
              let highestSequence = Self.uint64(body["highestSequence"]) else {
            return nil
        }
        self.version = version
        self.documentEpoch = documentEpoch
        self.highestSequence = highestSequence
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.intValue
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.int64Value >= 0 else {
            return nil
        }
        return number.uint64Value
    }
}

/// Testable state seam for the native-to-document event queue.
///
/// This type is intentionally not wired into the renderer yet. The transport
/// behavior lands in the follow-up implementation commit after its executable
/// regression contract is committed separately.
@MainActor
final class SupermuxHarnessNativeEventTransport {
    private struct PendingEvent {
        let sequence: UInt64
        let event: [String: Any]
        let encodedByteCount: Int
    }

    private let configuration: SupermuxHarnessNativeEventTransportConfiguration
    private let epochGenerator: () -> String
    private(set) var documentEpoch: String
    private(set) var nextSequence: UInt64 = 1
    private var pending: [PendingEvent] = []
    private var inFlightEnvelope: SupermuxHarnessNativeEventEnvelope?

    init(
        configuration: SupermuxHarnessNativeEventTransportConfiguration = .init(),
        epochGenerator: @escaping () -> String = { UUID().uuidString }
    ) {
        self.configuration = configuration
        self.epochGenerator = epochGenerator
        documentEpoch = epochGenerator()
    }

    var pendingEventCount: Int { pending.count }
    var hasInFlightEnvelope: Bool { inFlightEnvelope != nil }
    var backlogByteCount: Int { pending.reduce(0) { $0 + $1.encodedByteCount } }
    var highestEnqueuedSequence: UInt64 { nextSequence &- 1 }

    @discardableResult
    func beginDocumentNavigation() -> String {
        documentEpoch = epochGenerator()
        nextSequence = 1
        inFlightEnvelope = nil
        pending = pending.enumerated().map { index, item in
            PendingEvent(
                sequence: UInt64(index + 1),
                event: item.event,
                encodedByteCount: item.encodedByteCount
            )
        }
        nextSequence = UInt64(pending.count + 1)
        return documentEpoch
    }

    func enqueue(_ event: [String: Any]) -> SupermuxHarnessNativeEventEnqueueResult {
        guard let encoded = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else {
            return .recoveryRequired
        }
        pending.append(PendingEvent(
            sequence: nextSequence,
            event: event,
            encodedByteCount: encoded.count
        ))
        nextSequence &+= 1
        return .accepted
    }

    func nextEnvelope() -> SupermuxHarnessNativeEventEnvelope? {
        if let inFlightEnvelope { return inFlightEnvelope }
        guard !pending.isEmpty else { return nil }
        let count = min(configuration.maximumEventCountPerBatch, pending.count)
        let batch = Array(pending.prefix(count))
        pending.removeFirst(count)
        let envelope = SupermuxHarnessNativeEventEnvelope(
            documentEpoch: documentEpoch,
            firstSequence: batch[0].sequence,
            highestSequence: batch[batch.count - 1].sequence,
            events: batch.map(\.event)
        )
        inFlightEnvelope = envelope
        return envelope
    }

    @discardableResult
    func acknowledge(_ acknowledgement: SupermuxHarnessNativeEventAcknowledgement) -> Bool {
        guard acknowledgement.version == SupermuxHarnessNativeEventEnvelope.currentVersion,
              acknowledgement.documentEpoch == documentEpoch,
              acknowledgement.highestSequence == inFlightEnvelope?.highestSequence else {
            return false
        }
        inFlightEnvelope = nil
        return true
    }

    func deliveryFailed() {
        inFlightEnvelope = nil
    }
}
