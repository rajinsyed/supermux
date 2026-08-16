//
//  SupermuxZeronAssistantRowRenderLoopTests.swift
//  SupermuxZeronUITests
//
//  The regression guard for the streaming row's 100 % CPU render loop.
//
//  ── The bug ──
//
//  `SupermuxZeronAssistantRow.body` read a computed `streamingSpans`, which
//  called `model.spans(for:at:)`, which ADVANCED the `@Observable` model's veil
//  (`veil.advance` writes `veil`, `finishSeeding` writes `didSeed`) and renewed
//  a pulse-clock lease. Writing observable state that the same `body` reads
//  makes SwiftUI invalidate the view it is currently evaluating, which
//  re-renders it, which writes again: an unbounded loop with the main thread
//  pinned at 100 %. The user's app froze and needed a force quit.
//
//  Sampled live at the freeze, `body.getter` → `streamingSpans.getter` →
//  `spans(for:at:)` → `veil.modify` was the hot stack, all inside one
//  `GraphHost.flushTransactions` — i.e. one update that never terminated.
//
//  ── What is asserted here ──
//
//  Three levels, so a future edit cannot reintroduce it by another route:
//
//  1. **The invariant.** Evaluating the row's `body` inside
//     `withObservationTracking` must register no CHANGE — a body that mutates
//     what it observes trips the tracker on the very next evaluation. This is
//     the same mechanism SwiftUI itself uses to decide to re-render, so it
//     tests the real dependency rather than a proxy.
//  2. **The behavior, hosted.** An `NSHostingView` driven over real run-loop
//     turns must not burn the CPU, and the pulse clock must not be spun by
//     the render pass.
//  3. **The model's own contract.** Projecting twice at the same instant must
//     be observably inert, and the driver's commit must still advance.
//

import Foundation
import SwiftUI
import Testing

#if canImport(AppKit)
import AppKit
#endif

@testable import SupermuxZeronUI

@MainActor
struct SupermuxZeronAssistantRowRenderLoopTests {

    /// A `Sendable` one-way flag, for `withObservationTracking`'s escaping
    /// `onChange` — the same shape `SupermuxZeronPulseClockTests` uses.
    private final class Flag: @unchecked Sendable {
        // lint:allow lock — a test-only boolean touched from an escaping
        // `@Sendable` closure and read back synchronously.
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Streaming prose with the shapes the veil actually meets: inline marks,
    /// a list, and a fenced block.
    private static let sample = """
        # Heading

        A streaming **paragraph** with `code` and a [link](https://example.com).

        - first item
        - second item

        ```swift
        let x = 1
        ```
        """

    private static func row(
        text: String = sample,
        isStreaming: Bool = true,
        seeded: Bool = false
    ) -> SupermuxZeronAssistantRow {
        SupermuxZeronAssistantRow(
            text: text,
            isStreaming: isStreaming,
            theme: .dark,
            rowKey: "render-loop-row",
            seeded: seeded
        )
    }

    /// User CPU seconds burned by this process so far.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    }

    // MARK: - The invariant

    @Test("Evaluating `body` MUTATES NOTHING it observes — the render-loop guard")
    func bodyIsPure() {
        // ── The exact failure ──────────────────────────────────────────────
        //
        // Before the fix this flag was SET: the first `body` advanced the veil,
        // the write landed on the property the same body had just read, and the
        // tracker fired. In SwiftUI that firing is an invalidation, and the
        // invalidation re-enters `body`, forever.
        //
        // Measured against the pre-fix code: fired = true. After: false.
        let row = Self.row()
        let invalidated = Flag()
        withObservationTracking {
            _ = row.body
        } onChange: {
            invalidated.set()
        }
        // A second evaluation is what a real re-render does. If `body` writes,
        // THIS is the call that trips the tracker registered above.
        _ = row.body
        #expect(
            !invalidated.isSet,
            """
            `body` wrote observable state it also reads — SwiftUI will invalidate \
            the view it is rendering and spin the main thread at 100 % (cmux #2586).
            """
        )
    }

    @Test("A settled (non-streaming) row is inert too")
    func settledBodyIsPure() {
        let row = Self.row(isStreaming: false)
        let invalidated = Flag()
        withObservationTracking {
            _ = row.body
        } onChange: {
            invalidated.set()
        }
        _ = row.body
        #expect(!invalidated.isSet)
    }

    // MARK: - Hosted

