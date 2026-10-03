import Foundation
import Testing

@testable import CMUXMobileCore

// SUPERMUX:begin replay-mouse-modes-last
/// Fork coverage for the full snapshot's mouse modes (`replay-mouse-modes-last`).
///
/// Ghostty keeps one mouse event mode and one mouse format, not one flag per
/// code: setting any of them replaces the current one, and resetting any of
/// them clears it (`ghostty/src/termio/stream_handler.zig`). The frame carries
/// one flag per code, so the replay must emit them in an order that ends on
/// the mode the program meant. These tests run the replay's mode sequences
/// through that model of Ghostty's state.
private struct GhosttyMouseState {
    static let eventCodes: Set<Int> = [9, 1000, 1002, 1003]
    static let formatCodes: Set<Int> = [1005, 1006, 1015, 1016]

    /// The event mode's code, or nil for none.
    var event: Int?
    /// The format's code, or nil for the default (x10).
    var format: Int?

    /// Applies every DEC private `CSI ? Pm h` / `CSI ? Pm l` in `vt`, in order.
    init(after vt: String) {
        let pattern = try! NSRegularExpression(pattern: "\u{1B}\\[\\?([0-9;]+)([hl])")
        let text = vt as NSString
        for match in pattern.matches(in: vt, range: NSRange(location: 0, length: text.length)) {
            let enabled = text.substring(with: match.range(at: 2)) == "h"
            for code in text.substring(with: match.range(at: 1)).split(separator: ";").compactMap({ Int($0) }) {
                if Self.eventCodes.contains(code) { event = enabled ? code : nil }
                if Self.formatCodes.contains(code) { format = enabled ? code : nil }
            }
        }
    }
}

private func replayVT(_ modes: [MobileTerminalRenderGridFrame.ModeSetting]) throws -> String {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 8,
        rows: 1,
        cursor: .init(row: 0, column: 0),
        rowSpans: [.init(row: 0, column: 0, text: "mouse")],
        activeScreen: .alternate,
        modes: modes
    )
    return try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
}

/// Every mouse mode code as the producer exports it: on for `enabled`, else off.
private func mouseModes(enabled: Set<Int>) -> [MobileTerminalRenderGridFrame.ModeSetting] {
    [9, 1000, 1002, 1003, 1005, 1006, 1015, 1016].map { .init(code: $0, on: enabled.contains($0)) }
}

/// crossterm's EnableMouseCapture (`?1000h ?1002h ?1003h ?1015h ?1006h`):
/// the urxvt format first, then SGR, which Ghostty keeps. A replay that ended
/// on `?1015h` sent clicks to the program as `CSI 32;x;yM`.
@Test func supermuxReplayKeepsSGRWhenURXVTIsAlsoOn() throws {
    let state = GhosttyMouseState(after: try replayVT(mouseModes(enabled: [1000, 1002, 1003, 1015, 1006])))
    #expect(state.format == 1006)
    #expect(state.event == 1003)
}

/// Claude Code's set (`?1000h ?1002h ?1006h`, with 1003/1015/1016 off): a
/// reset after the set must not clear tracking or the format.
@Test func supermuxReplayKeepsTrackingWhenLaterCodesAreOff() throws {
    let state = GhosttyMouseState(after: try replayVT(mouseModes(enabled: [1000, 1002, 1006])))
    #expect(state.event == 1002)
    #expect(state.format == 1006)
}

/// SGR pixels is set after SGR by the programs that ask for both.
@Test func supermuxReplayPrefersSGRPixelsOverSGR() throws {
    let state = GhosttyMouseState(after: try replayVT(mouseModes(enabled: [1003, 1006, 1016])))
    #expect(state.format == 1016)
}

@Test func supermuxReplayLeavesMouseOffWhenNothingIsOn() throws {
    let state = GhosttyMouseState(after: try replayVT(mouseModes(enabled: [])))
    #expect(state.event == nil)
    #expect(state.format == nil)
}
// SUPERMUX:end replay-mouse-modes-last
