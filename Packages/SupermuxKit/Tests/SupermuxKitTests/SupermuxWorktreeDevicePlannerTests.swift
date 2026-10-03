import Foundation
import Testing

@testable import SupermuxKit

/// Ways the New Worktree sheet's device picker could go wrong (written before
/// the code):
/// 1. "This Mac" is not the first entry when the project has a local copy.
/// 2. Macs come out of the project's location order, or one Mac is listed twice.
/// 3. An offline or connecting Mac can be chosen to create on (it must be
///    listed but disabled), or an online Mac is disabled.
/// 4. A Mac missing from the availability map is treated as online although its
///    location says offline (or the reverse).
/// 5. The picker shows for a project that lives on one Mac with nothing to set
///    up, or hides although other Macs could set it up.
/// 6. "Set Up on <Mac>…" entries are offered as create targets, come before the
///    real locations, or duplicate a Mac that already has the project.
/// 7. The default ignores the last device used for this project, picks a last
///    device that no longer has the project or is offline, or picks a set-up
///    entry.
/// 8. A remote-only project does not default to its first location.
/// 9. An explicit choice from the row menu ("New Worktree on ▸ <Mac>") is
///    ignored, or wins although that Mac is offline.
struct SupermuxWorktreeDevicePlannerTests {
    private let studio = SupermuxProjectDevice(machineID: "device:aaaa@default", name: "Studio", isOnline: true)
    private let laptop = SupermuxProjectDevice(machineID: "device:bbbb@default", name: "Laptop", isOnline: true)
    private let air = SupermuxProjectDevice(machineID: "device:cccc@default", name: "Air", isOnline: false)

    private func project(_ places: [SupermuxProjectLocation.Place]) -> SupermuxUnifiedProject {
        SupermuxUnifiedProject(
            id: UUID(),
            name: "app",
            colorHex: nil,
            iconSymbol: nil,
            gitRemoteIdentity: "github.com/me/app",
            locations: places.map { SupermuxProjectLocation(place: $0, projectID: UUID(), rootPath: "/src/app") }
        )
    }

    private func entries(
        _ project: SupermuxUnifiedProject,
        availability: [String: SupermuxWorktreeDeviceAvailability] = [:],
        setUp: [SupermuxProjectSetupDestination] = []
    ) -> [SupermuxWorktreeDeviceEntry] {
        SupermuxWorktreeDevicePlanner.entries(for: project, availability: availability, setUpTargets: setUp)
    }

