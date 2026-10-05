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
    func supermuxRecordRouteCandidates(
        _ answer: SupermuxRouteCandidatesDTO,
        macDeviceID: String,
        instanceTag: String?
    ) async
}
