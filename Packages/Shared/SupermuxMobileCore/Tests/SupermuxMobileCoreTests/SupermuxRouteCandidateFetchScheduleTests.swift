import Foundation
import Testing
@testable import SupermuxMobileCore

/// When a device asks a Mac for its direct addresses (`route.candidates`),
/// shared by the Mac and the phone (review findings T3, H3 and I4, written
/// before the schedule):
/// 1. An answer that is not authoritative (the host's first network report
///    has not run yet, an empty list from an older host, a failure) is
///    treated as stored, so the next ask waits 10 min.
/// 2. After one stored answer, failed asks retry every few seconds instead
///    of once a minute (the phone's 2 s loop).
/// 3. A host that turned direct off is asked again within the minute.
/// 4. Two asks run at once.
/// 5. A new connection does not ask at once.
/// 6. (Second review #14) A host that has no address yet (`not_ready`: iroh
///    fills them 1–3 s after it binds) is asked again only after a minute, so
///    a fresh link races without direct addresses for that long.
@Suite struct SupermuxRouteCandidateFetchScheduleTests {
    typealias Schedule = SupermuxRouteCandidateFetchSchedule
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    @Test("1. a stored answer is asked again after 10 min; one that is not authoritative after 1 min")
    func storedVersusKept() {
        var schedule = Schedule()
        #expect(schedule.isDue(at: at(0)))
        schedule.started(at: at(0))
        #expect(!schedule.isDue(at: at(1)), "4. one ask at a time")
        schedule.finished(.stored, at: at(1))
        #expect(!schedule.isDue(at: at(500)))
        #expect(schedule.isDue(at: at(601)))
        for answer in [Schedule.Answer.empty, .failed] {
            var kept = Schedule()
            kept.started(at: at(0))
            kept.finished(answer, at: at(0.5))
            #expect(!kept.isDue(at: at(59)), "\(answer)")
            #expect(kept.isDue(at: at(60)), "\(answer): asked again within the minute, not in 10 min")
        }
    }

    @Test("2. after a stored answer, failures retry once a minute")
    func failuresAfterAStoredAnswer() {
        var schedule = Schedule()
        schedule.started(at: at(0))
        schedule.finished(.stored, at: at(0))
        schedule.started(at: at(600))
        schedule.finished(.failed, at: at(601))
        #expect(!schedule.isDue(at: at(603)), "not every 2 s")
        #expect(schedule.isDue(at: at(660)))
    }

    @Test("3. a host that turned direct off, or cannot answer, is asked again in 10 min")
    func settledAnswers() {
        for answer in [Schedule.Answer.directOff, .unsupported] {
            var schedule = Schedule()
            schedule.started(at: at(0))
            schedule.finished(answer, at: at(0))
            #expect(!schedule.isDue(at: at(599)), "\(answer)")
            #expect(schedule.isDue(at: at(600)), "\(answer)")
        }
    }

    @Test("5. a new connection asks at once")
    func connectionAsksAtOnce() {
        var schedule = Schedule()
        schedule.started(at: at(0))
        schedule.finished(.stored, at: at(0))
        schedule.connected()
        #expect(schedule.isDue(at: at(5)))
    }

    @Test("the host's answer: addresses, not ready, direct off, or a failure")
    func answerFromTheHost() {
        #expect(Schedule.Answer(addresses: ["192.168.1.20:58465"]) == .stored)
        #expect(Schedule.Answer(addresses: []) == .empty)
        #expect(Schedule.Answer(errorCode: SupermuxRouteCandidates.notReadyErrorCode) == .notReady)
        #expect(Schedule.Answer(errorCode: SupermuxRouteCandidates.directOffErrorCode) == .directOff)
        #expect(Schedule.Answer(errorCode: "forbidden") == .failed)
        #expect(Schedule.Answer(errorCode: nil) == .failed)
    }

    @Test("6. a host that is not ready yet is asked again within seconds")
    func notReadyRetriesSoon() {
        var schedule = Schedule()
        schedule.started(at: at(0))
        schedule.finished(.notReady, at: at(0.5))
        #expect(!schedule.isDue(at: at(4)))
        #expect(schedule.isDue(at: at(5)), "iroh fills its addresses 1-3 s after binding")
        schedule.started(at: at(5))
        schedule.finished(.failed, at: at(5.5))
        #expect(!schedule.isDue(at: at(30)), "a failure after it waits the minute")
        #expect(schedule.isDue(at: at(65)))
    }
}
