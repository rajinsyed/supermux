import Foundation
import SupermuxClaudeHarness
@testable import SupermuxKit
import Testing

@Suite("Mobile Claude transcript projection")
struct SupermuxMobileClaudeProjectionTests {
    @Test("streaming prose replaces the same message wholesale")
    func streamingProseReplacesWholesale() throws {
        let lines = try [
            line(seq: 1, json: """
            {"type":"stream_event","session_id":"s","event":{"type":"message_start","message":{"id":"m","role":"assistant","content":[]}}}
            """),
            line(seq: 2, json: """
            {"type":"stream_event","session_id":"s","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}
            """),
            line(seq: 3, json: """
            {"type":"stream_event","session_id":"s","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hel"}}}
            """),
            line(seq: 4, json: """
            {"type":"stream_event","session_id":"s","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}}
            """),
        ]

        let projection = SupermuxMobileClaudeProjection(lines: lines)

        #expect(projection.messages.count == 1)
        #expect(projection.messages[0].id == "m-0")
        #expect(projection.messages[0].text == "hello")
        #expect(projection.messages[0].seq == 4)
    }

    @Test("tool summaries are bounded while full output remains fetchable")
    func toolOutputIsBounded() throws {
        let output = String(repeating: "x", count: 5_000)
        let escapedOutput = try #require(String(
            data: JSONEncoder().encode(output), encoding: .utf8
        ))
        let lines = try [
            line(seq: 1, json: """
            {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"pwd"}}]}}
            """),
            line(seq: 2, json: """
            {"type":"user","session_id":"s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":\(escapedOutput),"is_error":false}]}}
            """),
        ]

        let projection = SupermuxMobileClaudeProjection(lines: lines)
        let message = try #require(projection.messages.first)
        let summary = try #require(message.tool?.outputSummary)
        let payload = try #require(projection.toolPayloads["tool-tool-1"])

        #expect(Data(summary.utf8).count == SupermuxMobileClaudeProjection.eventToolOutputLimit)
        #expect(String(data: payload, encoding: .utf8) == output)
        #expect(message.tool?.isComplete == true)
    }

    private func line(seq: UInt64, json: String) throws -> ClaudeTranscriptLine {
        let value = try JSONDecoder().decode(ClaudeJSONValue.self, from: Data(json.utf8))
        return ClaudeTranscriptLine(seq: seq, line: ClaudeStreamLine.decode(value))
    }
}
