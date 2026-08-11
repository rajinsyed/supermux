import Foundation
import Testing
@testable import SupermuxClaudeHarness

/// Generation-tagged process/turn state machine transitions.
struct SessionStateMachineTests {
    @Test func happyPathLifecycle() {
        var machine = ClaudeSessionStateMachine()
        #expect(machine.processPhase == .dormant)

        let generation = machine.beginSpawn()
        #expect(machine.processPhase == .spawning(generation: generation))

        machine.processStarted(generation: generation)
        #expect(machine.processPhase == .handshaking(generation: generation))

        machine.initialized(generation: generation)
        #expect(machine.processPhase == .running(generation: generation))

        let inputID = UUID()
        machine.beginDispatch(inputID: inputID)
        #expect(machine.turnPhase == .dispatching(inputID: inputID))

        machine.turnStarted()
        #expect(machine.turnPhase == .active(inputID: inputID))

        machine.turnFinished()
        #expect(machine.turnPhase == .idle)

        let finished = machine.finishProcess(
            generation: generation,
            exit: ClaudeProcessExit(status: 0, wasClean: true)
        )
        #expect(finished)
        #expect(machine.processPhase == .exited(ClaudeProcessExit(status: 0, wasClean: true)))
    }

    @Test func staleGenerationEventsAreIgnored() {
        var machine = ClaudeSessionStateMachine()
        let first = machine.beginSpawn()
        machine.processStarted(generation: first)
        machine.initialized(generation: first)

        let second = machine.beginSpawn()
        // Stale events from the first generation change nothing.
        machine.initialized(generation: first)
        #expect(machine.processPhase == .spawning(generation: second))
        let staleFinish = machine.finishProcess(
            generation: first,
            exit: ClaudeProcessExit(status: 1, wasClean: false)
        )
        #expect(!staleFinish)
        #expect(machine.processPhase == .spawning(generation: second))
    }

    @Test func finishProcessIsExactlyOncePerGeneration() {
        var machine = ClaudeSessionStateMachine()
        let generation = machine.beginSpawn()
        machine.processStarted(generation: generation)
        let first = machine.finishProcess(
            generation: generation,
            exit: ClaudeProcessExit(status: 0, wasClean: true)
        )
        let second = machine.finishProcess(
            generation: generation,
            exit: ClaudeProcessExit(status: 1, wasClean: false)
        )
        #expect(first)
        #expect(!second)
        #expect(machine.processPhase == .exited(ClaudeProcessExit(status: 0, wasClean: true)))
    }

    @Test func crashDuringDispatchMarksUncertain() {
        var machine = ClaudeSessionStateMachine()
        let generation = machine.beginSpawn()
        machine.processStarted(generation: generation)
        machine.initialized(generation: generation)
        let inputID = UUID()
        machine.beginDispatch(inputID: inputID)
        machine.finishProcess(
            generation: generation,
            exit: ClaudeProcessExit(status: 1, wasClean: false)
        )
        #expect(machine.turnPhase == .uncertain(inputID: inputID))
    }

    @Test func crashDuringActiveTurnMarksUncertain() {
        var machine = ClaudeSessionStateMachine()
        let generation = machine.beginSpawn()
        machine.processStarted(generation: generation)
        machine.initialized(generation: generation)
        let inputID = UUID()
        machine.beginDispatch(inputID: inputID)
        machine.turnStarted()
        machine.finishProcess(
            generation: generation,
            exit: ClaudeProcessExit(status: 1, wasClean: false)
        )
        #expect(machine.turnPhase == .uncertain(inputID: inputID))
    }

    @Test func interruptThenResultReturnsToIdle() {
        var machine = ClaudeSessionStateMachine()
        let generation = machine.beginSpawn()
        machine.processStarted(generation: generation)
        machine.initialized(generation: generation)
        machine.beginDispatch(inputID: UUID())
        machine.turnStarted()
        machine.beginInterrupt()
        #expect(machine.turnPhase == .interrupting)
        // Only the authoritative result finishes the turn.
        machine.turnFinished()
        #expect(machine.turnPhase == .idle)
    }

    @Test func spawnFailureRecordsFailedPhase() {
        var machine = ClaudeSessionStateMachine()
        let generation = machine.beginSpawn()
        machine.failSpawn(generation: generation, message: "ENOENT")
        #expect(machine.processPhase == .failed(message: "ENOENT"))
    }

    @Test func generationsIncreaseMonotonically() {
        var machine = ClaudeSessionStateMachine()
        let first = machine.beginSpawn()
        let second = machine.beginSpawn()
        let third = machine.beginSpawn()
        #expect(first < second)
        #expect(second < third)
    }
}
