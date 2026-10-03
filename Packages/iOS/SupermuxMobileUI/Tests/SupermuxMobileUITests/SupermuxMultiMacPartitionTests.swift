import CmuxMobileShellModel
import Foundation
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// A project id is only unique on its own Mac, so every project-keyed join
/// on the phone must carry the owning pairing: the nested-workspace mapping,
/// the flat-list hide filter, and the row key the section hands out.
@MainActor
@Suite struct SupermuxMultiMacPartitionTests {
    private static let sharedProjectID = "77777777-7777-7777-7777-777777777777"
    private let macA = SupermuxMacSeam.pairingID(macDeviceID: "mac-a", instanceTag: "default")
    private let macB = SupermuxMacSeam.pairingID(macDeviceID: "mac-b", instanceTag: "default")

    private func preview(id: String, mac: String?, projectID: String?) -> MobileWorkspacePreview {
        var preview = MobileWorkspacePreview(
            id: MobileWorkspacePreview.ID(rawValue: id),
            name: id,
            terminals: []
        )
        preview.macDeviceID = mac
        preview.macInstanceTag = mac == nil ? nil : "default"
        preview.supermuxProjectID = projectID
        return preview
    }

    @Test func nestedRowsCarryTheOwningMacsPairing() {
        let rows = SupermuxProjectWorkspaceRowSnapshot.rows(from: [
            preview(id: "w-a", mac: "mac-a", projectID: Self.sharedProjectID),
            preview(id: "w-b", mac: "mac-b", projectID: Self.sharedProjectID),
            preview(id: "w-x", mac: nil, projectID: Self.sharedProjectID),
        ])

        #expect(rows.map(\.pairingID) == [macA, macB, ""])
    }

    @Test func theHideFilterFoldsOnlyTheOwningMacsWorkspaces() {
        let shownKey = SupermuxProjectKey(pairingID: macA, projectID: Self.sharedProjectID).rawValue
        let rows = [
            preview(id: "w-a", mac: "mac-a", projectID: Self.sharedProjectID),
            preview(id: "w-b", mac: "mac-b", projectID: Self.sharedProjectID),
        ].supermuxFlatRows(hidingProjectIDs: [shownKey])

        #expect(rows.map(\.id.rawValue) == ["w-b"])
    }

    @Test func aProjectKeyRoundTripsThroughATaggedPairing() {
        let key = SupermuxProjectKey(pairingID: macB, projectID: Self.sharedProjectID)
        let parsed = SupermuxProjectKey(rawValue: key.rawValue)

        #expect(parsed == key)
        #expect(key.rawValue != Self.sharedProjectID)
    }

    @Test func aKeyWithoutAPairingIsThePlainProjectID() {
        let key = SupermuxProjectKey(pairingID: "", projectID: Self.sharedProjectID)

        #expect(key.rawValue == Self.sharedProjectID)
        #expect(SupermuxProjectKey(rawValue: Self.sharedProjectID) == key)
    }
}
