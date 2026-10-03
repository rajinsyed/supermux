import Observation

/// One monotonic counter shared by the section model and every per-Mac
/// session, so a session's generation and epoch stamps are never reused —
/// even when a Mac's session is ended and a new one is created for the same
/// pairing. In-flight work captures a stamp and drops its answer once the
/// stamp is stale; a pushed detail screen rebinds when its epoch moves.
@MainActor
@Observable
final class SupermuxSessionCounter {
    /// The most recently issued stamp.
    private(set) var value = 0

    /// Issues a fresh stamp.
    func next() -> Int {
        value += 1
        return value
    }
}
