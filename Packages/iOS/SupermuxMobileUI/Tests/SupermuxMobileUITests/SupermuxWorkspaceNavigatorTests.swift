import Foundation
@testable import SupermuxMobileUI
import Testing

/// How a Supermux RPC's Mac-local workspace id becomes a navigation: the
/// shell's rows are scoped per Mac once two Macs are paired, so the id must be
/// resolved against the OWNING Mac and, for a freshly created workspace, wait
/// for its row to arrive — bounded, and never yanking the user to a stale
/// target. Written as the list of ways it can go wrong.
@MainActor
@Suite struct SupermuxWorkspaceNavigatorTests {
    private typealias Target = SupermuxWorkspaceNavigator.Target
    private let wait = TestWait()

    /// The shell's rows, as `Target -> row id`, plus what the navigator did.
    private final class Harness {
        var rows: [Target: String] = [:]
        var resolverCalls: [Target] = []
        var selected: [String] = []
        var timedOut: [Target] = []
    }

    private func makeNavigator(
        timeout: Duration = .seconds(5)
    ) -> (SupermuxWorkspaceNavigator, Harness) {
        let harness = Harness()
        let navigator = SupermuxWorkspaceNavigator(timeout: timeout)
        navigator.resolve = { remoteID, macDeviceID, instanceTag in
            let target = Target(remoteWorkspaceID: remoteID, macDeviceID: macDeviceID, instanceTag: instanceTag)
            harness.resolverCalls.append(target)
            return harness.rows[target]
        }
        navigator.select = { harness.selected.append($0) }
        navigator.onTimeout = { harness.timedOut.append($0) }
        return (navigator, harness)
    }

    private let macB = Target(remoteWorkspaceID: "ws-1", macDeviceID: "mac-b", instanceTag: "default")

    @Test func anAlreadyListedRowIsSelectedImmediatelyByItsScopedID() {
        let (navigator, harness) = makeNavigator()
        harness.rows[macB] = "mac-b\u{1F}default\u{1F}ws-1"

        navigator.open(macB)

        #expect(harness.selected == ["mac-b\u{1F}default\u{1F}ws-1"])
        #expect(navigator.pendingTarget == nil)
    }

    @Test func theResolverIsAskedWithTheOwningMacsIdentity() {
        let (navigator, harness) = makeNavigator()

        navigator.open(macB)

        #expect(harness.resolverCalls == [macB])
    }

    @Test func aMissingRowParksUntilItAppearsThenSelectsExactlyOnce() {
        let (navigator, harness) = makeNavigator()

        navigator.open(macB)
        #expect(harness.selected.isEmpty)
        #expect(navigator.pendingTarget == macB)

        navigator.retryPending()
        #expect(harness.selected.isEmpty)

        harness.rows[macB] = "row-b"
        navigator.retryPending()
        navigator.retryPending()

        #expect(harness.selected == ["row-b"])
        #expect(navigator.pendingTarget == nil)
    }

    @Test func aRowThatNeverAppearsTimesOutVisiblyAndNeverNavigatesLater() async throws {
        let (navigator, harness) = makeNavigator(timeout: .milliseconds(30))

        navigator.open(macB)
        try await wait.until { !harness.timedOut.isEmpty }

        #expect(harness.timedOut == [macB])
        #expect(navigator.pendingTarget == nil)
        harness.rows[macB] = "row-b"
        navigator.retryPending()
        #expect(harness.selected.isEmpty)
    }

    @Test func aNewerRequestSupersedesAParkedOne() async throws {
        let (navigator, harness) = makeNavigator(timeout: .milliseconds(30))
        let newer = Target(remoteWorkspaceID: "ws-2", macDeviceID: "mac-a", instanceTag: "default")

        navigator.open(macB)
        harness.rows[newer] = "row-a"
        navigator.open(newer)
        harness.rows[macB] = "row-b"
        navigator.retryPending()
        try await Task.sleep(for: .milliseconds(80))

        #expect(harness.selected == ["row-a"])
        #expect(harness.timedOut.isEmpty)
    }

    @Test func withoutAResolverTheMacLocalIDIsSelectedAsIs() {
        let navigator = SupermuxWorkspaceNavigator(timeout: .seconds(5))
        let harness = Harness()
        navigator.select = { harness.selected.append($0) }

        navigator.open(macB)

        #expect(harness.selected == ["ws-1"])
    }

    /// The user moved on while a created workspace's row was still on its way:
    /// they opened another workspace from the flat list, a notification or
    /// search. When the parked row lands it must not yank them back, and no
    /// "hasn't appeared" alert may fire over where they went.
    @Test func aSelectionMadeElsewhereDropsAParkedTarget() async throws {
        let (navigator, harness) = makeNavigator(timeout: .milliseconds(30))

        navigator.open(macB)
        navigator.shellSelectionDidChange(to: "row-elsewhere")
        harness.rows[macB] = "row-b"
        navigator.retryPending()
        try await Task.sleep(for: .milliseconds(80))

        #expect(harness.selected.isEmpty)
        #expect(harness.timedOut.isEmpty)
    }

    /// The parked row landing can select itself first (the Mac focused the
    /// workspace it just created): that is the target arriving, not the user
    /// moving on.
    @Test func selectingTheParkedTargetsOwnRowKeepsTheNavigation() {
        let (navigator, harness) = makeNavigator()

        navigator.open(macB)
        harness.rows[macB] = "row-b"
        navigator.shellSelectionDidChange(to: "row-b")
        navigator.retryPending()

        #expect(harness.selected == ["row-b"])
    }

    /// A cleared selection (the selected workspace closed) is not a choice.
    @Test func aClearedSelectionKeepsAParkedTarget() {
        let (navigator, harness) = makeNavigator()

        navigator.open(macB)
        navigator.shellSelectionDidChange(to: nil)
        harness.rows[macB] = "row-b"
        navigator.retryPending()

        #expect(harness.selected == ["row-b"])
    }

    @Test func cancellingDropsAParkedRequestWithoutATimeout() async throws {
        let (navigator, harness) = makeNavigator(timeout: .milliseconds(30))

        navigator.open(macB)
        navigator.cancelPending()
        harness.rows[macB] = "row-b"
        navigator.retryPending()
        try await Task.sleep(for: .milliseconds(80))

        #expect(harness.selected.isEmpty)
        #expect(harness.timedOut.isEmpty)
    }
}
