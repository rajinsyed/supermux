import Foundation
import Testing
@testable import SupermuxKit

/// Newline framing across arbitrary chunk boundaries with bounded lines.
struct ClaudeLineFramerTests {
    private func lines(_ frames: [ClaudeLineFramer.Frame]) -> [String] {
        frames.compactMap {
            if case .line(let data) = $0 { return String(decoding: data, as: UTF8.self) }
            return nil
        }
    }

    @Test func chunkedWritesAcrossLineBoundaries() {
        var framer = ClaudeLineFramer()
        var collected: [ClaudeLineFramer.Frame] = []
        // One JSON line split across three chunks, then a second complete line.
        collected += framer.consume(Data(#"{"type":"sys"#.utf8))
        #expect(collected.isEmpty)
        collected += framer.consume(Data("tem\"}\n{\"a\":".utf8))
        #expect(lines(collected) == [#"{"type":"system"}"#])
        collected += framer.consume(Data("1}\n".utf8))
        #expect(lines(collected) == [#"{"type":"system"}"#, #"{"a":1}"#])
        #expect(framer.finish() == nil)
    }

    @Test func finalFragmentWithoutNewlineIsFlushedAtEOF() {
        var framer = ClaudeLineFramer()
        let frames = framer.consume(Data("first\npartial".utf8))
        #expect(lines(frames) == ["first"])
        #expect(framer.finish() == .line(Data("partial".utf8)))
        // finish is idempotent.
        #expect(framer.finish() == nil)
    }

    @Test func bannerLineBeforeJSONSurvivesFraming() {
        var framer = ClaudeLineFramer()
        let banner = "\u{1B}[2mccx → model via proxy\u{1B}[0m\n{\"type\":\"system\"}\n"
        let frames = framer.consume(Data(banner.utf8))
        let framed = lines(frames)
        #expect(framed.count == 2)
        #expect(framed[0].contains("ccx"))
        #expect(framed[1] == #"{"type":"system"}"#)
    }

    @Test func oversizedLineIsDiscardedThroughNextNewline() {
        var framer = ClaudeLineFramer(maxLineBytes: 8)
        var frames = framer.consume(Data("0123456789abcdef".utf8))
        #expect(frames.isEmpty)
        frames += framer.consume(Data("more\nnext\n".utf8))
        // The oversized frame reports the discarded byte count; the following
        // line still parses.
        #expect(frames.count == 2)
        guard case .oversized(let count) = frames[0] else {
            Issue.record("expected oversized, got \(frames[0])")
            return
        }
        #expect(count >= 16)
        #expect(frames[1] == .line(Data("next".utf8)))
    }

    @Test func oversizedLineWithNewlineInSameChunkIsStillBounded() {
        // Regression: the bound must hold when the newline arrives together
        // with the over-limit bytes in one chunk.
        var framer = ClaudeLineFramer(maxLineBytes: 4)
        let frames = framer.consume(Data("12345\nok\n".utf8))
        #expect(frames.count == 2)
        #expect(frames[0] == .oversized(byteCount: 5))
        #expect(frames[1] == .line(Data("ok".utf8)))
    }

    @Test func oversizedFinalFragmentReportsAtEOF() {
        var framer = ClaudeLineFramer(maxLineBytes: 4)
        _ = framer.consume(Data("toolong".utf8))
        guard case .oversized = framer.finish() else {
            Issue.record("expected oversized at EOF")
            return
        }
    }

    @Test func emptyLinesAreFramed() {
        var framer = ClaudeLineFramer()
        let frames = framer.consume(Data("\n\n".utf8))
        #expect(frames == [.line(Data()), .line(Data())])
    }
}
