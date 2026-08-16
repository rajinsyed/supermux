import SwiftUI
import SupermuxClaudeHarness
import SupermuxZeronUI

/// The macOS anchoring of the shared zeron picker card.
///
/// Two sibling menus hang off the composer's chip cluster, exactly as in zeron
/// (`pickers.rs:3526–3601`):
///
/// * **Model** — the 360 × 346 rail + pane card
///   (``SupermuxZeronPickerCard``). Picking dismisses.
/// * **Traits** — the 240 pt menu card of headed sections
///   (``SupermuxZeronMenuCard``). Picking KEEPS IT OPEN for multi-adjust
///   (`pickers.rs:3038`), which is why effort, fast mode and the thinking
///   budget can be set in one visit. supermux's ladder stands in for zeron's
///   reasoning ladder + model options (plan §0.4) through the same primitives.
///
/// Both mount through ``SupermuxZeronAnchoredMenu``: `MENU_IN`, BottomRight to
/// the chip, 6 pt gap, 8 pt window clamp. Neither uses SwiftUI's `.popover()`,
/// which brings a system arrow, material, radius and shadow — none of them
/// zeron's.
///
/// The old AppKit-styled sheet this replaced also carried an effort *fill
/// slider*. zeron has no slider anywhere; the ladder is menu rows, and the
/// value it sets is identical.
struct SupermuxHarnessRuntimePopover: View {
    /// Which sibling menu is showing. `nil` = neither.
    enum Menu: String, Equatable {
        case model
        case traits
    }

    let models: [ClaudeModelDescriptor]
    let selectedModel: String?
    let effortLevels: [String]
    let effortLevel: String?
    let supportsFastMode: Bool
    let fastMode: Bool
    let maxThinkingTokens: Int?
    let theme: SupermuxZeronTheme
    /// The session has started and its model is fixed — the rail dims and takes
    /// no clicks, exactly like zeron's locked-harness treatment.
    var isLocked: Bool = false
    let onSelectModel: (String) -> Void
    let onSelectEffort: (String) -> Void
    let onToggleFastMode: (Bool) -> Void
    let onSetThinkingBudget: (Int) -> Void
    /// Which sibling menu to render. A caller with a single "is the runtime
    /// menu open" flag passes the default and gets the model picker.
    var menu: Menu = .model
    /// Called when a pick should dismiss the container. Defaults to a no-op so
    /// a caller that dismisses on its own (a `.popover` binding, say) needs no
    /// extra plumbing.
    var onDismiss: () -> Void = {}

    /// Rail, query and cursor.
    ///
    /// Owned HERE rather than by the shell: the state's whole job is to survive
    /// from open to open so a reopen re-anchors the cursor on the selected row,
    /// and the popover view is what lives exactly that long. A shell that wants
    /// to drive it (to preselect a rail, or to restore a query) can hoist it
    /// later without changing this file's other parameters.
    @State private var pickerState = SupermuxZeronPickerState()

    /// The budgets offered; `0` is "off" (Claude decides). zeron's traits
    /// sections are per-model option lists, and this is supermux's.
    private static let thinkingBudgets = [0, 4_000, 10_000, 32_000]

    @ViewBuilder
    var body: some View {
        switch menu {
        case .model:
            SupermuxZeronPickerCard(
                theme: theme,
                rows: rows,
                selectedID: selectedModel,
                state: $pickerState,
                isLocked: isLocked,
                onSelect: { row in
                    onSelectModel(row.id)
                    // The model picker dismisses on pick; the traits menu does
                    // not. zeron states no policy for this one either way
                    // (spec 08 §8.3) — dismissing matches every other
                    // single-choice picker in the app.
                    onDismiss()
                },
                // Escape closes it (`animate_close`, `pickers.rs:1932`).
                onDismiss: onDismiss
            )
        case .traits:
            traitsMenu
        }
    }

    // MARK: - Model rows

    /// The catalog as picker rows.
    ///
    /// zeron's subline is the harness identity; supermux has one harness, so it
    /// carries the model's own description, falling back to the raw `value`
    /// when the CLI gives none — an empty subline would collapse the two-line
    /// row to one and break the 42 pt rhythm.
    private var rows: [SupermuxZeronPickerRow] {
        models.map { model in
            SupermuxZeronPickerRow(
                id: model.value,
                label: model.displayName ?? model.value,
                subline: model.description?.isEmpty == false
                    ? (model.description ?? model.value)
                    : model.value
            )
        }
    }

