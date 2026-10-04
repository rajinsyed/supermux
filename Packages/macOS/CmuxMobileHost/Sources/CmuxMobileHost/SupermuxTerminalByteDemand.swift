// SUPERMUX:begin terminal-stream-byte-demand (what streaming connections ask of each terminal's bytes — see SUPERMUX-TOUCHPOINTS.md)
public import Foundation
import os

/// What the connections that take `terminal.bytes` ask of each terminal,
/// across connections (Supermux terminal streaming).
///
/// Every connection's event queue reports its ask here whenever it changes
/// (its watch, its subscription, its close), so the byte producer can ask
/// before it encodes a PTY read:
/// - ``Delivery/foreground``: a connection looks at the terminal, or one
///   takes every terminal's bytes (a phone, an older Mac): send at once.
/// - ``Delivery/background``: every connection that watches the terminal has
///   it off screen: send it in larger, slower batches, still every byte in order.
/// - ``Delivery/unwatched``: no connection would admit its bytes: send
///   nothing (the byte tee's tail still holds them for a resume).
public final class SupermuxTerminalByteDemand: Sendable {
    public static let shared = SupermuxTerminalByteDemand()

    public enum Delivery: Sendable, Equatable {
        case foreground
        case background
        case unwatched
    }

    /// One subscribed connection's ask; `watched` nil takes every terminal.
    private struct Ask: Sendable {
        var watched: Set<UUID>?
        var background: Set<UUID>
    }

    private struct State: Sendable {
        var asks: [ObjectIdentifier: Ask] = [:]
        /// Connections that take every terminal's bytes.
        var topicWide = 0
        var watched: Set<UUID> = []
        var background: Set<UUID> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    /// How the producer sends `surfaceID`'s bytes now. One lock, no allocation.
    public func delivery(surfaceID: UUID) -> Delivery {
        state.withLock { state -> Delivery in
            if state.topicWide > 0 { return .foreground }
            if state.background.contains(surfaceID) { return .background }
            return state.watched.contains(surfaceID) ? .foreground : .unwatched
        }
    }

    /// Records the ask of a connection subscribed to `terminal.bytes`:
    /// `watched` nil takes every terminal, `background` names watched ones it
    /// has off screen.
    func update(connection: ObjectIdentifier, watched: Set<String>?, background: Set<String>) {
        let ask = Ask(watched: watched.map(Self.uuids), background: Self.uuids(background))
        state.withLock { state in
            state.asks[connection] = ask
            Self.derive(&state)
        }
    }

    /// Forgets a connection that no longer takes `terminal.bytes`.
    func remove(connection: ObjectIdentifier) {
        state.withLock { state in
            guard state.asks.removeValue(forKey: connection) != nil else { return }
            Self.derive(&state)
        }
    }

    /// A terminal is background when a connection watches it and none
    /// watches it on screen.
    private static func derive(_ state: inout State) {
        var topicWide = 0
        var watched = Set<UUID>()
        var foreground = Set<UUID>()
        for ask in state.asks.values {
            guard let ids = ask.watched else {
                topicWide += 1
                continue
            }
            watched.formUnion(ids)
            foreground.formUnion(ids.subtracting(ask.background))
        }
        state.topicWide = topicWide
        state.watched = watched
        state.background = watched.subtracting(foreground)
    }

    private static func uuids(_ strings: Set<String>) -> Set<UUID> {
        Set(strings.compactMap(UUID.init(uuidString:)))
    }
}
// SUPERMUX:end terminal-stream-byte-demand
