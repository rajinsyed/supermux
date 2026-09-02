/// Picker semantics shared by the Mac sheet and the phone sheet, so both
/// resolve "which model row is the default" and "which effort levels apply"
/// identically.
public extension Array where Element == SupermuxAgentModelDTO {
    /// The canonical order Claude Code lists effort levels in.
    static let canonicalEffortOrder = ["low", "medium", "high", "xhigh", "max"]

    /// Claude Code's own catalog entry for "use the settings default" (its
    /// `value` is literally `default`). Our pickers represent that choice as
    /// *no* `--model` flag, so this entry is folded into the default row
    /// instead of being listed as a selectable model.
    var defaultEntry: SupermuxAgentModelDTO? {
        first { $0.value.lowercased() == "default" }
    }

    /// The models offered as explicit `--model` selections (the CLI's
    /// `default` entry excluded).
    var selectableModels: [SupermuxAgentModelDTO] {
        filter { $0.value.lowercased() != "default" }
    }

    /// The effort levels available for a selection.
    ///
    /// - A named model contributes its own levels (empty when it takes no
    ///   `--effort`).
    /// - The default row (`nil`) uses the CLI's `default` entry when the
    ///   catalog has one, otherwise the union of every model's levels in
    ///   canonical order — Claude's default model is one of them, and the CLI
    ///   warns (rather than fails) on a level it does not accept.
    /// - An empty catalog offers the canonical list, so effort stays usable
    ///   when the model probe was unavailable.
    /// - Parameter selection: The `--model` value, or `nil` for the default.
    func effortLevels(forSelection selection: String?) -> [String] {
        if let selection {
            guard let model = first(where: { $0.value == selection }), model.supportsEffort else { return [] }
            return model.supportedEffortLevels
        }
        if let defaultEntry, defaultEntry.supportsEffort, !defaultEntry.supportedEffortLevels.isEmpty {
            return defaultEntry.supportedEffortLevels
        }
        let union = Set(selectableModels.filter(\.supportsEffort).flatMap(\.supportedEffortLevels))
        if union.isEmpty {
            return isEmpty ? Self.canonicalEffortOrder : []
        }
        return Self.canonicalEffortOrder.filter(union.contains)
            + union.subtracting(Self.canonicalEffortOrder).sorted()
    }
}
