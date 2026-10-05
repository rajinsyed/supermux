public import SupermuxMobileCore

/// Asks one Mac for its direct addresses (`mobile.supermux.route.candidates`).
public protocol SupermuxRouteCandidatesCalling: Sendable {
    /// The Mac's iroh endpoint id and its direct addresses.
    func routeCandidates() async throws -> SupermuxRouteCandidatesDTO
}