    @Test("A hosted streaming row: no render-driven lease, and no runaway CPU")
    func hostedRowStaysIdle() throws {
        #if canImport(AppKit)
        // The injected clock is how this observes what the RENDER PASS did:
        // `@Environment` only resolves inside a real host, so a bare `row.body`
        // would silently fall back to the shared clock and see nothing.
        let clock = SupermuxZeronPulseClock()
        let host = NSHostingView(
            rootView: AnyView(
                Self.row()
                    .environment(\.supermuxZeronPulseClock, clock)
                    .frame(width: SupermuxZeronMetrics.Transcript.maxContentWidth)
            )
        )
        host.layoutSubtreeIfNeeded()
        // A host that never laid out cannot measure anything; skip rather than
        // report a bogus pass.
        try #require(host.fittingSize.height > 0)

        // Laying out evaluates `body`. The pre-fix body renewed a pulse-clock
        // lease from inside that evaluation — a write to SHARED state during
        // render. `.task` bodies do not run in a host that was never added to a
        // window, so a lease present HERE can only have come from the render
        // pass.
        #expect(
            clock.leaseCount == 0 && !clock.isRunning,
            "the render pass took a pulse-clock lease — `body` is mutating shared state"
        )

        let wallStart = Date()
        let cpuStart = Self.cpuSeconds()
        // Real run-loop turns: this is where an invalidation loop runs away,
        // since SwiftUI flushes its transactions from a run-loop observer.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let wall = Date().timeIntervalSince(wallStart)
        let cpu = Self.cpuSeconds() - cpuStart

