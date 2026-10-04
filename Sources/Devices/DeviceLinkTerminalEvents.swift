import CmuxMobileRPC
import CmuxMobileHost
import CmuxTerminalSizing
import CoreFoundation
import Foundation

/// A terminal-scoped event from a device link's host: raw PTY output for a
/// surface, or the host telling us the surface changed (its effective grid
/// rides along so a byte-stream mirror learns of remote resizes without
/// subscribing to render grids).
enum DeviceTerminalEvent: Equatable, Sendable {
    case bytes(sequence: UInt64?, data: Data)
    case updated(columns: Int?, rows: Int?)
    /// The link reconnected; the consumer must re-attach (viewport, replay, cursor).
    case linkReconnected
    /// The link is gone for now (transport lost, device offline, link stopped).
    case linkLost
    /// The bounded event queue overflowed; consult the current link and replay.
    case resyncRequired
    /// The host's shared-sizing state (`mobile.terminal.size_state`).
    case sizeState(TerminalSizingState, selfParticipantID: String?)
    /// Someone disconnected this Mac's view (`mobile.terminal.detached`).
    case sharingDetached(TerminalDetachReason, at: Date?)
    // SUPERMUX:begin terminal-stream-grid-viewer
    /// The bytes that follow were sent under this grid generation
    /// (`supermux.terminal_stream.v2`); sent only when it changes.
    case supermuxGridGeneration(UInt64)
    // SUPERMUX:end terminal-stream-grid-viewer

    /// The host's shared-sizing pushes this Mac subscribes to as a viewer.
    static let sizeStateTopic = "mobile.terminal.size_state"
    static let detachedTopic = "mobile.terminal.detached"

    /// Decode a `terminal.bytes` / `terminal.updated` envelope for its surface.
    /// Returns `(surfaceID, event)`; nil for payloads without a surface.
    static func decode(_ envelope: MobileEventEnvelope) -> (surfaceID: UUID, event: DeviceTerminalEvent)? {
        guard let payload = envelope.payloadJSON else { return nil }
        switch envelope.topic {
        case "terminal.bytes":
            guard let event = MobileTerminalBytesEvent.decode(payload),
                  let surfaceID = UUID(uuidString: event.surfaceID) else { return nil }
            return (surfaceID, .bytes(sequence: event.sequence, data: event.bytes))
        case "terminal.updated", DeviceTerminalGridPublisher.eventTopic:
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let raw = object["surface_id"] as? String,
                  let surfaceID = UUID(uuidString: raw) else { return nil }
            let columns = dimension(object["columns"])
            let rows = dimension(object["rows"])
            guard object["columns"] == nil || columns != nil,
                  object["rows"] == nil || rows != nil else { return nil }
            return (surfaceID, .updated(
                columns: columns,
                rows: rows
            ))
        case Self.sizeStateTopic:
            guard let event = try? MobileTerminalSizeStateEvent.decode(payload),
                  let surfaceID = UUID(uuidString: event.surfaceID) else { return nil }
            return (surfaceID, .sizeState(event.state, selfParticipantID: event.selfParticipantID))
        case Self.detachedTopic:
            guard let event = try? MobileTerminalDetachedEvent.decode(payload),
                  let surfaceID = UUID(uuidString: event.surfaceID) else { return nil }
            return (surfaceID, .sharingDetached(event.reason, at: event.at))
        default:
            return nil
        }
    }

    private static func dimension(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 1, value <= Double(UInt16.max), value.rounded(.towardZero) == value else { return nil }
        return number.intValue
    }
}

/// Fans one link's terminal events out to the mirror sessions attached to its
/// surfaces. Each session gets its own bounded stream; a session that falls
/// behind drops oldest frames and, on seeing a sequence gap, replays. Main
/// actor only, like the link that owns it.
@MainActor
final class DeviceLinkTerminalEvents {
    private var continuations: [UUID: [UUID: AsyncStream<DeviceTerminalEvent>.Continuation]] = [:]
    private var pendingControls: [UUID: [UUID: [DeviceTerminalEvent]]] = [:]

    // SUPERMUX:begin terminal-stream-viewer
    #if DEBUG
    /// Counts every decoded `terminal.bytes` payload (SupermuxTerminalStreamWatch).
    var supermuxOnBytes: ((UUID, Int) -> Void)?
    #endif
    // SUPERMUX:end terminal-stream-viewer
    // SUPERMUX:begin terminal-stream-grid-viewer
    /// The last grid generation forwarded per remote terminal.
    private var supermuxGridGenerations: [UUID: UInt64] = [:]
    // SUPERMUX:end terminal-stream-grid-viewer

