import Foundation
@testable import SupermuxKit
import Testing

@Suite struct SupermuxNotificationFocusPolicyTests {
    private let policy = SupermuxNotificationFocusPolicy()

    @Test func preservesFocusWhenTheRowRemainsVisible() {
        let first = UUID()
        let focused = UUID()

        #expect(policy.focusedID(visibleIDs: [first, focused], current: focused) == focused)
    }

    @Test func reseatsFocusWhenTheCurrentRowIsFilteredOut() {
        let firstVisible = UUID()

        #expect(policy.focusedID(visibleIDs: [firstVisible], current: UUID()) == firstVisible)
    }

    @Test func clearsFocusWhenNoRowsAreVisible() {
        #expect(policy.focusedID(visibleIDs: [], current: UUID()) == nil)
    }
}
