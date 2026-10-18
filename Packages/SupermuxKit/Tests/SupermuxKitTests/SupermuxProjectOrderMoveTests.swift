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
/// 6. (RR3) A move that restamps every project also re-keys a stamped one
///    whose Mac is offline. That stamp is never written, so its old key lands
///    among the new ones and two rows nobody moved swap places.
/// 7. (RR4) A drag committed over a project no Mac can stamp (the preview's
///    follower) is dropped, though the moved row can keep the slot before it:
///    the row snaps back.
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

    @Test func aDropOverAProjectNoMacCanStampLandsInTheNearestKeyedSlot() throws {
        let a = local("A", key: "a1"), b = local("B", key: "a2"), y = remoteOnly("Y", on: old)
        let stay = move(b, over: y, in: [a, b, y])
        #expect(Set(stay.keys) == [b.id], "Move Down onto Y")
        #expect(try #require(stay[b.id]?.key) > "a1")
        let down = move(a, over: y, in: [a, b, y])
        #expect(Set(down.keys) == [a.id], "a drag dropped over Y")
        #expect(try #require(down[a.id]?.key) > "a2")
    }

    // MARK: 5

    @Test func aStampedProjectWhoseMacWentOfflineKeepsItsPlace() throws {
        let a = local("A", key: "a1"), z = remoteOnly("Z", on: asleep, key: "a2"), b = local("B", key: "a3")
        let stamps = move(b, over: z, in: [a, z, b])
        #expect(Set(stamps.keys) == [b.id])
        let key = try #require(stamps[b.id]?.key)
        #expect("a1" < key && key < "a2")
    }

    // MARK: 6

    @Test func aFullRestampLeavesAStampedProjectWhoseMacWentOfflineWhereItIs() throws {
        let p1 = local("P1", key: "a0"), p2 = local("P2", key: "a1"), z = remoteOnly("Z", on: asleep, key: "a2")
        let p3 = local("P3", key: "a3"), p4 = local("P4")
        let stamps = move(p4, over: p1, in: [p1, p2, z, p3, p4])
        #expect(Set(stamps.keys) == [p4.id, p1.id, p2.id, p3.id], "Z's stamp could never be written")
        let keys = try [p4, p1, p2].map { try #require(stamps[$0.id]?.key) }
        let keyP3 = try #require(stamps[p3.id]?.key)
        #expect(keys[0] < keys[1] && keys[1] < keys[2] && keys[2] < "a2" && "a2" < keyP3)
    }

    // MARK: 7

    @Test func aDragCommittedOverAProjectNoMacCanStampLandsBeforeIt() throws {
        let l1 = local("L1"), l2 = local("L2"), y = remoteOnly("Y", on: old), z = remoteOnly("Z", on: current)
        let stamps = move(z, over: y, in: [l1, l2, y, z])
        #expect(Set(stamps.keys) == [l1.id, l2.id, z.id])
        let keys = try [l1, l2, z].map { try #require(stamps[$0.id]?.key) }
        #expect(keys[0] < keys[1] && keys[1] < keys[2])
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
