import Foundation
@testable import SupermuxKit
import Testing

/// A project id is minted by the Mac that owns the project, so another Mac's
/// id means nothing in this Mac's icon store: a notification mirrored from
/// another Mac must take its project icon from that Mac's fetched icons.
@Suite struct SupermuxNotificationIconSourceTests {
    private static let projectID = UUID()
    private static let otherMac = "device:7a1c1e4b-5d0e-4b0f-9c39-1e7c3f0a2b11@default"

    @Test func aMirroredNotificationUsesTheOtherMacsIcons() {
        let source = SupermuxNotificationIconSource(
            projectID: Self.projectID.uuidString,
            mirroredFromMachineID: Self.otherMac
        )
        #expect(source == .remote(machineID: Self.otherMac, projectID: Self.projectID))
    }

    @Test func aLocalNotificationUsesThisMacsIcons() {
        let source = SupermuxNotificationIconSource(
            projectID: Self.projectID.uuidString,
            mirroredFromMachineID: nil
        )
        #expect(source == .local(projectID: Self.projectID))
    }

    /// The avatar cache keys on the source, so one id seen from two Macs must
    /// never share a rendered chip.
    @Test func theSameIDOnTwoMacsIsTwoSources() {
        let local = SupermuxNotificationIconSource(projectID: Self.projectID.uuidString, mirroredFromMachineID: nil)
        let remote = SupermuxNotificationIconSource(projectID: Self.projectID.uuidString, mirroredFromMachineID: Self.otherMac)
        #expect(local != remote)
    }

    @Test func aMalformedProjectIDHasNoIcon() {
        #expect(SupermuxNotificationIconSource(projectID: "not-a-uuid", mirroredFromMachineID: nil) == nil)
        #expect(SupermuxNotificationIconSource(projectID: "not-a-uuid", mirroredFromMachineID: Self.otherMac) == nil)
    }

    @Test func aBlankMachineIsNotAnotherMac() {
        let source = SupermuxNotificationIconSource(projectID: Self.projectID.uuidString, mirroredFromMachineID: "  ")
        #expect(source == .local(projectID: Self.projectID))
    }
}
