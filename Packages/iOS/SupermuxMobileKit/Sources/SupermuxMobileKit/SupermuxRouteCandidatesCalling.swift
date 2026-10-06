public import SupermuxMobileCore

/// Asks one Mac for its direct addresses (`mobile.supermux.route.candidates`).
public protocol SupermuxRouteCandidatesCalling: Sendable {
    /// The Mac's iroh endpoint id and its direct addresses. Throws
    /// ``SupermuxRouteCandidatesRefusal`` when the Mac answered with an
    /// error code (`not_ready`, `direct_off`).
    func routeCandidates() async throws -> SupermuxRouteCandidatesDTO
}

/// A Mac refused `mobile.supermux.route.candidates` with an error code
/// (``SupermuxRouteCandidates/notReadyErrorCode``,
/// ``SupermuxRouteCandidates/directOffErrorCode``, or another).
public struct SupermuxRouteCandidatesRefusal: Error, Equatable, Sendable {
    /// The Mac's error code.
    public let code: String

    public init(code: String) {
        self.code = code
    }
}
