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
    /// How long a first request waits for an already-running pass to land
    /// before answering `loading`. Bounded so a wedged provider fetch can
    /// never hold an RPC open.
    @MainActor
    private static var usageFirstPassWait: Duration { .seconds(5) }

    /// `mobile.supermux.usage.state`: `{claude: …, codex: …}` — both provider
    /// columns exactly as the desktop tracker holds them after a
    /// floor-throttled refresh.
    @MainActor
    func v2SupermuxUsageState(params: [String: Any]) async -> V2CallResult {
        let model = SupermuxComposition.usageModel
        await model.refresh()
        // `refresh()` returns immediately with `.alreadyRefreshing` when a
        // pass is already in flight, which is fine once there is data to
        // serve — the payload is self-describing and the phone repolls. But
        // on the FIRST request it would answer `loading` for both providers
        // and strand the phone on a spinner for a full poll period, even
        // though the pass lands seconds later. So when nothing has been
        // measured yet, briefly wait the running pass out.
        await waitForFirstUsagePass(model)
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

    /// Waits out an in-flight pass, but only while BOTH providers are still
    /// `loading` (nothing has ever been measured) and only up to
    /// ``usageFirstPassWait``. Polling `isRefreshing` rather than awaiting the
    /// pass keeps this handler read-only against the shared model — no new
    /// continuation or completion hook has to be threaded through it.
    @MainActor
    private func waitForFirstUsagePass(_ model: SupermuxUsageModel) async {
        func hasNothingToServe() -> Bool {
            if case .loading = model.claude, case .loading = model.codex { return true }
            return false
        }
        guard hasNothingToServe(), model.isRefreshing else { return }
        let deadline = ContinuousClock().now.advanced(by: Self.usageFirstPassWait)
        while model.isRefreshing, hasNothingToServe(), ContinuousClock().now < deadline {
            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return }
        }
    }
}
