import SupermuxKit
import Testing

/// Tests the priority and parsing of agent-activity resolution from cmux's
/// per-agent lifecycle raw values.
struct SupermuxWorkspaceActivityTests {
    @Test func runningWinsWhenAnyAgentIsWorking() {
        #expect(SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues: ["running", "needsInput", "idle"]) == .working)
        #expect(SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues: ["idle", "running"]) == .working)
        #expect(SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues: ["Running"]) == .working)
    }

    @Test func needsInputWinsWhenNoAgentIsRunning() {
        #expect(SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues: ["idle", "needsInput"]) == .needsInput)
        // Order-independent and case/underscore tolerant (cmux uses "needsInput").
        #expect(SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues: ["needs-input"]) == .needsInput)
        #expect(SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues: ["NEEDSINPUT"]) == .needsInput)
    }

    @Test func idleAgentBecomesReady() {
        #expect(SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues: ["idle"]) == .ready)
        #expect(SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues: ["idle", "unknown"]) == .ready)
    }

    @Test func noAgentSignalIsIdle() {
        #expect(SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues: []) == .idle)
        #expect(SupermuxWorkspaceActivity.resolve(fromLifecycleRawValues: ["unknown", "bogus"]) == .idle)
    }

    @Test func onlyIdleAndReadyAreVisibleAppropriately() {
        #expect(SupermuxWorkspaceActivity.idle.isVisible == false)
        #expect(SupermuxWorkspaceActivity.working.isVisible)
        #expect(SupermuxWorkspaceActivity.needsInput.isVisible)
        #expect(SupermuxWorkspaceActivity.ready.isVisible)
    }
}