        // The loop pinned a whole core (ratio ≈ 1.0, measured 100.0 % in `ps`).
        // A healthy streaming row wakes 30 times a second to advance a veil, so
        // the honest ceiling is well under a tenth of a core; 0.5 is a
        // deliberately loose bound that only a runaway can cross.
        #expect(
            cpu / wall < 0.5,
            "burned \(cpu) s CPU over \(wall) s wall — the render loop is back"
        )
        #endif
    }

    /// A row whose text grows on a timer, exactly as a streaming reply does.
    ///
    /// The freeze needed a WINDOW: `.task` and the run-loop observer that
    /// flushes SwiftUI transactions only run for a hosted, on-screen view, and
    /// the loop lived in that flush. This drives the real thing.
    private struct StreamingHost: View {
        let clock: SupermuxZeronPulseClock
        let full: String
        @State private var shown = ""

        var body: some View {
            SupermuxZeronAssistantRow(
                text: shown,
                isStreaming: true,
                theme: .dark,
                rowKey: "streaming-host-row"
            )
            .environment(\.supermuxZeronPulseClock, clock)
            .frame(width: SupermuxZeronMetrics.Transcript.maxContentWidth)
            .task {
                // ~20 deltas at 25 ms, the cadence a real reply streams at.
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(25))
                    let next = full.prefix(shown.count + max(1, full.count / 20))
                    shown = String(next)
                }
            }
        }
    }

    /// The time limit is load-bearing, not boilerplate. Against the pre-fix
    /// code this test does not fail, it **hangs**: the render loop pins the main
    /// actor, so the `await`s below never resume and the whole test run wedges
    /// at 99 % CPU (measured — the harness process sat in state `R` forever,
    /// with `body.getter` → `projectedSpans` → `commitSpans` → `veil.advance` on
    /// the stack, the same signature as the app freeze). Without the limit, a
    /// reintroduced loop would time out a CI job instead of reporting a failure.
    @Test(
        "A LIVE streaming row in a window: deltas fade, CPU stays low, the clock parks",
        .timeLimit(.minutes(1))
    )
    func windowedStreamingRowStaysIdle() async throws {
        #if canImport(AppKit)
        let clock = SupermuxZeronPulseClock()
        let host = NSHostingView(
            rootView: AnyView(StreamingHost(clock: clock, full: Self.sample))
        )
        // An off-screen window is still a real window: `.task` runs, and
        // SwiftUI's run-loop observer flushes transactions — which is where the
        // pre-fix build spun forever.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        let cpuStart = Self.cpuSeconds()
        let wallStart = Date()
        // Cover the whole stream plus the settle. `Task.sleep` yields the main
        // actor back to the run loop, which is what lets `.task` deltas and
        // SwiftUI's transaction flush actually run between turns —
        // `RunLoop.run(until:)` is unavailable from an async context.
        while Date().timeIntervalSince(wallStart) < 1.5 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let wall = Date().timeIntervalSince(wallStart)
        let cpu = Self.cpuSeconds() - cpuStart
        // The row starts EMPTY (height 0) and grows as deltas land, so a
        // non-zero height here is the proof that text actually streamed
        // through the live view rather than the test measuring a dead window.
        host.layoutSubtreeIfNeeded()
        try #require(
            host.fittingSize.height > 0,
            "nothing streamed into the hosted row — the measurement below is meaningless"
        )
        #expect(
            cpu / wall < 0.5,
            "burned \(cpu) s CPU over \(wall) s wall while streaming — the render loop is back"
        )

        // The stream finished during that window, so the veil must have settled
        // and released the clock. A clock still running here means a row is
        // renewing a lease forever — the 100 %-CPU shape, one step removed.
        while Date().timeIntervalSince(wallStart) < 2.5, clock.isRunning {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(!clock.isRunning, "a settled transcript must let the pulse clock PARK")
        #expect(clock.leaseCount == 0)
        #endif
    }

    // MARK: - The model's contract

    @Test("Projecting twice at one instant is observably inert; committing is not")
    func projectionIsInertAndCommitIsNot() {
        let model = SupermuxZeronStreamingMarkdownModel(seeded: false)
        let blocks = SupermuxZeronMarkdownParser.parseDisplay(Self.sample)
        let now = Date().timeIntervalSinceReferenceDate

        let projectionWrote = Flag()
        withObservationTracking {
            _ = model.projectedSpans(for: blocks, at: now)
        } onChange: {
            projectionWrote.set()
        }
        // Same inputs a second time: a projection that secretly committed would
        // trip the tracker here.
        let first = model.projectedSpans(for: blocks, at: now)
        #expect(!projectionWrote.isSet, "projection must not mutate the model")
        // …and it is deterministic, because nothing moved underneath it.
        #expect(first == model.projectedSpans(for: blocks, at: now))

        // The committing half is what the driver calls, and it MUST write —
        // otherwise the row observes nothing and the fade never repaints.
        let commitWrote = Flag()
        withObservationTracking {
            _ = model.projectedSpans(for: blocks, at: now)
        } onChange: {
            commitWrote.set()
        }
        model.commitSpans(for: blocks, at: now)
        #expect(commitWrote.isSet, "a commit must invalidate the rows observing the veil")
        #expect(model.isFading, "fresh text must register fading chunks")
    }

    @Test("Projection agrees with the commit that follows it, and the fade still settles")
    func projectionMatchesCommitAndSettles() {
        // The painted spans come from the projection and the state comes from
        // the commit, so the two running the same math is what keeps the fade
        // from stepping.
        let model = SupermuxZeronStreamingMarkdownModel(seeded: false)
        let blocks = SupermuxZeronMarkdownParser.parseDisplay("Hello world")
        let start = 1_000.0
        #expect(model.projectedSpans(for: blocks, at: start) == model.commitSpans(for: blocks, at: start))

        // Mid-fade the projection still matches, and opacity is climbing.
        let mid = start + 0.1
        let projected = model.projectedSpans(for: blocks, at: mid)
        #expect(projected == model.commitSpans(for: blocks, at: mid))
        #expect(model.isFading)

        // The first chunk's duration is the clamped seed EMA — 400 ms — so it
        // has settled well before 1 s, and a settled row emits NO spans at all.
        let after = start + 1
        #expect(model.projectedSpans(for: blocks, at: after).isEmpty)
        model.commitSpans(for: blocks, at: after)
        #expect(!model.isFading, "a settled veil must let the clock park")
    }

    @Test("A seeded row does not dissolve the reply it re-attached to")
    func seededRowDoesNotFade() {
        let model = SupermuxZeronStreamingMarkdownModel(seeded: true)
        let blocks = SupermuxZeronMarkdownParser.parseDisplay("An existing reply.")
        let now = 2_000.0
        // The attach pass adopts the text as a baseline: nothing fades, and the
        // projection agrees with it rather than showing a phantom fade.
        #expect(model.projectedSpans(for: blocks, at: now).isEmpty)
        #expect(model.commitSpans(for: blocks, at: now).isEmpty)
        #expect(!model.isFading)

        // Text appended AFTER the attach pass fades normally.
        let appended = SupermuxZeronMarkdownParser.parseDisplay("An existing reply. And more.")
        #expect(!model.commitSpans(for: appended, at: now + 0.05).isEmpty)
        #expect(model.isFading)
    }

    // MARK: - The clock's out-of-render tick

    @Test("`nextFrame` resumes on a tick, and on park, so a driver is never stranded")
    func nextFrameResumes() async {
        let clock = SupermuxZeronPulseClock()
        // A waiter takes a lease, which starts the clock.
        async let waited: Void = clock.nextFrame(leasedBy: "veil")
        // Give the suspension a turn to register before ticking.
        await Task.yield()
        #expect(clock.isRunning)
        _ = clock.tick()
        await waited

        // Releasing the last lease parks the clock; anything suspended on a
        // frame that will never come must be woken rather than leaked.
        async let stranded: Void = clock.nextFrame(leasedBy: "veil")
        await Task.yield()
        clock.releaseLease("veil")
        await stranded
        #expect(!clock.isRunning)
    }
}
