import Testing
@testable import SupermuxKit

/// Ways the flat-row device chip's link lookup could fail. The flat sidebar
/// row only knows the Mac's NAME (recovered from upstream's "Workspace on %@"
/// label), so the chip looks the Mac up among the known devices by name:
/// 1. A connected Mac renders dimmed (the common case looks broken).
/// 2. An offline Mac renders at full strength (the point of the change).
/// 3. A Mac that is dialing renders as offline (it should say "Connecting").
/// 4. Two Macs share a name and one is connected: the chip dims anyway, so a
///    live mirror looks dead.
/// 5. Two same-named Macs, one connecting and one offline: reads offline.
/// 6. A name no device carries (renamed Mac, restored mirror before the
///    catalog lists it, a multi-Mac label) claims "offline" without evidence.
/// 7. Surrounding whitespace in the recovered name defeats the match.
/// 8. The label fell back to the machine id (the name was unknown when it was
///    built): the chip cannot find the Mac.
/// 9. An empty name matches a device with an empty name and dims.
/// 10. Dimming is not exactly "not online".
struct SupermuxDeviceChipStateTests {
    private func mac(_ name: String, _ state: SupermuxDeviceChipState, id: String? = nil) -> SupermuxDeviceChipState.Candidate {
        SupermuxDeviceChipState.Candidate(name: name, machineID: id ?? "device:\(name)@tag", state: state)
    }

    @Test func connectedMacIsOnline() {
        #expect(SupermuxDeviceChipState.resolve(name: "MacBook", among: [mac("MacBook", .online)]) == .online)
    }

    @Test func offlineMacIsOffline() {
        #expect(SupermuxDeviceChipState.resolve(name: "MacBook", among: [mac("MacBook", .offline)]) == .offline)
    }

    @Test func dialingMacIsConnecting() {
        #expect(SupermuxDeviceChipState.resolve(name: "MacBook", among: [mac("MacBook", .connecting)]) == .connecting)
    }

    @Test func anyConnectedSameNamedMacWins() {
        let devices = [mac("MacBook", .offline, id: "a"), mac("MacBook", .online, id: "b")]
        #expect(SupermuxDeviceChipState.resolve(name: "MacBook", among: devices) == .online)
    }

    @Test func connectingBeatsOfflineAmongSameNamedMacs() {
        let devices = [mac("MacBook", .offline, id: "a"), mac("MacBook", .connecting, id: "b")]
        #expect(SupermuxDeviceChipState.resolve(name: "MacBook", among: devices) == .connecting)
    }

    @Test func unknownNameIsNeverDimmed() {
        #expect(SupermuxDeviceChipState.resolve(name: "Studio", among: [mac("MacBook", .offline)]) == .online)
        #expect(SupermuxDeviceChipState.resolve(name: "Studio · MacBook", among: [mac("MacBook", .offline)]) == .online)
        #expect(SupermuxDeviceChipState.resolve(name: "Studio", among: []) == .online)
    }

    @Test func whitespaceAroundTheNameIsIgnored() {
        #expect(SupermuxDeviceChipState.resolve(name: "  MacBook ", among: [mac("MacBook", .offline)]) == .offline)
    }

    @Test func machineIDFallbackLabelMatches() {
        let devices = [mac("MacBook", .offline, id: "device:1234@stable")]
        #expect(SupermuxDeviceChipState.resolve(name: "device:1234@stable", among: devices) == .offline)
    }

    @Test func emptyNameIsNeverDimmed() {
        #expect(SupermuxDeviceChipState.resolve(name: "  ", among: [mac("", .offline, id: "x")]) == .online)
    }

    @Test func onlyNonOnlineStatesDim() {
        #expect(SupermuxDeviceChipState.online.isDimmed == false)
        #expect(SupermuxDeviceChipState.connecting.isDimmed)
        #expect(SupermuxDeviceChipState.offline.isDimmed)
    }
}