    @Test func thisMacComesFirstThenDevicesInLocationOrderWithoutDuplicates() {
        let project = project([.device(studio), .thisMac, .device(laptop), .device(studio)])
        let list = entries(project)
        #expect(list.map(\.deviceKey) == [
            SupermuxWorktreeDeviceEntry.thisMacKey, studio.machineID, laptop.machineID,
        ])
        #expect(list.first?.isThisMac == true)
        #expect(list.map(\.name).dropFirst() == ["Studio", "Laptop"])
        #expect(Set(list.map(\.id)).count == list.count)
    }

    @Test func offlineAndConnectingMacsAreListedButCannotCreate() {
        let project = project([.thisMac, .device(studio), .device(laptop), .device(air)])
        let list = entries(project, availability: [
            studio.machineID: .online,
            laptop.machineID: .connecting,
        ])
        let byKey = Dictionary(uniqueKeysWithValues: list.map { ($0.deviceKey, $0) })
        #expect(byKey[SupermuxWorktreeDeviceEntry.thisMacKey]?.canCreate == true)
        #expect(byKey[studio.machineID]?.canCreate == true)
        #expect(byKey[laptop.machineID]?.availability == .connecting)
        #expect(byKey[laptop.machineID]?.canCreate == false)
        // Missing from the map: the location's own online flag decides.
        #expect(byKey[air.machineID]?.availability == .offline)
        #expect(byKey[air.machineID]?.canCreate == false)
    }

    @Test func availabilityMapOverridesAStaleLocationFlag() {
        let project = project([.thisMac, .device(air)])
        let list = entries(project, availability: [air.machineID: .online])
        #expect(list.last?.availability == .online)
        #expect(list.last?.canCreate == true)
    }

    @Test func pickerHidesForOneLocationAndShowsWhenOtherMacsCanSetUp() {
        let single = project([.thisMac])
        #expect(!SupermuxWorktreeDevicePlanner.showsPicker(entries(single)))
        let withSetUp = entries(single, setUp: [.device(studio)])
        #expect(SupermuxWorktreeDevicePlanner.showsPicker(withSetUp))
        #expect(SupermuxWorktreeDevicePlanner.showsPicker(entries(project([.thisMac, .device(studio)]))))
    }

    @Test func setUpEntriesFollowLocationsAndNeverCreateOrDuplicate() {
        let project = project([.thisMac, .device(studio)])
        let list = entries(project, setUp: [.device(laptop), .device(studio), .thisMac])
        #expect(list.map(\.deviceKey) == [SupermuxWorktreeDeviceEntry.thisMacKey, studio.machineID, laptop.machineID])
        let setUp = list[2]
        #expect(setUp.setUpDestination == .device(laptop))
        #expect(setUp.location == nil)
        #expect(!setUp.canCreate)
        #expect(setUp.id != setUp.deviceKey)
    }

    @Test func remoteOnlyProjectOffersThisMacAsSetUp() {
        let project = project([.device(studio)])
        let list = entries(project, setUp: [.thisMac])
        #expect(list.map(\.deviceKey) == [studio.machineID, SupermuxWorktreeDeviceEntry.thisMacKey])
        #expect(list[1].setUpDestination == .thisMac)
        #expect(SupermuxWorktreeDevicePlanner.defaultEntryID(in: list, preferredDeviceKey: nil, lastUsedDeviceKey: nil)
            == list[0].id)
    }

    @Test func defaultPrefersTheLastUsedMacWhenItCanCreate() {
        let project = project([.thisMac, .device(studio), .device(air)])
        let list = entries(project, setUp: [.device(laptop)])
        func pick(_ last: String?) -> String? {
            SupermuxWorktreeDevicePlanner.defaultEntryID(in: list, preferredDeviceKey: nil, lastUsedDeviceKey: last)
        }
        #expect(pick(studio.machineID) == studio.machineID)
        #expect(pick(nil) == SupermuxWorktreeDeviceEntry.thisMacKey)
        // Offline, gone, or only a set-up target: fall back to the first Mac that can create.
        #expect(pick(air.machineID) == SupermuxWorktreeDeviceEntry.thisMacKey)
        #expect(pick("device:gone@default") == SupermuxWorktreeDeviceEntry.thisMacKey)
        #expect(pick(laptop.machineID) == SupermuxWorktreeDeviceEntry.thisMacKey)
    }

    @Test func explicitChoiceWinsOnlyWhenThatMacCanCreate() {
        let project = project([.thisMac, .device(studio), .device(air)])
        let list = entries(project)
        #expect(SupermuxWorktreeDevicePlanner.defaultEntryID(
            in: list, preferredDeviceKey: studio.machineID, lastUsedDeviceKey: SupermuxWorktreeDeviceEntry.thisMacKey
        ) == studio.machineID)
        #expect(SupermuxWorktreeDevicePlanner.defaultEntryID(
            in: list, preferredDeviceKey: air.machineID, lastUsedDeviceKey: studio.machineID
        ) == studio.machineID)
    }

    @Test func allOfflineStillSelectsTheFirstLocationSoTheSheetExplainsWhy() {
        let project = project([.device(air)])
        let list = entries(project)
        #expect(SupermuxWorktreeDevicePlanner.defaultEntryID(in: list, preferredDeviceKey: nil, lastUsedDeviceKey: nil)
            == air.machineID)
        #expect(SupermuxWorktreeDevicePlanner.defaultEntryID(in: [], preferredDeviceKey: nil, lastUsedDeviceKey: nil) == nil)
    }
}