    // MARK: - Traits

    private var traitsMenu: some View {
        SupermuxZeronMenuCard(theme: theme) {
            if !effortLevels.isEmpty {
                SupermuxZeronMenuSection(theme: theme, heading: Self.effortHeading) {
                    ForEach(effortLevels, id: \.self) { level in
                        SupermuxZeronMenuRow(
                            theme: theme,
                            label: level.capitalized,
                            isActive: level == effortLevel,
                            action: { onSelectEffort(level) }
                        )
                    }
                }
            }

            if supportsFastMode {
                if !effortLevels.isEmpty {
                    SupermuxZeronMenuSeparator(theme: theme)
                }
                SupermuxZeronMenuSection(theme: theme, heading: Self.fastModeHeading) {
                    SupermuxZeronMenuRow(
                        theme: theme,
                        label: Self.fastModeOff,
                        isActive: !fastMode,
                        action: { onToggleFastMode(false) }
                    ) {
                        SupermuxZeronDefaultBadge(theme: theme)
                    }
                    SupermuxZeronMenuRow(
                        theme: theme,
                        label: Self.fastModeOn,
                        isActive: fastMode,
                        action: { onToggleFastMode(true) }
                    )
                }
            }

            if !effortLevels.isEmpty || supportsFastMode {
                SupermuxZeronMenuSeparator(theme: theme)
            }
            SupermuxZeronMenuSection(theme: theme, heading: Self.thinkingHeading) {
                ForEach(Self.thinkingBudgets, id: \.self) { budget in
                    SupermuxZeronMenuRow(
                        theme: theme,
                        label: Self.budgetLabel(budget),
                        isActive: budget == (maxThinkingTokens ?? 0),
                        action: { onSetThinkingBudget(budget) }
                    ) {
                        if budget == 0 {
                            SupermuxZeronDefaultBadge(theme: theme)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Strings

    private static var effortHeading: String {
        String(localized: "supermux.harness.effort.title", defaultValue: "Effort")
    }

    private static var fastModeHeading: String {
        String(localized: "supermux.harness.model.fastMode", defaultValue: "Fast mode")
    }

    private static var fastModeOff: String {
        String(localized: "supermux.harness.model.fastMode.off", defaultValue: "Off")
    }

    private static var fastModeOn: String {
        String(localized: "supermux.harness.model.fastMode.on", defaultValue: "On")
    }

    private static var thinkingHeading: String {
        String(
            localized: "supermux.harness.thinking.budget.title",
            defaultValue: "Thinking budget"
        )
    }

    private static func budgetLabel(_ budget: Int) -> String {
        guard budget > 0 else {
            return String(
                localized: "supermux.harness.thinking.budget.off",
                defaultValue: "Auto"
            )
        }
        return "\(budget / 1000)k"
    }
}

// MARK: - Chip summary

/// The traits chip's label: zeron joins the effective summary with " · "
/// ("High · 1M · Fast") and **omits the chip entirely** when the model has
/// neither a ladder nor options — "a dead trigger reads as broken"
/// (`pickers.rs:3541–3543`).
///
/// An extension on the descriptor rather than a free helper: the summary is a
/// property of the model's capabilities, and the caller already holds one.
extension ClaudeModelDescriptor {
    /// The joined traits summary for a live runtime state, or `nil` when the
    /// chip must not render at all.
    static func supermuxTraitsSummary(
        effortLevels: [String],
        effortLevel: String?,
        supportsFastMode: Bool,
        fastMode: Bool,
        maxThinkingTokens: Int?
    ) -> String? {
        var parts: [String] = []
        if !effortLevels.isEmpty, let effortLevel {
            parts.append(effortLevel.capitalized)
        }
        if let maxThinkingTokens, maxThinkingTokens > 0 {
            parts.append("\(maxThinkingTokens / 1000)k")
        }
        if supportsFastMode, fastMode {
            parts.append(
                String(localized: "supermux.harness.model.fastMode", defaultValue: "Fast mode")
            )
        }
        // No ladder AND no options ⇒ no chip.
        guard !effortLevels.isEmpty || supportsFastMode else { return nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
