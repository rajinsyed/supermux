import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Focused pane phone-push gate", .serialized)
@MainActor
struct SupermuxFocusedPaneNotificationTests {
    @Test("The phone gate requires an exact pane target")
    func focusSuppressionRequiresExactPaneTarget() {
        let policy = SupermuxFocusedPaneNotificationPolicy(userIsPresent: { true })

        #expect(policy.targetIsAlreadyVisible(
            surfaceID: UUID(),
            exactPaneFocused: true
        ))
        #expect(!policy.targetIsAlreadyVisible(
            surfaceID: nil,
            exactPaneFocused: true
        ))
        #expect(!policy.targetIsAlreadyVisible(
            surfaceID: UUID(),
            exactPaneFocused: false
        ))
        #expect(!policy.targetIsAlreadyVisible(
            surfaceID: UUID(),
            exactPaneFocused: true,
            targetWindowIsKey: false
        ))
    }
}
