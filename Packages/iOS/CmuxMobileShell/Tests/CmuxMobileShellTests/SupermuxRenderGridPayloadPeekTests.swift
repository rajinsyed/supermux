// SUPERMUX:begin render-grid-sink-first
import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// A phone finds which terminal a render-grid frame is for before decoding
/// it, so frames for terminals it does not show cost a key lookup instead of
/// a full decode on the main actor.
@Suite struct SupermuxRenderGridPayloadPeekTests {
    private static let surfaceID = "123E4567-E89B-42D3-A456-426614174000"

    private static func framePayload(rows: Int = 4) throws -> Data {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: 7,
            columns: 120,
            rows: rows,
            rowSpans: (0..<rows).map {
                MobileTerminalRenderGridFrame.RowSpan(
                    row: $0,
                    column: 0,
                    styleID: 0,
                    text: String(repeating: "x", count: 120)
                )
            }
        )
        return try JSONEncoder().encode(frame)
    }

    @Test func bareFrameNamesItsTerminalAndDecodesOnce() throws {
        let payload = try Self.framePayload()
        let peek = try #require(SupermuxRenderGridPayloadPeek.read(payload))
        #expect(peek.frameSurfaceID == Self.surfaceID)
        #expect(peek.wrapped == nil)
        #expect(peek.decodeFrame(payload)?.stateSeq == 7)
    }

    @Test func wrappedFrameNamesItsTerminalAndDecodesOnce() throws {
        let frame = try JSONSerialization.jsonObject(with: Self.framePayload())
        let payload = try JSONSerialization.data(withJSONObject: ["render_grid": frame])
        let peek = try #require(SupermuxRenderGridPayloadPeek.read(payload))
        #expect(peek.frameSurfaceID == Self.surfaceID)
        #expect(peek.decodeFrame(payload)?.surfaceID == Self.surfaceID)
    }

    @Test func malformedPayloadsAreDropped() {
        #expect(SupermuxRenderGridPayloadPeek.read(Data("[1,2]".utf8)) == nil)
        #expect(SupermuxRenderGridPayloadPeek.read(Data("not json".utf8)) == nil)
        let noTerminal = SupermuxRenderGridPayloadPeek.read(Data(#"{"rows":3}"#.utf8))
        #expect(noTerminal?.frameSurfaceID == nil)
    }

    /// Reading the terminal costs far less than the decode it saves (the
    /// upstream path decoded the wrapper and then the bare frame).
    @Test func peekIsMuchCheaperThanTheDecodeItSkips() throws {
        let payload = try Self.framePayload(rows: 60)
        let clock = ContinuousClock()
        let iterations = 200
        let decode = clock.measure {
            for _ in 0..<iterations {
                _ = try? MobileTerminalRenderGridEvent.decode(payload)
                _ = try? MobileTerminalRenderGridFrame.decode(payload)
            }
        }
        let peek = clock.measure {
            for _ in 0..<iterations {
                _ = SupermuxRenderGridPayloadPeek.read(payload)
            }
        }
        print("render-grid peek \(peek) vs decode \(decode) for \(iterations) x \(payload.count) bytes")
        #expect(peek * 3 < decode, "peek \(peek) vs decode \(decode) for \(payload.count) bytes")
    }
}
// SUPERMUX:end render-grid-sink-first