    func stream(surfaceID: UUID) -> AsyncStream<DeviceTerminalEvent> {
        let id = UUID()
        // SUPERMUX:begin terminal-stream-viewer (upstream: `.bufferingNewest(512)`)
        return AsyncStream(bufferingPolicy: .bufferingNewest(SupermuxTerminalStream.sessionEventBufferLimit)) { continuation in
        // SUPERMUX:end terminal-stream-viewer
            continuations[surfaceID, default: [:]][id] = continuation
            pendingControls[surfaceID, default: [:]][id] = []
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.remove(surfaceID: surfaceID, id: id) }
            }
        }
    }

    var hasSubscribers: Bool { continuations.values.contains { !$0.isEmpty } }

    /// Deliver a host envelope to the sessions attached to its surface.
    /// Topics that `DeviceTerminalEvent` does not decode are ignored.
    func receive(_ envelope: MobileEventEnvelope) {
        guard let decoded = DeviceTerminalEvent.decode(envelope) else { return }
        // SUPERMUX:begin terminal-stream-viewer
        #if DEBUG
        if case .bytes(_, let data) = decoded.event { supermuxOnBytes?(decoded.surfaceID, data.count) }
        #endif
        // SUPERMUX:end terminal-stream-viewer
        // SUPERMUX:begin terminal-stream-grid-viewer (the generation goes ahead of the bytes sent under it)
        if case .bytes = decoded.event, let payload = envelope.payloadJSON,
           let generation = SupermuxTerminalGridTracker.generation(inBytesPayload: payload),
           supermuxGridGenerations[decoded.surfaceID] != generation {
            supermuxGridGenerations[decoded.surfaceID] = generation
            send(.supermuxGridGeneration(generation), surfaceID: decoded.surfaceID)
        }
        // SUPERMUX:end terminal-stream-grid-viewer
        send(decoded.event, surfaceID: decoded.surfaceID)
    }

    func send(_ event: DeviceTerminalEvent, surfaceID: UUID) {
        for (id, continuation) in continuations[surfaceID] ?? [:] {
            deliver(event, to: continuation, surfaceID: surfaceID, id: id)
        }
    }

    func broadcast(_ event: DeviceTerminalEvent) {
        // SUPERMUX:begin terminal-stream-grid-viewer (a new connection may be a new host process: forward its first generation)
        if event == .linkLost || event == .linkReconnected { supermuxGridGenerations.removeAll() }
        // SUPERMUX:end terminal-stream-grid-viewer
        for (surfaceID, surface) in continuations {
            for (id, continuation) in surface {
                deliver(event, to: continuation, surfaceID: surfaceID, id: id)
            }
        }
    }

    private func deliver(_ event: DeviceTerminalEvent, to continuation: AsyncStream<DeviceTerminalEvent>.Continuation, surfaceID: UUID, id: UUID) {
        let isControl: Bool
        switch event {
        // A detach must never be dropped by the bounded queue.
        case .linkReconnected, .linkLost, .resyncRequired, .sharingDetached: isControl = true
        case .bytes, .updated, .sizeState: isControl = false
        // SUPERMUX:begin terminal-stream-grid-viewer (a dropped one is followed by `resyncRequired`, a replay)
        case .supermuxGridGeneration: isControl = false
        // SUPERMUX:end terminal-stream-grid-viewer
        }
        if isControl {
            pendingControls[surfaceID, default: [:]][id, default: []].append(event)
            while let next = pendingControls[surfaceID]?[id]?.first {
                switch continuation.yield(next) {
                case .enqueued, .terminated:
                    pendingControls[surfaceID]?[id]?.removeFirst()
                case .dropped:
                    return
                @unknown default:
                    return
                }
            }
            return
        }
        if case .dropped = continuation.yield(event) {
            // Every overflow appends a fresh recovery marker. If a later byte
            // drops that marker, it appends another, so recovery cannot vanish.
            continuation.yield(.resyncRequired)
        }
    }

    func finishAll() {
        let all = continuations
        continuations = [:]
        pendingControls = [:]
        for surface in all.values {
            for continuation in surface.values { continuation.finish() }
        }
    }

    private func remove(surfaceID: UUID, id: UUID) {
        continuations[surfaceID]?[id] = nil
        pendingControls[surfaceID]?[id] = nil
        if continuations[surfaceID]?.isEmpty == true {
            continuations[surfaceID] = nil
        }
    }
}
