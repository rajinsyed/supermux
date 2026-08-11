import Foundation

/// One queued user input awaiting dispatch to the Claude process.
public struct ClaudeQueuedInput: Sendable, Equatable, Identifiable, Codable {
    /// Delivery state of one queued input.
    ///
    /// `uncertain` means the stdin write succeeded but the process ended before
    /// authoritative evidence; such input is never auto-resent.
    public enum State: String, Sendable, Codable {
        case queued
        case dispatching
        case acknowledged
        case uncertain
        case cancelled
    }

    public let id: UUID
    public var text: String
    public let createdAt: Date
    public var state: State

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date(), state: State = .queued) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.state = state
    }
}

/// FIFO input queue with explicit delivery-state transitions.
///
/// Only one turn is active per process: `nextForDispatch()` yields an item
/// only when nothing else is dispatching. A crash pauses the queue; dispatch
/// resumes only after explicit `resume()`.
public struct ClaudeInputQueue: Sendable, Equatable {
    public private(set) var entries: [ClaudeQueuedInput] = []
    public private(set) var isPaused = false

    public init() {}

    public mutating func enqueue(_ input: ClaudeQueuedInput) {
        entries.append(input)
    }

    /// The next queued entry eligible for dispatch, or `nil` when paused,
    /// empty, or an item is already in flight.
    public func nextForDispatch() -> ClaudeQueuedInput? {
        guard !isPaused else { return nil }
        guard !entries.contains(where: { $0.state == .dispatching }) else { return nil }
        return entries.first(where: { $0.state == .queued })
    }

    /// queued → dispatching. Returns `false` for invalid transitions.
    @discardableResult
    public mutating func markDispatching(id: UUID) -> Bool {
        transition(id: id, from: [.queued], to: .dispatching)
    }

    /// dispatching → acknowledged (authoritative turn evidence observed).
    @discardableResult
    public mutating func markAcknowledged(id: UUID) -> Bool {
        transition(id: id, from: [.dispatching], to: .acknowledged)
    }

    /// dispatching → uncertain (process ended before acknowledgment).
    @discardableResult
    public mutating func markUncertain(id: UUID) -> Bool {
        transition(id: id, from: [.dispatching], to: .uncertain)
    }

    /// queued/dispatching → cancelled (user removal).
    @discardableResult
    public mutating func cancel(id: UUID) -> Bool {
        transition(id: id, from: [.queued, .dispatching], to: .cancelled)
    }

    /// Marks any in-flight dispatch uncertain and pauses further dispatch.
    public mutating func pauseForProcessEnd() {
        isPaused = true
        for index in entries.indices where entries[index].state == .dispatching {
            entries[index].state = .uncertain
        }
    }

    /// Explicitly resumes dispatch after a pause.
    public mutating func resume() {
        isPaused = false
    }

    /// Removes terminal entries (acknowledged/cancelled), keeping history slim.
    public mutating func compact() {
        entries.removeAll { $0.state == .acknowledged || $0.state == .cancelled }
    }

    private mutating func transition(
        id: UUID,
        from allowed: Set<ClaudeQueuedInput.State>,
        to newState: ClaudeQueuedInput.State
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              allowed.contains(entries[index].state) else { return false }
        entries[index].state = newState
        return true
    }
}
