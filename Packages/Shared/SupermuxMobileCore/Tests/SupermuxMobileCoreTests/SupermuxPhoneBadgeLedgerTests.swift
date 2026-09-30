import Foundation
@testable import SupermuxMobileCore
import Testing

/// Failure modes of the phone's per-Mac badge: every Mac reports only its own
/// unread count, so applying one Mac's count as the whole badge undercounts and
/// flips between Macs.
///
/// Per app instance (one Mac running Stable and Nightly is two instances, as
/// everywhere else on the phone — `MacPairingKey`):
/// 1. One instance's count (a dismiss push's zero) erases another instance's
///    count on the same Mac, so the badge drops while that build still has
///    unread notifications.
/// 2. A build this phone cannot pair with (a tagged dev or dogfood build that
///    shares the Mac's push setup) gets a slot: it erases or inflates the
///    real builds' counts, and its slot outlives the build forever.
/// 3. An untagged push (an older Mac), the app's legacy untagged pairing and
///    the `default` tag land in different slots, counting one build twice.
/// 4. The tag inside a pairing id (after U+001F) and the push's separate tag
///    field name different slots.
/// 5. A count stored before slots carried a tag is summed next to the tagged
///    slot (double count) or lost instead of becoming the default build's.
/// 6. Forgetting one build's pairing drops another build's count.
@Suite struct SupermuxPhoneBadgeLedgerTests {
    private static let macA = "7A1C1E4B-5D0E-4B0F-9C39-1E7C3F0A2B11"
    private static let macB = "0F6E9C2A-3B4D-4E5F-8A7B-9C0D1E2F3A4B"

    @Test func eachBuildOnOneMacKeepsItsOwnCount() {
        withLedger { ledger in
            #expect(ledger.total(recording: 3, forMacDeviceID: Self.macA, instanceTag: "default") == 3)
            #expect(ledger.total(recording: 2, forMacDeviceID: Self.macA, instanceTag: "nightly") == 5)
            // Nightly's dismiss push reports its own zero; Stable still has 3.
            #expect(ledger.total(recording: 0, forMacDeviceID: Self.macA, instanceTag: "nightly") == 3)
        }
    }

    @Test func aBuildThePhoneCannotPairWithNeverTouchesTheBadge() {
        withLedger { ledger in
            _ = ledger.total(recording: 3, forMacDeviceID: Self.macA, instanceTag: "default")
            #expect(ledger.total(recording: 0, forMacDeviceID: Self.macA, instanceTag: "rws-a4") == 3)
            #expect(ledger.total(recording: 7, forMacDeviceID: Self.macA, instanceTag: "my-dogfood") == 3)
            #expect(ledger.total() == 3, "a dev build's slot would outlive the build")
        }
    }

    @Test func untaggedAndDefaultAreOneBuild() {
        withLedger { ledger in
            _ = ledger.total(recording: 4, forMacDeviceID: Self.macA, instanceTag: nil)
            #expect(ledger.total(recording: 1, forMacDeviceID: Self.macA, instanceTag: "default") == 1)
            #expect(ledger.total(recording: 2, forMacDeviceID: Self.macA, instanceTag: " ") == 2)
            #expect(ledger.total(recording: 5, forMacDeviceID: Self.macA, instanceTag: "Default") == 5)
        }
    }

    @Test func aPairingIDsTagMatchesThePushsTagField() {
        withLedger { ledger in
            _ = ledger.total(recording: 4, forMacDeviceID: Self.macA, instanceTag: "nightly")
            #expect(ledger.total(recording: 1, forMacDeviceID: "\(Self.macA.lowercased())\u{1F}nightly", instanceTag: nil) == 1)
        }
    }

    @Test func aCountStoredBeforeTagsBecomesTheDefaultBuilds() {
        withLedger { ledger, defaults in
            defaults.set(6, forKey: SupermuxPhoneBadgeLedger.keyPrefix + Self.macA.lowercased())
            #expect(ledger.total(recording: 2, forMacDeviceID: Self.macA, instanceTag: "nightly") == 8)
            #expect(ledger.total(recording: 1, forMacDeviceID: Self.macA, instanceTag: "default") == 3, "never summed twice")
            #expect(defaults.object(forKey: SupermuxPhoneBadgeLedger.keyPrefix + Self.macA.lowercased()) == nil)
        }
    }

