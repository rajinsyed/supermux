import Foundation
import Testing
@testable import SupermuxKit

/// What a link to another Mac does once that Mac said it is going to sleep.
///
/// Field evidence (2026-10-05): while a MacBook Pro slept with its lid closed,
/// the always-awake M4 dialed it every 40 s all night (about 90 dials an hour);
/// half of the laptop's DarkWakes came 0–6 s after one of those dials, and the
/// sessions made inside them were ~31 s zombies that the M4 redialed at once.
/// Neither side knew the other was asleep.
///
/// Ways the policy could get it wrong, one test each:
/// 1. A Mac that announced it is going to sleep is redialed at the normal
///    backoff (seconds to two minutes) all night, waking it.
/// 2. The sleeping wait cuts a longer wait short (it must only lengthen).
/// 3. A link whose Mac never announced anything waits longer.
/// 4. A session made inside one of the sleeper's DarkWakes (~31 s) clears the
///    notice, so the hammering resumes after the first zombie.
/// 5. The long, healthy session that was live when the notice came clears it
///    when it is taken down.
/// 6. A session that started after the notice and stayed up two minutes (the
///    Mac really is awake) keeps the notice, so its next loss waits minutes.
/// 7. The sleeper dialing this Mac (it woke: a new build never dials from a
///    DarkWake) neither clears the notice nor dials it back at once.
/// 8. Repeated dial-ins (an older build churning through DarkWakes) each dial
///    back at once: a storm.
/// 9. A notice that comes again (it woke unseen and sleeps again) is measured
///    from the first, so the session live when it came clears it; or a
///    dial-in long after the last one is refused.
struct SupermuxPeerSleepTests {
    typealias Sleep = SupermuxPeerSleep
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func announced(at seconds: TimeInterval = 0) -> Sleep {
        var sleep = Sleep()
        sleep.announced(at: at(seconds))
        return sleep
    }

    @Test("1. a Mac that said it is going to sleep is dialed again only after the sleeping wait")
    func sleepingMacWaitsLong() {
        let sleep = announced()
        #expect(sleep.isAsleep)
        #expect(sleep.wait(after: .seconds(1)) == Sleep.wait)
        #expect(sleep.wait(after: .seconds(120)) == Sleep.wait)
        #expect(Sleep.wait >= .seconds(300), "at most about 12 dials an hour into a sleeping laptop")
    }

    @Test("2. the sleeping wait only lengthens a wait")
    func longerWaitsStand() {
        #expect(announced().wait(after: .seconds(900)) == .seconds(900))
    }

    @Test("3. a Mac that announced nothing waits its normal backoff")
    func noNoticeNoChange() {
        let sleep = Sleep()
        #expect(!sleep.isAsleep)
        #expect(sleep.wait(after: .seconds(2)) == .seconds(2))
        #expect(sleep.wait(after: .milliseconds(300)) == .milliseconds(300))
    }

    @Test("4. a DarkWake session (31 s, then gone) keeps the notice")
    func darkWakeSessionKeepsTheNotice() {
        var sleep = announced()
        sleep.connected(at: at(600))
        sleep.disconnected(at: at(631))
        #expect(sleep.isAsleep)
        #expect(sleep.wait(after: .seconds(1)) == Sleep.wait)
    }

    @Test("5. the session that was live when the notice came keeps it when taken down")
    func preNoticeSessionKeepsTheNotice() {
        var sleep = Sleep()
        sleep.connected(at: at(0))
        sleep.announced(at: at(3_600))
        sleep.disconnected(at: at(3_600.2))
        #expect(sleep.isAsleep)
    }

    @Test("6. a session that started after the notice and lasted two minutes clears it")
    func provenSessionClearsTheNotice() {
        var sleep = announced()
        sleep.connected(at: at(1_000))
        sleep.disconnected(at: at(1_000 + Sleep.provenAwakeLifetime))
        #expect(!sleep.isAsleep)
        #expect(sleep.wait(after: .seconds(1)) == .seconds(1))
    }

    @Test("7. the sleeper dialing in clears the notice and dials it back at once")
    func dialInWakesTheLink() {
        var sleep = announced()
        let dialsBack1 = sleep.dialedIn(at: at(900))
        #expect(dialsBack1)
        #expect(!sleep.isAsleep)
        #expect(sleep.wait(after: .seconds(1)) == .seconds(1))
    }

    @Test("8. dial-ins dial back at most once per spacing")
    func dialInsAreSpaced() {
        var sleep = announced()
        let dialsBack2 = sleep.dialedIn(at: at(100))
        #expect(dialsBack2)
        let dialsBack3 = sleep.dialedIn(at: at(100 + Sleep.nudgeSpacing - 1))
        #expect(!dialsBack3)
        let dialsBack4 = sleep.dialedIn(at: at(100 + Sleep.nudgeSpacing))
        #expect(dialsBack4)
        var quiet = Sleep()
        let dialsBack5 = quiet.dialedIn(at: at(5))
        #expect(dialsBack5, "a dial-in without a notice may still dial a waiting link back")
    }

    @Test("9. a repeated notice counts from the newest; a dial-in much later is allowed")
    func repeatedNoticeCountsFromTheNewest() {
        var sleep = announced(at: 0)
        sleep.connected(at: at(10))
        sleep.announced(at: at(50))
        // The session was live when the second notice came: like test 5, it proves nothing.
        sleep.disconnected(at: at(10 + Sleep.provenAwakeLifetime))
        #expect(sleep.isAsleep)
        sleep.connected(at: at(400))
        sleep.disconnected(at: at(400 + Sleep.provenAwakeLifetime))
        #expect(!sleep.isAsleep)
        var later = announced()
        let dialsBack6 = later.dialedIn(at: at(10))
        #expect(dialsBack6)
        later.announced(at: at(20))
        let dialsBack7 = later.dialedIn(at: at(20 + 3_600))
        #expect(dialsBack7)
    }
}
