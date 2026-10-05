public import SupermuxMobileCore

/// The phone's Iroh runtime as the route features see it.
///
/// The app's runtime composition conforms; ``SupermuxPhoneRouteModel``
/// depends only on this, so it tests against a fake.
public protocol SupermuxPhoneRouteRuntime: Sendable {
    /// The selected path of every Mac session the phone has right now.
    func supermuxLinkPaths() async -> [SupermuxPhoneLinkPath]

    /// Keeps the direct addresses a Mac handed over its authenticated link,
    /// for the phone's direct-lane dials. Kept on the phone only.
    /// - Parameters:
    ///   - answer: The Mac's `route.candidates` answer.
    ///   - macDeviceID: The Mac that answered.
    ///   - instanceTag: Its build tag, if any.
    /// - Returns: ``SupermuxRouteCandidateFetchSchedule/Answer/stored``, or
    ///   ``SupermuxRouteCandidateFetchSchedule/Answer/empty`` when the answer
    ///   listed nothing the phone keeps (the old addresses stay), or
    ///   ``SupermuxRouteCandidateFetchSchedule/Answer/failed`` when it could
    ///   not be filed under the Mac (unknown Mac, another endpoint's answer).
    func supermuxRecordRouteCandidates(
        _ answer: SupermuxRouteCandidatesDTO,
        macDeviceID: String,
        instanceTag: String?
    ) async -> SupermuxRouteCandidateFetchSchedule.Answer

    /// Forgets a Mac's direct addresses: it said its direct paths are off
    /// (relay-only), so the phone must not dial it directly.
    /// - Parameters:
    ///   - macDeviceID: The Mac.
    ///   - instanceTag: Its build tag, if any.
    func supermuxForgetRouteCandidates(macDeviceID: String, instanceTag: String?) async
}