    @Test func forgettingOneBuildKeepsTheOthers() {
        withLedger { ledger in
            _ = ledger.total(recording: 3, forMacDeviceID: Self.macA, instanceTag: "default")
            _ = ledger.total(recording: 2, forMacDeviceID: Self.macA, instanceTag: "nightly")
            #expect(ledger.total(forgetting: Self.macA, instanceTag: "nightly") == 3)
        }
    }

    @Test func badgeIsTheSumOfEveryMacsLatestCount() {
        withLedger { ledger in
            #expect(ledger.total(recording: 2, forMacDeviceID: Self.macA) == 2)
            // B pushing its own count must not replace A's share of the badge.
            #expect(ledger.total(recording: 1, forMacDeviceID: Self.macB) == 3)
            // A's fresher count replaces only A's slot.
            #expect(ledger.total(recording: 0, forMacDeviceID: Self.macA) == 1)
            #expect(ledger.total() == 1)
        }
    }

    @Test func oneMacSpelledDifferentlyIsOneSlot() {
        withLedger { ledger in
            _ = ledger.total(recording: 4, forMacDeviceID: Self.macA)
            // The extension sees the raw push field, the app its pairing key
            // (lowercased UUID, possibly with a build tag); double counting one
            // Mac would overstate the badge forever.
            #expect(ledger.total(recording: 1, forMacDeviceID: Self.macA.lowercased()) == 1)
            #expect(ledger.total(recording: 3, forMacDeviceID: " \(Self.macA.lowercased())\u{1F}default ") == 3)
        }
    }

    @Test func aPayloadWithoutAMacKeepsItsOwnCountAndRecordsNothing() {
        withLedger { ledger in
            _ = ledger.total(recording: 2, forMacDeviceID: Self.macA)
            #expect(ledger.total(recording: 5, forMacDeviceID: "  ") == 5)
            #expect(ledger.total() == 2)
        }
    }

    @Test func negativeCountsClampToZero() {
        withLedger { ledger in
            _ = ledger.total(recording: 2, forMacDeviceID: Self.macB)
            #expect(ledger.total(recording: -3, forMacDeviceID: Self.macA) == 2)
        }
    }

    @Test func forgettingAMacDropsItsCount() {
        withLedger { ledger in
            _ = ledger.total(recording: 2, forMacDeviceID: Self.macA)
            _ = ledger.total(recording: 5, forMacDeviceID: Self.macB)
            #expect(ledger.total(forgetting: Self.macB.lowercased()) == 2)
        }
    }

    @Test func unrelatedDefaultsNeverCount() {
        withLedger { ledger, defaults in
            defaults.set(9, forKey: "someOtherCount")
            defaults.set("x", forKey: SupermuxPhoneBadgeLedger.keyPrefix + "broken")
            #expect(ledger.total(recording: 1, forMacDeviceID: Self.macA) == 1)
        }
    }

    /// The extension and the app meet only in this group; it must be the one
    /// the notification service extension's entitlements already carry.
    @Test func ledgerLivesInTheIconStoresAppGroup() {
        #expect(SupermuxPhoneBadgeLedger.appGroupIdentifier == SupermuxSharedProjectIconStore.appGroupIdentifier)
    }

    #if !os(iOS)
    /// Off the phone there is no shared ledger, so host-side test runs never
    /// write the real app group's defaults.
    @Test func noSharedLedgerOffThePhone() {
        #expect(SupermuxPhoneBadgeLedger.shared() == nil)
    }
    #endif

    private func withLedger(_ body: (SupermuxPhoneBadgeLedger) -> Void) {
        withLedger { ledger, _ in body(ledger) }
    }

    private func withLedger(_ body: (SupermuxPhoneBadgeLedger, UserDefaults) -> Void) {
        let suite = "supermux-phone-badge-ledger-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create a scratch defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        body(SupermuxPhoneBadgeLedger(defaults: defaults), defaults)
    }
}
