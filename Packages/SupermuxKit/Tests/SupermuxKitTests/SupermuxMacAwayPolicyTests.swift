import Foundation
import SupermuxKit
import Testing

@Suite struct SupermuxMacAwayPolicyTests {
    private let policy = SupermuxMacAwayPolicy(idleThreshold: 60)

    @Test func lockedScreenIsAlwaysAway() {
        #expect(policy.isAway(screenLocked: true, secondsSinceLastInput: 0))
        #expect(policy.isAway(screenLocked: true, secondsSinceLastInput: nil))
    }

    @Test func recentLocalInputMeansPresent() {
        #expect(!policy.isAway(screenLocked: false, secondsSinceLastInput: 3))
        #expect(!policy.isAway(screenLocked: false, secondsSinceLastInput: 59.9))
    }

    @Test func idlePastTheThresholdMeansAway() {
        #expect(policy.isAway(screenLocked: false, secondsSinceLastInput: 60))
        #expect(policy.isAway(screenLocked: false, secondsSinceLastInput: 3_600))
    }

    @Test func unknownInputRecencyFailsClosedToPresent() {
        #expect(!policy.isAway(screenLocked: false, secondsSinceLastInput: nil))
        #expect(!policy.isAway(screenLocked: false, secondsSinceLastInput: .infinity))
    }
}
