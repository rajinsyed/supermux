// SUPERMUX:begin runtime-cloud-mutations-theme-harness
@testable import CmuxCloud

/// Deterministic send admission, ownership observations, and colors for theme regressions.
actor RuntimeCloudMutationsThemeHarness {
    nonisolated let entered = CloudLinkFirstValue<Bool>()
    nonisolated let release = CloudLinkFirstValue<Bool>()
    private var sends = 0
    private(set) var ownedTurns: [Bool] = []
    private(set) var colors = (foreground: "#112233", background: "#445566")

    func beforeSend() async {
        sends += 1
        if sends == 2 {
            entered.resolve(true)
            _ = await release.result
        }
    }

    func record(ownsTurn: Bool) { ownedTurns.append(ownsTurn) }
    func setColors(foreground: String, background: String) { colors = (foreground, background) }
}
// SUPERMUX:end runtime-cloud-mutations-theme-harness
