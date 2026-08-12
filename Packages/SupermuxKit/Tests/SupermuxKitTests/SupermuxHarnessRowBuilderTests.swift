import Foundation
import SupermuxClaudeHarness
import Testing
@testable import SupermuxKit

/// Transcript projection: the rule that matters is that refinements UPDATE a
/// row rather than appending a second one. Every streaming delta appending a
/// row would make the transcript grow without bound and destroy `LazyVStack`
/// identity, which is what animates rows instead of re-inserting them.
struct SupermuxHarnessRowBuilderTests {
    private func line(_ json: String) -> ClaudeStreamLine {
        let value = try! JSONDecoder().decode(ClaudeJSONValue.self, from: Data(json.utf8))
        return ClaudeStreamLine.decode(value)
    }

    @Test func streamingTextCoalescesIntoOneRow() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"message_start",
        "message":{"id":"msg_1","role":"assistant","content":[]}}}
        """))
        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"content_block_start",
        "index":0,"content_block":{"type":"text","text":""}}}
        """))
        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"content_block_delta",
        "index":0,"delta":{"type":"text_delta","text":"Hel"}}}
        """))
        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"content_block_delta",
        "index":0,"delta":{"type":"text_delta","text":"lo"}}}
        """))

        #expect(builder.rows.count == 1)
        guard case .assistantProse(let text, let isStreaming) = builder.rows[0].kind else {
            Issue.record("expected prose row, got \(builder.rows[0].kind)")
            return
        }
        #expect(text == "Hello")
        #expect(isStreaming)

        builder.consume(line("""
        {"type":"stream_event","session_id":"s","event":{"type":"content_block_stop","index":0}}
        """))
        guard case .assistantProse(_, let stillStreaming) = builder.rows[0].kind else {
            Issue.record("expected prose row")
            return
        }
        #expect(!stillStreaming)
        #expect(builder.rows.count == 1)
    }

    @Test func toolResultUpdatesTheOriginatingToolRow() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"msg_1","role":"assistant",
        "content":[{"type":"tool_use","id":"toolu_1","name":"Bash",
        "input":{"command":"echo ok"}}]}}
        """))
        #expect(builder.rows.count == 1)
        guard case .toolCall(let running) = builder.rows[0].kind else {
            Issue.record("expected tool row")
            return
        }
        #expect(running.status == .running)
        #expect(running.subject == "echo ok")

        builder.consume(line("""
        {"type":"user","session_id":"s","message":{"role":"user","content":[
        {"tool_use_id":"toolu_1","type":"tool_result","content":"ok","is_error":false}]},
        "tool_use_result":{"stdout":"ok","stderr":""}}
        """))

        // Still ONE row: the result refines the call, it is not a new event.
        #expect(builder.rows.count == 1)
        guard case .toolCall(let finished) = builder.rows[0].kind else {
            Issue.record("expected tool row")
            return
        }
        #expect(finished.status == .succeeded)
        #expect(finished.resultText == "ok")
    }

    @Test func toolResultErrorMarksTheCallFailed() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x"}}]}}
        """))
        builder.consume(line("""
        {"type":"user","session_id":"s","message":{"role":"user","content":[
        {"tool_use_id":"t1","type":"tool_result","content":"no such file","is_error":true}]}}
        """))
        guard case .toolCall(let call) = builder.rows[0].kind else {
            Issue.record("expected tool row")
            return
        }
        #expect(call.status == .failed)
    }

    @Test func replayedPromptsRenderOnceEvenWhenBackfilledTwice() {
        var builder = SupermuxHarnessRowBuilder()
        let prompt = """
        {"type":"user","session_id":"s","uuid":"u-1","isReplay":true,
        "message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
        """
        builder.consume(line(prompt))
        builder.consume(line(prompt))
        #expect(builder.rows.count == 1)
        guard case .userPrompt(let text) = builder.rows[0].kind else {
            Issue.record("expected prompt row")
            return
        }
        #expect(text == "hi")
    }

    @Test func thinkingBlocksProjectSeparatelyFromProse() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "content":[{"type":"thinking","thinking":"pondering","signature":"sig"}]}}
        """))
        #expect(builder.rows.count == 1)
        guard case .thinking(let text, _) = builder.rows[0].kind else {
            Issue.record("expected thinking row, got \(builder.rows[0].kind)")
            return
        }
        #expect(text == "pondering")
    }

    @Test func resultLineProjectsCostSummary() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"result","subtype":"success","is_error":false,"duration_ms":1234,
        "num_turns":2,"total_cost_usd":0.0321,"uuid":"r-1",
        "usage":{"input_tokens":10,"output_tokens":20}}
        """))
        guard case .result(let summary) = builder.rows[0].kind else {
            Issue.record("expected result row")
            return
        }
        #expect(summary.totalCostUSD == 0.0321)
        #expect(summary.numTurns == 2)
        #expect(summary.inputTokens == 10)
    }

    @Test func todoWriteInputProjectsPlanSteps() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "content":[{"type":"tool_use","id":"t","name":"TodoWrite","input":{"todos":[
        {"content":"one","status":"completed"},
        {"content":"two","status":"in_progress"},
        {"content":"three","status":"pending"}]}}]}}
        """))
        guard case .toolCall(let call) = builder.rows[0].kind else {
            Issue.record("expected tool row")
            return
        }
        let todos = call.todos
        #expect(todos.count == 3)
        #expect(todos[0].state == .completed)
        #expect(todos[1].state == .inProgress)
        #expect(todos[2].state == .pending)
    }

    @Test func unknownToolFallsBackToAReadableLabel() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "content":[{"type":"tool_use","id":"t","name":"mcp__codex__codex","input":{}}]}}
        """))
        guard case .toolCall(let call) = builder.rows[0].kind else {
            Issue.record("expected tool row")
            return
        }
        #expect(call.labels.running.contains("codex: codex"))
    }

    @Test func derivedTitleClipsOnAWordBoundary() {
        let short = SupermuxHarnessViewModel.title(fromPrompt: "Fix the login bug")
        #expect(short == "Fix the login bug")

        let long = SupermuxHarnessViewModel.title(
            fromPrompt: "Please refactor the entire authentication subsystem today\nsecond line"
        )
        #expect(long.count <= 41)
        #expect(long.hasSuffix("…"))
        // Clipped on a space, never mid-word.
        #expect(!long.dropLast().hasSuffix(" "))
    }
}
