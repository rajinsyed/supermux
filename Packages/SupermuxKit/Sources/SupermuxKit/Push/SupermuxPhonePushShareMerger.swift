import Foundation

/// Decides what a Mac keeps when another Mac shares push state with it.
/// Pure: the service applies the outcome to its files.
public enum SupermuxPhonePushShareMerger {
    /// What happens to the incoming provider identity.
    public enum CredentialOutcome: String, Sendable, Equatable {
        /// No identity was sent.
        case absent
        /// The identity is malformed (identifiers or key) and is ignored.
        case invalid
        /// None was installed here; the incoming one is installed.
        case install
        /// The same identity is already installed; nothing is written.
        case unchanged
        /// A different identity (or a partial one) is installed here. It is
        /// kept; the incoming one is ignored.
        case conflict
    }

    /// At most this many registrations are kept after a merge. A phone
    /// normally has one; the bound stops a misbehaving peer from growing the
    /// file and the per-notification fan-out without limit.
    public static let registrationLimit = 16

    /// The credential decision. `existing` is what is fully installed here.
    public static func credentialOutcome(
        existing: SupermuxPhonePushCredentials?,
        incoming: SupermuxPhonePushCredentials?
    ) -> CredentialOutcome {
        guard let incoming else { return .absent }
        guard incoming.isValid else { return .invalid }
        guard let existing else { return .install }
        return existing.isSameKey(as: incoming) ? .unchanged : .conflict
    }

    /// Adds incoming registrations for phones this Mac does not know yet, and
    /// replaces a known phone's token only with a strictly newer one.
    ///
    /// A known token is never duplicated. For a phone this Mac already has
    /// (same device id) with a different token, the incoming entry wins only
    /// when its ``SupermuxPhonePushRegistration/registeredAt`` is later than the
    /// local entry's (an entry without a timestamp counts as oldest; a tie keeps
    /// the local entry). That carries a rotated token from the Mac the phone
    /// reached to the Macs it could not. Undeliverable entries are dropped and
    /// the total is capped at ``registrationLimit``.
    public static func mergeRegistrations(
        existing: [SupermuxPhonePushRegistration],
        incoming: [SupermuxPhonePushRegistration]
    ) -> (merged: [SupermuxPhonePushRegistration], added: Int) {
        var merged = existing
        var added = 0
        for candidate in incoming {
            guard let registration = candidate.normalized(),
                  !merged.contains(where: { $0.deviceToken == registration.deviceToken }) else { continue }
            if let deviceID = registration.deviceID,
               let index = merged.firstIndex(where: { $0.deviceID == deviceID }) {
                guard (registration.registeredAt ?? 0) > (merged[index].registeredAt ?? 0) else { continue }
                merged[index] = registration
                added += 1
                continue
            }
            guard merged.count < registrationLimit else { continue }
            merged.append(registration)
            added += 1
        }
        return (merged, added)
    }
}
