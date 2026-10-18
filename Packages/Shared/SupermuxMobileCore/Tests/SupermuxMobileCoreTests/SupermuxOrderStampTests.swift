import Foundation
@testable import SupermuxMobileCore
import Testing

/// Project order stamps: each copy of a project carries `(key, updated_at,
/// origin)` and the newest stamp wins on every device.
///
/// Ways it could fail, written before the code (design §4 G and A):
/// 1. (#58) An older stamp overrides a newer one, so a move made on one
///    device is undone by a late write from another.
/// 2. (#58) Re-applying the same stamp counts as a change, so an idempotent
///    `projects.set_order` or a gossip adoption writes forever (#60).
/// 3. (#59) Clock skew: a device whose clock runs behind makes a move that
///    loses to the stamp it just saw.
/// 4. (#65) Equal stamps break on ids the Mac and the phone do not share, so
///    they order projects differently; or two stamps with the same time are
///    each judged the winner on a different device; or two copies of one
///    project stamped by one full restamp (same time and origin, different
///    keys) never beat each other, so each device keeps the copy it saw first.
/// 5. (#61) Unstamped projects reshuffle: they must follow the stamped ones in
///    their incoming (today's) order.
/// 6. (#3) A stamp with a key that is not valid (an old or buggy peer) wins or
///    sorts by its garbage key: it must count as no stamp.
/// 7. The wire shape drifts from `{"key", "updated_at", "origin"}`, so the Mac,
///    the phone and the projects file stop reading each other's stamps.
@Suite struct SupermuxOrderStampTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: wins (1, 2, 4, 6)

    @Test func anyStampWinsOverNoStamp() {
        #expect(stamp("a1", at: 1, from: "mac:a").wins(over: nil))
    }

    @Test func theNewerStampWins() {
        let older = stamp("a5", at: 100, from: "mac:z")
        let newer = stamp("a1", at: 101, from: "mac:a")
        #expect(newer.wins(over: older))
        #expect(!older.wins(over: newer))
    }

    @Test func aStampDoesNotWinOverItself() {
        let same = stamp("a1", at: 100, from: "mac:a")
        #expect(!same.wins(over: same))
    }

    @Test func atTheSameTimeTheOriginDecidesTheSameWayOnEveryDevice() {
        let mac = stamp("a1", at: 100, from: "mac:7a1c@default")
        let phone = stamp("a2", at: 100, from: "phone:0F6E")
        #expect(phone.wins(over: mac) != mac.wins(over: phone))
        #expect(phone.wins(over: mac), "origins compare in byte order: \"p\" > \"m\"")
    }

    @Test func atTheSameTimeAndOriginTheGreaterKeyWins() {
        let lower = stamp("a2", at: 100, from: "mac:a")
        let greater = stamp("a4", at: 100, from: "mac:a")
        #expect(greater.wins(over: lower), "keys compare in byte order: \"a4\" > \"a2\"")
        #expect(!lower.wins(over: greater))
    }

    @Test func aStampWithABadKeyNeverWins() {
        let bad = stamp("!!", at: 200, from: "mac:a")
        let good = stamp("a1", at: 100, from: "mac:a")
        #expect(!bad.isValid)
        #expect(good.isValid)
        #expect(!bad.wins(over: good))
        #expect(!bad.wins(over: nil))
        #expect(good.wins(over: bad))
    }

    @Test func aStampWithATimeThatIsNotFiniteIsNotValid() {
        #expect(!stamp("a1", at: .infinity, from: "mac:a").isValid)
        #expect(!stamp("a1", at: .nan, from: "mac:a").isValid)
    }

    // MARK: next (3)

    @Test func aMoveIsStampedNowWhenNothingNewerWasSeen() {
        let next = SupermuxOrderStamp.next(key: "a3", observed: [stamp("a1", at: 5, from: "mac:a")], origin: "phone:1", now: now)
        #expect(next == SupermuxOrderStamp(key: "a3", updatedAt: now.timeIntervalSince1970, origin: "phone:1"))
        #expect(SupermuxOrderStamp.next(key: "a3", observed: [], origin: "phone:1", now: now).updatedAt == now.timeIntervalSince1970)
    }

    @Test func aMoveBeatsEveryStampItSawEvenFromAClockAhead() {
        let ahead = now.timeIntervalSince1970 + 3600
        let observed = [
            stamp("a1", at: now.timeIntervalSince1970 - 10, from: "mac:a"),
            stamp("a2", at: ahead, from: "zzz:fast-clock"),
        ]
        let next = SupermuxOrderStamp.next(key: "a0", observed: observed, origin: "mac:a", now: now)
        #expect(next.updatedAt > ahead)
        #expect(next.updatedAt < ahead + 1)
        #expect(observed.allSatisfy { next.wins(over: $0) })
    }

    @Test func aStampThatIsNotValidDoesNotPushTheClock() {
        let next = SupermuxOrderStamp.next(
            key: "a0",
            observed: [stamp("a1", at: .infinity, from: "mac:a")],
            origin: "mac:b",
            now: now
        )
        #expect(next.updatedAt == now.timeIntervalSince1970)
    }

    // MARK: Wire shape (7)

    @Test func theWireShapeIsKeyUpdatedAtOrigin() throws {
        let json = #"{"key":"a1","updated_at":1760000000.123,"origin":"phone:0F6E"}"#
        let decoded = try JSONDecoder().decode(SupermuxOrderStamp.self, from: Data(json.utf8))
        #expect(decoded == SupermuxOrderStamp(key: "a1", updatedAt: 1_760_000_000.123, origin: "phone:0F6E"))

        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["key", "updated_at", "origin"])
        #expect(try JSONDecoder().decode(SupermuxOrderStamp.self, from: encoded) == decoded)
    }

    @Test func aWholeSecondTimeDecodes() throws {
        let json = #"{"key":"a1","updated_at":1760000000,"origin":"mac:a"}"#
        let decoded = try JSONDecoder().decode(SupermuxOrderStamp.self, from: Data(json.utf8))
        #expect(decoded.updatedAt == 1_760_000_000)
    }

    // MARK: Project order (4, 5, 6)

    @Test func stampedProjectsSortByKeyAndUnstampedFollowInTheirOrder() {
        let projects: [(name: String, order: SupermuxOrderStamp?)] = [
            ("unstamped-1", nil),
            ("third", stamp("a5", at: 1, from: "mac:a")),
            ("first", stamp("Zz", at: 9, from: "mac:b")),
            ("unstamped-2", nil),
            ("second", stamp("a0", at: 3, from: "phone:1")),
        ]
        let sorted = SupermuxProjectOrder().sorted(projects) { $0.order }.map(\.name)
        #expect(sorted == ["first", "second", "third", "unstamped-1", "unstamped-2"])
    }

    @Test func equalKeysBreakOnTheStampNeverOnTheInputOrder() {
        let projects: [(name: String, order: SupermuxOrderStamp?)] = [
            ("late", stamp("a1", at: 20, from: "mac:a")),
            ("early-b", stamp("a1", at: 10, from: "mac:b")),
            ("early-a", stamp("a1", at: 10, from: "mac:a")),
        ]
        let expected = ["early-a", "early-b", "late"]
        #expect(SupermuxProjectOrder().sorted(projects) { $0.order }.map(\.name) == expected)
        #expect(SupermuxProjectOrder().sorted(projects.reversed()) { $0.order }.map(\.name) == expected)
    }

    @Test func aProjectWithABadStampSortsAsUnstamped() {
        let projects: [(name: String, order: SupermuxOrderStamp?)] = [
            ("bad", stamp("a00", at: 50, from: "mac:a")),
            ("good", stamp("a9", at: 1, from: "mac:a")),
            ("none", nil),
        ]
        #expect(SupermuxProjectOrder().sorted(projects) { $0.order }.map(\.name) == ["good", "bad", "none"])
    }

    @Test func nothingStampedKeepsTheIncomingOrder() {
        let names = ["c", "a", "b"]
        #expect(SupermuxProjectOrder().sorted(names) { _ in nil } == names)
    }

    // MARK: Helpers

    private func stamp(_ key: String, at time: Double, from origin: String) -> SupermuxOrderStamp {
        SupermuxOrderStamp(key: key, updatedAt: time, origin: origin)
    }
}
