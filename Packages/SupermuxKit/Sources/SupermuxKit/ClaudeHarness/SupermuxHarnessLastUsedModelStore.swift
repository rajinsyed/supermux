public import Foundation

/// Persists the model (and effort) most recently USED by any harness pane on
/// this machine, so a brand-new pane can default to it instead of the CLI's
/// settings-file model.
///
/// The real CLI persists a model into `~/.claude/settings.json` only when the
/// user explicitly saves it "as your default for new sessions" — a plain
/// `/model` switch is "for this session only" and is forgotten on exit. The
/// harness remembers it here instead: every model a session actually runs with
/// (a pick carried into a start, a live `set_model` ack) updates this store,
/// and `harness.context` delivers it as the strongest *default* — still below
/// everything session-specific (live init, user pick, restore snapshot,
/// replayed history).
///
/// One machine-wide value, deliberately NOT keyed per binary path or per pane:
/// "the last model I used, in any session" is the user's mental model.
///
/// Isolation: this stateless value holds an immutable `UserDefaults` reference,
/// whose API is documented thread-safe.
public struct SupermuxHarnessLastUsedModelStore: Sendable {
    private static let modelKey = "supermux.harness.lastUsedModel"
    private static let effortKey = "supermux.harness.lastUsedEffort"

    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a last-used-model store for the supplied defaults suite.
    ///
    /// - Parameter defaults: The defaults suite in which the value is persisted.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The most recently used model and effort, or `nil` when nothing has been
    /// recorded yet (the settings-file default then stands alone).
    public func snapshot() -> (model: String, effort: String?)? {
        guard let model = defaults.string(forKey: Self.modelKey), !model.isEmpty else {
            return nil
        }
        let effort = defaults.string(forKey: Self.effortKey)
        return (model, effort?.isEmpty == false ? effort : nil)
    }

    /// Records a model use.
    ///
    /// An absent effort leaves the stored effort untouched rather than clearing
    /// it: the wire spells one model several ways (`opus[1m]`,
    /// `claude-opus-5[1m]`, `claude-opus-5`), so "did the model change" cannot
    /// be answered reliably here — and a preserved level is clamped against the
    /// active model's supported levels on display anyway.
    ///
    /// - Parameters:
    ///   - model: The model selector or resolved id the session ran with.
    ///   - effort: The effort in force, when the caller knows it.
    public func store(model: String, effort: String?) {
        guard !model.isEmpty else { return }
        defaults.set(model, forKey: Self.modelKey)
        if let effort, !effort.isEmpty {
            defaults.set(effort, forKey: Self.effortKey)
        }
    }

    /// Removes the recorded value, so the settings-file default stands alone.
    public func clear() {
        defaults.removeObject(forKey: Self.modelKey)
        defaults.removeObject(forKey: Self.effortKey)
    }
}
