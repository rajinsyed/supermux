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

    /// Adds incoming registrations for phones this Mac does not know yet.
    ///
    /// A phone this Mac already has (same device id, or same token) keeps its
    /// local entry: a direct `phone_push.register` here is at least as fresh as
    /// anything relayed, and a stale local token self-heals when APNs rejects it
    /// (pruned) and the next share re-adds the current one. Undeliverable
    /// entries are dropped and the total is capped at ``registrationLimit``.
    public static func mergeRegistrations(
        existing: [SupermuxPhonePushRegistration],
        incoming: [SupermuxPhonePushRegistration]
    ) -> (merged: [SupermuxPhonePushRegistration], added: Int) {
        var merged = existing
        var added = 0
        for candidate in incoming {
            guard merged.count < registrationLimit,
                  let registration = candidate.normalized() else { continue }
            let known = merged.contains { entry in
                entry.deviceToken == registration.deviceToken
                    || (registration.deviceID != nil && entry.deviceID == registration.deviceID)
            }
            guard !known else { continue }
            merged.append(registration)
            added += 1
        }
        return (merged, added)
    }
}
