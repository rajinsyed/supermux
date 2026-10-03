import Foundation
import Testing
@testable import SupermuxKit

/// Ways the projects list's per-project file facts could fail, written before
/// the code. A project in ~/Documents while macOS's privacy prompt for it is
/// unanswered blocks its icon stat in the kernel:
///
/// 1. One stuck project holds the whole list past the viewer's deadline, so
///    the device link reconnects every ~20 s.
/// 2. The other projects lose their icons because one is stuck.
/// 3. A project whose probe is stuck now loses the icon it had (the phone
///    drops a good cached icon on every list).
/// 4. A project that was never probed in time shows an icon it may not have.
@Suite(.serialized)
struct SupermuxProjectFileFactsTests {
    private static let icon = SupermuxMobileProjectsPayloadBuilder.FileFacts(hasCustomIcon: true, iconETag: "e1", configPath: nil)

    @Test func aStuckProjectAnswersAtTheBoundWithTheOthers() async {
        let gate = DispatchSemaphore(value: 0)
        let stuck = SupermuxProject(name: "Docs", rootPath: "/Users/me/Documents/docs")
        let fine = SupermuxProject(name: "Tmp", rootPath: "/tmp/fine")
        let facts = SupermuxProjectFileFacts { project in
            if project.rootPath == stuck.rootPath { _ = gate.wait(timeout: .now() + 3) }
            return Self.icon
        }
        let started = ContinuousClock.now
        let answered = await facts.facts(for: [stuck, fine], timeout: 0.3)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(answered[SupermuxMobileProjectsPayloadBuilder.fileFactsKey(for: fine)] == Self.icon)
        #expect(answered[SupermuxMobileProjectsPayloadBuilder.fileFactsKey(for: stuck)] == nil)
        gate.signal()
    }

    @Test func aStuckProjectKeepsItsLastKnownFacts() async {
        let gate = DispatchSemaphore(value: 0)
        let blocks = Flag()
        let project = SupermuxProject(name: "Docs", rootPath: "/Users/me/Documents/docs")
        let facts = SupermuxProjectFileFacts { _ in
            if blocks.isSet { _ = gate.wait(timeout: .now() + 3) }
            return Self.icon
        }
        let key = SupermuxMobileProjectsPayloadBuilder.fileFactsKey(for: project)
        #expect(await facts.facts(for: [project], timeout: 2)[key] == Self.icon)
        blocks.set()
        let started = ContinuousClock.now
        #expect(await facts.facts(for: [project], timeout: 0.3)[key] == Self.icon)
        #expect(ContinuousClock.now - started < .seconds(2))
        gate.signal()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
