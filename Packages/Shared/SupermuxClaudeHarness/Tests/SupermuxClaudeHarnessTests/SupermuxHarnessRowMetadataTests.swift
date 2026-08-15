import Foundation
import Testing
@testable import SupermuxClaudeHarness

/// The four fields the transcript layout reads off every row: `turnStart`
/// (turn gap vs block gap), `entryID` (hover reveals the whole entry's
/// timestamp), `timestamp` (only once the turn has settled), and `version`
/// (the content fingerprint that keeps a streaming transcript from rebuilding
/// every visible row per delta).
struct SupermuxHarnessRowMetadataTests {
    private func line(_ json: String) -> ClaudeStreamLine {
        let value = try! JSONDecoder().decode(ClaudeJSONValue.self, from: Data(json.utf8))
        return ClaudeStreamLine.decode(value)
    }

    @Test func userRowsAlwaysCarryTheirTimestamp() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"user","session_id":"s","uuid":"u-1","isReplay":true,
        "timestamp":"2026-08-16T12:00:00.000Z",
        "message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
        """))
        #expect(builder.rows.count == 1)
        #expect(builder.rows[0].turnStart)
        #expect(builder.rows[0].entryID == "u-1")
        #expect(builder.rows[0].timestamp != nil)
    }

    /// "The turn isn't at a time yet": an assistant row gets its timestamp only
    /// once streaming has ended, and only on the entry's LAST row.
    @Test func assistantTimestampsLandOnTheLastRowOnceStreamingEnds() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"message_start",
        "message":{"id":"m","role":"assistant","content":[]}}}
        """))
        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"content_block_start",
        "index":0,"content_block":{"type":"text","text":""}}}
        """))
        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"content_block_delta",
        "index":0,"delta":{"type":"text_delta","text":"Hello"}}}
        """))
        #expect(builder.rows[0].timestamp == nil, "mid-stream rows have no time yet")
        let streamingVersion = builder.rows[0].version

        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"content_block_stop","index":0}}
        """))
        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"message_stop"}}
        """))
        #expect(builder.rows[0].timestamp != nil)
        // Stamping the time MUST bump the version: a tool-group row's own
        // fingerprint would not otherwise change when streaming flips off.
        #expect(builder.rows[0].version != streamingVersion)
    }

    @Test func onlyTheLastRowOfAnEntryIsStamped() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "stop_reason":"end_turn","content":[
        {"type":"text","text":"first"},
        {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
        """))
        #expect(builder.rows.count == 2)
        #expect(builder.rows[0].timestamp == nil)
        #expect(builder.rows[1].timestamp != nil)
        #expect(builder.rows.allSatisfy { $0.entryID == "m" })
    }

    /// A trailing group auto-expands mid-run and collapses when the turn
    /// completes; a non-trailing group never auto-opens.
    @Test func trailingGroupAutoOpensOnlyWhileStreaming() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"message_start",
        "message":{"id":"m","role":"assistant","content":[]}}}
        """))
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
        """))
        guard case .toolGroup(let streaming) = builder.rows[0].kind else {
            Issue.record("expected a tool group")
            return
        }
        #expect(streaming.autoOpen)

        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"message_stop"}}
        """))
        guard case .toolGroup(let settled) = builder.rows[0].kind else {
            Issue.record("expected a tool group")
            return
        }
        #expect(!settled.autoOpen)
    }

    @Test func aNonTrailingGroupNeverAutoOpens() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"message_start",
        "message":{"id":"m","role":"assistant","content":[]}}}
        """))
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "content":[
        {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}},
        {"type":"text","text":"done"}]}}
        """))
        guard case .toolGroup(let group) = builder.rows[0].kind else {
            Issue.record("expected a tool group first")
            return
        }
        #expect(!group.autoOpen)
    }

    /// Row equality on `(id, version)` is what makes the transcript splice only
    /// the tail: an untouched row must keep its fingerprint across a delta.
    @Test func settledRowsKeepTheirVersionAcrossADelta() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m1","role":"assistant",
        "stop_reason":"end_turn","content":[{"type":"text","text":"settled"}]}}
        """))
        let settled = builder.rows[0].version

        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"message_start",
        "message":{"id":"m2","role":"assistant","content":[]}}}
        """))
        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"content_block_start",
        "index":0,"content_block":{"type":"text","text":""}}}
        """))
        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"content_block_delta",
        "index":0,"delta":{"type":"text_delta","text":"growing"}}}
        """))
        #expect(builder.rows.count == 2)
        #expect(builder.rows[0].version == settled, "settled row untouched")
    }

    @Test func changingContentChangesTheVersion() {
        var a = SupermuxHarnessRowBuilder()
        a.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "content":[{"type":"text","text":"one"}]}}
        """))
        var b = SupermuxHarnessRowBuilder()
        b.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "content":[{"type":"text","text":"two"}]}}
        """))
        #expect(a.rows[0].id == b.rows[0].id)
        #expect(a.rows[0].version != b.rows[0].version)
    }

    /// The fingerprint must be stable across processes: it is a persisted and
    /// wire-visible value, so seeding it off Swift's per-process `Hashable`
    /// seed would silently invalidate every cached row on relaunch.
    @Test func theFingerprintIsProcessStable() {
        let row = SupermuxHarnessRow(
            id: "m#g0",
            kind: .toolGroup(
                SupermuxHarnessToolGroup(
                    id: "m#g0",
                    tools: [SupermuxHarnessToolCall(
                        id: "t1", name: "Bash",
                        input: .object(["command": .string("ls"), "timeout": .integer(5)]),
                        status: .succeeded, resultText: "ok"
                    )]
                )
            ),
            turnStart: true,
            entryID: "m"
        )
        #expect(SupermuxHarnessRowBuilder.fingerprint(of: row) == 18_067_002_217_672_994_380)
    }

    /// Regression: the fingerprint used to widen the CLI's signed counts with
    /// `UInt64(_:)`, which TRAPS on a negative value. A `result` line carrying
    /// `"duration_ms": -1` therefore took the whole app down from inside a
    /// projection that is supposed to be total. Every number here comes off an
    /// untrusted wire, so the hash must be bit-pattern, not range-checked.
    @Test func negativeWireCountsDoNotTrapTheFingerprint() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"result","subtype":"success","session_id":"s","uuid":"r-1",
        "duration_ms":-1,"num_turns":-2,"is_error":false}
        """))
        #expect(builder.rows.count == 1)

        let stats = SupermuxHarnessRow(
            id: "m#g0",
            kind: .toolGroup(SupermuxHarnessToolGroup(id: "m#g0", tools: [
                SupermuxHarnessToolCall(
                    id: "t1", name: "Edit", input: .object([:]), status: .succeeded,
                    diffStats: [SupermuxHarnessDiffStat(path: "a", additions: -3, deletions: -4)]
                ),
            ])),
            entryID: "m"
        )
        #expect(SupermuxHarnessRowBuilder.fingerprint(of: stats) != 0)

        // Non-negative values must hash exactly as they did before the fix, so
        // no persisted or wire-visible version silently changes.
        let positive = SupermuxHarnessRow(
            id: "m#g0",
            kind: .toolGroup(
                SupermuxHarnessToolGroup(
                    id: "m#g0",
                    tools: [SupermuxHarnessToolCall(
                        id: "t1", name: "Bash",
                        input: .object(["command": .string("ls"), "timeout": .integer(5)]),
                        status: .succeeded, resultText: "ok"
                    )]
                )
            ),
            turnStart: true,
            entryID: "m"
        )
        #expect(SupermuxHarnessRowBuilder.fingerprint(of: positive) == 18_067_002_217_672_994_380)
    }

    /// A tool result arriving on a later user line refines the call in place
    /// and must re-fingerprint the group row that owns it.
    @Test func aToolResultBumpsItsGroupsVersion() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
        """))
        let running = builder.rows[0].version
        builder.consume(line("""
        {"type":"user","session_id":"s","message":{"role":"user","content":[
        {"tool_use_id":"t1","type":"tool_result","content":"ok","is_error":false}]},
        "tool_use_result":{"stdout":"ok","stderr":""}}
        """))
        #expect(builder.rows.count == 1)
        #expect(builder.rows[0].version != running)
        guard case .toolGroup(let group) = builder.rows[0].kind else {
            Issue.record("expected a tool group")
            return
        }
        #expect(group.tools[0].status == .succeeded)
        #expect(group.tools[0].resultText == "ok")
    }
}
