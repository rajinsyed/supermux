import Foundation
import SupermuxMobileCore
import Testing

@testable import SupermuxKit

/// One project move in the shared order: which projects take a new stamp.
///
/// Ways it could fail, written before the code (design §3.4.2, review R7/R9):
/// 1. The first move leaves a project unstamped, so it jumps behind the
///    stamped ones; or a later move restamps every project, so a move another
///    device made to a different project is overwritten.
/// 2. A remote-only project no Mac can stamp now (its Mac lacks
///    `supermux.order_sync.v1`, or is offline and never stamped it) is counted
///    as "not every project is stamped", so every move restamps the whole list
///    forever.
/// 3. A drag of such a project is planned, though its stamp reaches no copy:
///    the drop is silently undone.
/// 4. A drop over such a project places the moved row after it, where the
///    stamped row can never stay (unstamped rows sort after stamped ones).
/// 5. A remote-only project on a connected Mac that serves order sync, or a
///    stamped one whose Mac went offline, is left out of the order too.
@Suite struct SupermuxProjectOrderMoveTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let current = SupermuxProjectDevice(machineID: "device:aaaa@default", name: "Studio", isOnline: true, supportsOrderSync: true)
    private let old = SupermuxProjectDevice(machineID: "device:bbbb@default", name: "Old", isOnline: true, supportsOrderSync: false)
    private let asleep = SupermuxProjectDevice(machineID: "device:cccc@default", name: "Laptop", isOnline: false, supportsOrderSync: true)

    // MARK: 1

    @Test func theFirstMoveStampsEveryProjectInTheNewOrder() throws {
        let a = local("A"), b = local("B")
        let stamps = move(b, over: a, in: [a, b])
        #expect(Set(stamps.keys) == [a.id, b.id])
        let keyB = try #require(stamps[b.id]?.key), keyA = try #require(stamps[a.id]?.key)
        #expect(keyB < keyA)
        #expect(Set(stamps.values.map(\.updatedAt)).count == 1)
    }

    @Test func aMoveWhenEveryProjectIsStampedStampsOnlyTheMovedProject() throws {
        let a = local("A", key: "a1"), b = local("B", key: "a2"), c = local("C", key: "a3")
        let stamps = move(c, over: a, in: [a, b, c])
        #expect(Set(stamps.keys) == [c.id])
        #expect(try #require(stamps[c.id]?.key) < "a1")
    }

    // MARK: 2

    @Test func aProjectOnlyAMacWithoutOrderSyncHoldsIsLeftOutOfTheMove() throws {
        let a = local("A", key: "a1"), b = local("B", key: "a2"), y = remoteOnly("Y", on: old)
        let stamps = move(b, over: a, in: [a, b, y])
        #expect(Set(stamps.keys) == [b.id], "one move, one stamp")
        #expect(try #require(stamps[b.id]?.key) < "a1")
    }

    @Test func aNeverStampedProjectOnAnOfflineMacIsLeftOutOfTheMove() {
        let a = local("A", key: "a1"), b = local("B", key: "a2"), y = remoteOnly("Y", on: asleep)
        #expect(Set(move(b, over: a, in: [a, b, y]).keys) == [b.id])
    }

    @Test func theFirstMoveStampsEveryProjectAMacCanHoldAndNoOther() throws {
        let a = local("A"), b = local("B"), y = remoteOnly("Y", on: old), x = remoteOnly("X", on: current)
        let stamps = move(x, over: a, in: [a, b, y, x])
        #expect(Set(stamps.keys) == [x.id, a.id, b.id])
        let keyX = try #require(stamps[x.id]?.key), keyA = try #require(stamps[a.id]?.key)
        let keyB = try #require(stamps[b.id]?.key)
        #expect(keyX < keyA && keyA < keyB)
    }

    // MARK: 3

    @Test func aDragOfAProjectNoMacCanStampIsIgnored() {
        let a = local("A", key: "a1"), y = remoteOnly("Y", on: old)
        #expect(move(y, over: a, in: [a, y]).isEmpty)
        let z = remoteOnly("Z", on: asleep)
        #expect(move(z, over: a, in: [a, z]).isEmpty)
    }

    // MARK: 4

    @Test func aDropOverAProjectNoMacCanStampIsIgnored() {
        let a = local("A", key: "a1"), b = local("B", key: "a2"), y = remoteOnly("Y", on: old)
        #expect(move(b, over: y, in: [a, b, y]).isEmpty, "Move Down onto Y")
        #expect(move(a, over: y, in: [a, b, y]).isEmpty, "a drag dropped over Y")
    }

    // MARK: 5

    @Test func aStampedProjectWhoseMacWentOfflineKeepsItsPlace() throws {
        let a = local("A", key: "a1"), z = remoteOnly("Z", on: asleep, key: "a2"), b = local("B", key: "a3")
        let stamps = move(b, over: z, in: [a, z, b])
        #expect(Set(stamps.keys) == [b.id])
        let key = try #require(stamps[b.id]?.key)
        #expect("a1" < key && key < "a2")
    }

    // MARK: Helpers

    private func move(
        _ dragged: SupermuxUnifiedProject,
        over target: SupermuxUnifiedProject,
        in projects: [SupermuxUnifiedProject]
    ) -> [UUID: SupermuxOrderStamp] {
        let order = SupermuxUnifiedProjectList(projects: projects).sharedOrder
        return SupermuxProjectOrderMove(origin: "mac:e2e@default", now: now)
            .stamps(moving: dragged.id, over: target.id, in: order)
    }

    private func local(_ name: String, key: String? = nil) -> SupermuxUnifiedProject {
        let id = UUID()
        return project(name, id: id, location: SupermuxProjectLocation(place: .thisMac, projectID: id, rootPath: "/p/\(name)"), key: key)
    }

    private func remoteOnly(_ name: String, on device: SupermuxProjectDevice, key: String? = nil) -> SupermuxUnifiedProject {
        let location = SupermuxProjectLocation(place: .device(device), projectID: UUID(), rootPath: "/p/\(name)")
        return project(name, id: UUID(), location: location, key: key)
    }

    private func project(_ name: String, id: UUID, location: SupermuxProjectLocation, key: String?) -> SupermuxUnifiedProject {
        SupermuxUnifiedProject(
            id: id,
            name: name,
            colorHex: nil,
            iconSymbol: nil,
            gitRemoteIdentity: nil,
            locations: [location],
            order: key.map { SupermuxOrderStamp(key: $0, updatedAt: 100, origin: "mac:z") }
        )
    }
}
