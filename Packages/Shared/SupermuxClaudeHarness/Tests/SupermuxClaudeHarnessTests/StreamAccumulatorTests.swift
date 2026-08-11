import Foundation
import Testing
@testable import SupermuxClaudeHarness

/// Production accumulator/reconciler behavior over captured fixtures and
/// synthetic malformed cases.
struct StreamAccumulatorTests {
    private func accumulate(_ name: String) throws -> (
        ClaudeStreamAccumulator, [ClaudeStreamAccumulator.Event]
    ) {
        var accumulator = ClaudeStreamAccumulator()
        var events: [ClaudeStreamAccumulator.Event] = []
        for line in try FixtureSupport.decode(name).lines {
            events.append(contentsOf: accumulator.consume(line))
        }
        return (accumulator, events)
    }

    private func diagnostics(
        _ events: [ClaudeStreamAccumulator.Event]
    ) -> [ClaudeHarnessDiagnostic] {
        events.compactMap {
            if case .diagnostic(let diagnostic) = $0 { return diagnostic }
            return nil
        }
    }

    @Test func toolTurnReassemblesInputAtBlockStop() throws {
        let (accumulator, events) = try accumulate("tool-turn.jsonl")
        #expect(diagnostics(events).isEmpty)

        // Two API messages (tool call, then text answer).
        let messages = accumulator.messages
        #expect(messages.count == 2)

        let toolMessage = try #require(messages.first)
        let toolBlock = try #require(toolMessage.blocks.first { block in
            if case .toolUse = block.content { return true }
            return false
        })
        guard case .toolUse(_, let name, let input, _) = toolBlock.content else {
            Issue.record("expected toolUse block")
            return
        }
        #expect(name == "Bash")
        // The reassembled streamed input equals the authoritative input.
        #expect(input["command"]?.stringValue == "echo ok")
        #expect(toolBlock.isComplete)
        #expect(toolBlock.isAuthoritative)
        #expect(toolBlock.undecodablePartialJSON == nil)
    }

    @Test func thinkingTurnAccumulatesThinkingAndSignature() throws {
        let (accumulator, events) = try accumulate("thinking-turn.jsonl")
        #expect(diagnostics(events).isEmpty)

        // Both blocks reconcile into ONE message keyed by the API message ID,
        // not one message per assistant line.
        let messages = accumulator.messages
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message.blocks.count == 2)
        #expect(message.isComplete)

        guard case .thinking(let thinking, let signature) = message.blocks[0].content else {
            Issue.record("expected thinking block first")
            return
        }
        // The authoritative line's (possibly empty) thinking replaced the
        // draft; the signature is real.
        _ = thinking
        #expect(signature?.isEmpty == false)
        guard case .text = message.blocks[1].content else {
            Issue.record("expected text block second")
            return
        }
        #expect(message.blocks.allSatisfy { $0.isAuthoritative })
    }

    @Test func simpleTurnAuthoritativeTextReplacesDraftWithoutDuplication() throws {
        let (accumulator, events) = try accumulate("simple-turn.jsonl")
        #expect(diagnostics(events).isEmpty)
        let message = try #require(accumulator.messages.first)
        let textBlocks = message.blocks.compactMap { block -> String? in
            if case .text(let text, _) = block.content { return text }
            return nil
        }
        #expect(textBlocks.count == 1)
        // Streamed deltas joined equal the authoritative text — replacement,
        // never append-duplication.
        let fixture = try FixtureSupport.decode("simple-turn.jsonl")
        let authoritative = fixture.assistants.flatMap(\.message.content).compactMap {
            if case .text(let text, _) = $0 { return text } else { return nil }
        }.joined()
        #expect(textBlocks[0] == authoritative)
    }

    @Test func malformedPartialInputIsPreservedAndDiagnosed() {
        var accumulator = ClaudeStreamAccumulator()
        func consume(_ json: String) -> [ClaudeStreamAccumulator.Event] {
            guard case .json(let value) = ClaudeLineClassifier.classify(json) else {
                Issue.record("bad test line")
                return []
            }
            return accumulator.consume(ClaudeStreamLine.decode(value))
        }
        var events: [ClaudeStreamAccumulator.Event] = []
        events += consume(#"{"type":"stream_event","session_id":"s","event":{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}}"#)
        events += consume(#"{"type":"stream_event","session_id":"s","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}}}"#)
        events += consume(#"{"type":"stream_event","session_id":"s","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"cmd\": tru"}}}"#)
        events += consume(#"{"type":"stream_event","session_id":"s","event":{"type":"content_block_stop","index":0}}"#)

        let diagnostics = events.compactMap { event -> ClaudeHarnessDiagnostic? in
            if case .diagnostic(let diagnostic) = event { return diagnostic }
            return nil
        }
        #expect(diagnostics.contains(
            .toolInputUndecodable(toolUseID: "toolu_1", messageID: "msg_1")
        ))
        let block = accumulator.messages.first?.blocks.first
        #expect(block?.undecodablePartialJSON == #"{"cmd": tru"#)

        // The authoritative assistant line then reconciles the block.
        events = consume(#"{"type":"assistant","session_id":"s","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"cmd":true}}],"stop_reason":"tool_use"}}"#)
        let reconciled = try? #require(accumulator.messages.first?.blocks.first)
        #expect(reconciled?.isAuthoritative == true)
        #expect(reconciled?.undecodablePartialJSON == nil)
        guard case .toolUse(_, _, let input, _) = reconciled?.content else {
            Issue.record("expected toolUse")
            return
        }
        #expect(input["cmd"]?.boolValue == true)
    }

    @Test func streamedAuthoritativeToolInputMismatchIsDiagnosed() {
        var accumulator = ClaudeStreamAccumulator()
        func consume(_ json: String) -> [ClaudeStreamAccumulator.Event] {
            guard case .json(let value) = ClaudeLineClassifier.classify(json) else { return [] }
            return accumulator.consume(ClaudeStreamLine.decode(value))
        }
        _ = consume(#"{"type":"stream_event","session_id":"s","event":{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}}"#)
        _ = consume(#"{"type":"stream_event","session_id":"s","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}}}"#)
        _ = consume(#"{"type":"stream_event","session_id":"s","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"streamed\"}"}}}"#)
        // The authoritative line carries a DIFFERENT input.
        let events = consume(#"{"type":"assistant","session_id":"s","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"authoritative"}}]}}"#)
        let sawMismatch = events.contains {
            if case .diagnostic(.toolInputMismatch(let id)) = $0 { return id == "toolu_1" }
            return false
        }
        #expect(sawMismatch)
        // The authoritative input wins.
        guard case .toolUse(_, _, let input, _) =
            accumulator.messages.first?.blocks.first?.content else {
            Issue.record("expected toolUse")
            return
        }
        #expect(input["command"]?.stringValue == "authoritative")
    }

    @Test func deltasWithoutMessageStartUseSyntheticKeyThenAdopt() {
        var accumulator = ClaudeStreamAccumulator()
        func consume(_ json: String) -> [ClaudeStreamAccumulator.Event] {
            guard case .json(let value) = ClaudeLineClassifier.classify(json) else { return [] }
            return accumulator.consume(ClaudeStreamLine.decode(value))
        }
        // No message_start: block events land on a synthetic message.
        _ = consume(#"{"type":"stream_event","session_id":"s","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#)
        _ = consume(#"{"type":"stream_event","session_id":"s","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}}"#)
        #expect(accumulator.messages.count == 1)
        #expect(accumulator.messages.first?.key.messageID.hasPrefix("synthetic-") == true)

        // The authoritative assistant line re-keys the synthetic draft.
        _ = consume(#"{"type":"assistant","session_id":"s","message":{"id":"msg_real","role":"assistant","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}}"#)
        #expect(accumulator.messages.count == 1)
        #expect(accumulator.messages.first?.key.messageID == "msg_real")
        #expect(accumulator.messages.first?.isComplete == true)
    }

    @Test func emptyThinkingDeltaDoesNotTerminateTheBlock() {
        var accumulator = ClaudeStreamAccumulator()
        func consume(_ json: String) -> [ClaudeStreamAccumulator.Event] {
            guard case .json(let value) = ClaudeLineClassifier.classify(json) else { return [] }
            return accumulator.consume(ClaudeStreamLine.decode(value))
        }
        _ = consume(#"{"type":"stream_event","session_id":"s","event":{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}}"#)
        _ = consume(#"{"type":"stream_event","session_id":"s","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#)
        _ = consume(#"{"type":"stream_event","session_id":"s","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"","estimated_tokens":12}}}"#)
        let block = accumulator.messages.first?.blocks.first
        #expect(block != nil)
        #expect(block?.isComplete == false)
        guard case .thinking = block?.content else {
            Issue.record("thinking block must survive an empty delta")
            return
        }
    }
}
