import Foundation
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.usage.state`: the Mac side of the iOS usage tracker.
///
/// The snapshot is read straight off ``SupermuxComposition/usageModel`` — the
/// exact model the sidebar gauge and popover render, never a second fetch
/// path — and projected by the package-tested
/// ``SupermuxMobileUsagePayloadBuilder``.
///
/// The request asks the model to refresh before answering, which matters when
/// no Mac window has a sidebar mounted: the model's poll loop is view-driven,
/// so without this the phone would sit on `loading` forever.
///
/// Rate limiting: `refresh()` is the unforced entry point, so it obeys the
/// model's hard floor (`minimumRefreshInterval`, 30 s) and its in-flight
/// guard, and that floor is SHARED with the desktop poll loop and the
/// popover's refresh button. Every caller on this Mac therefore adds up to at
/// most one provider pass per 30 s — the ceiling the model already documents,
/// and one the desktop refresh button could already reach on its own. A phone
/// polling faster just collects `.throttled` and gets the cached snapshot.
/// The phone's own store polls at the desktop's 120 s cadence, so in normal
/// use it roughly doubles the pass rate rather than multiplying it.
extension TerminalController {
    /// `mobile.supermux.usage.state`: `{claude: …, codex: …}` — both provider
    /// columns exactly as the desktop tracker holds them after a
    /// floor-throttled refresh.
    @MainActor
    func v2SupermuxUsageState(params: [String: Any]) async -> V2CallResult {
        let model = SupermuxComposition.usageModel
        await model.refresh()
        do {
            let payload = try SupermuxMobileUsagePayloadBuilder().usageState(
                claude: model.claude,
                codex: model.codex
            )
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode usage state", data: nil)
        }
    }
}
