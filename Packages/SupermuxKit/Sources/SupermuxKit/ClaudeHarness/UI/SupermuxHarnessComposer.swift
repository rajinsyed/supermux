import AppKit
import SwiftUI
import CmuxFoundation
import SupermuxClaudeHarness
import SupermuxZeronUI

/// The macOS mount of the shared zeron composer pill.
///
/// Owns only what a platform shell must own: the `NSTextView` bridge, the flip
/// reducer's state, the slash model, popover anchoring, and the file picker.
/// Every painted dimension comes from `SupermuxZeronUI`, so the phone renders
/// the identical geometry from the identical constants.
///
/// ── Layout, bottom-up (spec 04 §1.7 / §6) ──
///
/// ```
/// ┌ status strip ── 24 pt, RESERVED, empty in most states ─────────┐
/// ├ notice chip ── only when a failure is set ─────────────────────┤
/// ├ pill ── 49 compact / 124…308 expanded, radius 26 ──────────────┤
/// └ footer ── "Local checkout" · "⌥ main", 20 pt, git only ────────┘
///   the column: max 768, mx-auto, gap 8, px 16, pb 16
/// ```
///
/// ── Wiring: the data path is untouched ──
///
/// The composer calls exactly the `SupermuxHarnessViewModel` methods the old one
/// did — `send()`, `interrupt()`, `cancelQueued(id:)`, `setModel(_:)`,
/// `setEffort(_:)`, `setFastMode(_:)`, `setMaxThinkingTokens(_:)` — through the
/// same closures, so queueing, interrupts, model/effort selection, fast mode and
/// the thinking budget all behave exactly as before. The initializer's parameter
/// list is unchanged for the same reason: `SupermuxHarnessView` still compiles
/// against it while the rest of the port lands.
struct SupermuxHarnessComposer: View {
    typealias Flip = SupermuxZeronComposerFlip
    private typealias Metrics = SupermuxZeronMetrics.Composer

    @Binding var text: String
    let queue: [ClaudeQueuedInput]
    let slashCommands: [String]
    let modelLabel: String
    let models: [ClaudeModelDescriptor]
    let selectedModel: String?
    let effortLevels: [String]
    let effortLevel: String?
    let supportsFastMode: Bool
    let fastMode: Bool
    let maxThinkingTokens: Int?
    let isBusy: Bool
    let canSend: Bool
    let theme: SupermuxZeronTheme
    let onSend: () -> Void
    let onInterrupt: () -> Void
    let onCancelQueued: (UUID) -> Void
    let onSelectModel: (String) -> Void
    let onSelectEffort: (String) -> Void
    let onToggleFastMode: (Bool) -> Void
    let onSetThinkingBudget: (Int) -> Void

    /// A send is in flight but the turn has not started — the strip shows
    /// "Sending…" and the working trailer hides its timer.
    var isSending: Bool = false
    /// Whether the session's PROCESS failed — the strip's `Errored` indicator.
    /// Distinct from ``failure``, which is a message rendered as the notice
    /// chip; see ``stripState``.
    var isRunFailed: Bool = false
    /// A failure that is not part of the transcript. Shown as the notice chip.
    var failure: String?
    /// The footer row's two labels. Absent unless the project has git.
    var footer: SupermuxZeronComposerFooter.Item?
    var footerBranch: SupermuxZeronComposerFooter.Item?
    /// Reports the measured composer + strip height, which the transcript's
    /// last row pads itself by (`bottomClearance`, plan §3.6).
    var onMeasureClearance: (CGFloat) -> Void = { _ in }

    // MARK: Flip / morph state

    @State private var flip = Flip()
    @State private var expanded = false
    /// The pill's target height. Animated ONLY on a committed flip; auto-grow
    /// moves it instantly, exactly as the source does.
    @State private var pillHeight: CGFloat = Metrics.compactTotal
    @State private var baseHeight: CGFloat = Metrics.compactTotal
    /// The eased 0…1 morph phase driving the transient anchoring offsets. It is
    /// 1 at rest in both modes.
    @State private var morphProgress: Double = 1
    @State private var morphFromHeight: CGFloat?
    @State private var contentHeight: CGFloat = Metrics.inputLineHeight
    @State private var innerWidth: CGFloat = 720

    // MARK: Input / menu state

    @State private var isInputFocused = false
    @State private var caret = 0
    @State private var slash = SupermuxZeronSlashState()
    /// The two sibling menus. They are mutually exclusive — opening one closes
    /// the other, exactly as clicking between zeron's chips switches menus.
    @State private var showsModelMenu = false
    @State private var showsTraitsMenu = false
    /// One guard shared by BOTH chips, which is what makes clicking the second
    /// while the first is open SWITCH rather than swallow the click.
    @State private var pressGuard = SupermuxZeronMenuPressGuard()
    @State private var dismissedFailure: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var zeron: SupermuxZeronTheme { theme }

    // MARK: - Body

    var body: some View {
        // The strip is a SIBLING of the composer column, not a child of it
        // (`shell.rs:4626`: `.child(status).child(composer)` on an un-gapped
        // flex_col). It carries its own `max_w(768) mx-auto px-24`, so its
        // content sits 8 pt further in than the pill's border — aligned with
        // the pill's inner text. Nesting it inside the column would inherit the
        // column's own px-16 on top and add a gap zeron does not have.
        VStack(spacing: 0) {
            SupermuxZeronStatusStrip(theme: zeron, state: stripState)
            container
        }
        .background(clearanceReader)
        .onPreferenceChange(SupermuxComposerHeightKey.self) { onMeasureClearance($0) }
        .onChange(of: text) { _, _ in syncSlash() }
        .onChange(of: caret) { _, _ in syncSlash() }
    }

    /// `mx-auto w-full max-w-3xl · gap-8 · px-16 pb-16` (`composer.rs:5318`).
    ///
    /// gpui's `max_w` caps the BORDER box, so the 16 pt gutters live INSIDE the
    /// 768 and the pill measures 736 — which is what `docs/screenshot.png`
    /// samples (x 495 → 1231). SwiftUI's `.frame(maxWidth:)` caps the content
    /// box, so the padding has to be applied first or the pill comes out 768.
    private var container: some View {
        VStack(spacing: Metrics.containerGap) {
            if let notice = visibleFailure {
                SupermuxZeronComposerNotice(
                    theme: zeron,
                    severity: notice.severity,
                    message: notice.message,
                    onDismiss: { dismissedFailure = notice.message }
                )
            }
            if sendMode == .steer {
                SupermuxZeronSteerHint(theme: zeron)
            }
            pill
            if let footer, let footerBranch {
                SupermuxZeronComposerFooter(
                    theme: zeron,
                    leading: footer,
                    trailing: footerBranch,
                    mode: .labels
                )
            }
            if !visibleQueue.isEmpty {
                queueChips
            }
        }
        .padding(.horizontal, Metrics.containerPadX)
        .padding(.bottom, Metrics.containerPadBottom)
        .frame(maxWidth: Metrics.containerMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var pill: some View {
        SupermuxZeronComposerPill(
            theme: zeron,
            expanded: expanded,
            height: pillHeight,
            baseHeight: baseHeight,
            morphProgress: morphProgress,
            morphFromHeight: morphFromHeight
        ) {
            input
        } actions: {
            actions
        }
        // The slash card's bottom-left corner sits at the `/` glyph's top-left
        // with a 6 pt gap, opening upward. The glyph is always at the input's
        // leading edge (a slash command is a whole-prompt prefix, so its `/` is
        // character 0), which is why this anchors to the pill's top-leading
        // rather than tracking a caret rect.
        .overlay(alignment: .topLeading) { slashCard }
        // The runtime menus' anchor. On the PILL, not inside the actions row —
        // see `menuAnchor`.
        .overlay(alignment: .bottomTrailing) { menuAnchor }
    }

    private var input: some View {
        SupermuxZeronComposerTextView(
            text: $text,
            theme: zeron,
            // zeron's exact string (`composer.rs:3369`), U+2026 — NOT three
            // dots. Resolved against the shared package's own catalog: the
            // app-target key `supermux.harness.composer.placeholder` still
            // carries the pre-port "Message Claude Code" / 「Claude Code にメッセージ」,
            // and `String(localized:)` would return that translated value in
            // both languages rather than falling back to this default.
            placeholder: String(
                localized: "supermux.zeron.composer.placeholder",
                defaultValue: "Do anything…",
                bundle: .supermuxZeronUI
            ),
            isFocused: $isInputFocused,
            onMeasure: applyMeasurement,
            onCaretChange: { caret = $0 },
            onSubmit: submit,
            onMenuKey: handleMenuKey
        )
    }

    @ViewBuilder
    private var actions: some View {
        SupermuxZeronActionsRow(
            theme: zeron,
            model: .init(
                modelLabel: modelLabel,
                effortLabel: effortChipLabel,
                effortCustomized: effortCustomized,
                openChip: openChip
            ),
            sendMode: sendMode,
            isSendBlocked: isSendBlocked,
            // supermux has no attachment pipeline yet; the button would open a
            // picker that stages nothing.
            showsAttach: false,
            onOpenModel: { toggle(Self.modelMenuID) },
            onOpenEffort: { toggle(Self.traitsMenuID) },
            onSubmit: submit,
            onInterrupt: onInterrupt
        )
    }

    // MARK: - Runtime menus

    /// The zero-size anchor both runtime menus hang from.
    ///
    /// ── Why it is not attached to the actions row ──
    ///
    /// `SupermuxZeronActionsRow`'s body is a `TupleView` on purpose, so the
    /// pill's `gap-1` HStack sees the chips, attach and send as DIRECT children
    /// and the 4 pt inter-button distances survive. A modifier applied to a view
    /// whose body is a tuple is applied to **each element** — the same rule that
    /// makes `.padding()` on a `Group` pad every child — so hanging a popover
    /// there mounts one card per child. (The pre-assembly build did exactly
    /// that with `.popover(arrowEdge:)`.) A zero-size pin in the pill's own
    /// overlay has no such problem.
    ///
    /// ── The offsets ──
    ///
    /// Aligned bottom-trailing on the pill, then pushed to the chip cluster's
    /// top-right corner. **Both offsets depend on the committed mode**, which is
    /// the whole reason they are computed rather than constant — the pill rests
    /// COMPACT, and the expanded geometry is 4 pt further in and 2.5 pt higher:
    ///
    /// | | compact (49 pt pill) | expanded (124…308) |
    /// |---|---|---|
    /// | trailing | `8 + 28 + 4` = **40** | `12 + 28 + 4` = **44** |
    /// | bottom | `(47 − 32)/2 + 32` = **39.5** | `10 + 32` = **42** |
    ///
    /// The trailing value comes from `clusterInset(expanded:morph:)`, the same
    /// function the pill itself uses, so the anchor glides with the cluster
    /// through the 180 ms morph instead of jumping at the commit. The compact
    /// bottom is the chip's own centre in the bottom-justified 47 pt row; the
    /// expanded one is `pb-2.5` plus the chip.
    ///
    /// Attach is not mounted here (`showsAttach: false`), so the send button and
    /// one gap are the entire distance from the pill's edge to the chips.
    ///
    /// The modifier then adds zeron's own 6 pt gap and opens upward.
    ///
    /// **Documented deviation:** zeron flushes each menu with **its own** chip's
    /// right edge (`pickers.rs:3574`). Both menus here flush with the cluster's
    /// right edge, which is the traits chip's. Reproducing per-chip anchoring
    /// needs a measured chip width, and the cards are 240–360 pt against ~60–90
    /// pt chips, so the model card overhangs to the left in either case.
    private var menuAnchor: some View {
        // A zero-size layout pin, not a resting wash — the one sanctioned use of
        // `Color.clear` in this port.
        Color.clear
            .frame(width: 0, height: 0)
            // NOT `.popover(arrowEdge:)`, which brings a system arrow, material,
            // radius and shadow, none of them zeron's. This gives MENU_IN
            // (opacity 0.3 → 1 plus a −2 pt rise, 140 ms EASE), MENU_OUT,
            // BottomRight anchoring, the 6 pt gap, the 8 pt window clamp,
            // outside-press dismissal, and Escape.
            //
            // The two menus share ONE press guard but carry DIFFERENT
            // identities: that is what makes a click on the traits chip while
            // the model card is open SWITCH menus, rather than being swallowed
            // by the dismissal the same press already began.
            .supermuxZeronAnchoredMenu(
                isPresented: $showsModelMenu,
                identity: Self.modelMenuID,
                pressGuard: pressGuard
            ) {
                runtimeMenu(.model)
            }
            .supermuxZeronAnchoredMenu(
                isPresented: $showsTraitsMenu,
                identity: Self.traitsMenuID,
                pressGuard: pressGuard
            ) {
                runtimeMenu(.traits)
            }
            .padding(.trailing, chipClusterTrailingInset)
            .padding(.bottom, chipClusterBottomInset)
    }

    /// The runtime menus carry model, effort, fast mode and the thinking budget
    /// — every capability the old runtime bar had, through the same closures.
    private func runtimeMenu(_ menu: SupermuxHarnessRuntimePopover.Menu) -> some View {
        SupermuxHarnessRuntimePopover(
            models: models,
            selectedModel: selectedModel,
            effortLevels: effortLevels,
            effortLevel: effortLevel,
            supportsFastMode: supportsFastMode,
            fastMode: fastMode,
            maxThinkingTokens: maxThinkingTokens,
            theme: zeron,
            onSelectModel: onSelectModel,
            onSelectEffort: onSelectEffort,
            onToggleFastMode: onToggleFastMode,
            onSetThinkingBudget: onSetThinkingBudget,
            menu: menu,
            onDismiss: {
                showsModelMenu = false
                showsTraitsMenu = false
            }
        )
    }

    /// Which chip holds the open wash.
    private var openChip: SupermuxZeronActionsRow.Model.Chip? {
        if showsModelMenu { return .model }
        if showsTraitsMenu { return .effort }
        return nil
    }

    /// Opens one menu and closes its sibling, consuming the press guard's note.
    ///
    /// The guard's note exists because the outside-press dismissal fires on the
    /// SAME press that becomes this click: by click time the menu already reads
    /// closed, and a naive `toggle()` would immediately reopen it.
    private func toggle(_ identity: String) {
        let wasOpen = pressGuard.takePressWasOpen(identity: identity)
        showsModelMenu = false
        showsTraitsMenu = false
        guard !wasOpen else { return }
        if identity == Self.modelMenuID {
            showsModelMenu = true
        } else {
            showsTraitsMenu = true
        }
    }

    /// The chip cluster's right edge, measured from the pill's trailing edge.
    ///
    /// Reads the SAME `clusterInset(expanded:morph:)` the pill lays the cluster
    /// out with, so the anchor tracks the 180 ms morph rather than snapping at
    /// the commit. Compact 8 + 28 + 4 = 40; expanded 12 + 28 + 4 = 44.
    private var chipClusterTrailingInset: CGFloat {
        Flip.clusterInset(expanded: expanded, morph: morphProgress)
            + SupermuxZeronMetrics.Composer.sendDiameter
            + Flip.clusterGap
    }

    /// The chips' top edge, measured from the pill's bottom edge.
    ///
    /// Expanded, the actions row is an overlay at the pill's stationary bottom
    /// with `pb-2.5`, so the chip's top is `10 + 32 = 42`. Compact, the cluster
    /// is centred in the bottom-justified 47 pt row, putting its top at
    /// `(47 − 32)/2 + 32 = 39.5`. The 2.5 pt difference is exactly the cluster
    /// delta the morph glides, so it is taken from `clusterOffsetY` rather than
    /// recomputed — one source, and it cannot drift from the painted cluster.
    private var chipClusterBottomInset: CGFloat {
        let expandedTop = Flip.actionsPadBottom + SupermuxZeronMetrics.Composer.triggerChipHeight
        let compactTop = (Flip.compactRowHeight - SupermuxZeronMetrics.Composer.triggerChipHeight) / 2
            + SupermuxZeronMetrics.Composer.triggerChipHeight
        let resting = expanded ? expandedTop : compactTop
        // `clusterOffsetY` is positive-down; the anchor measures UP from the
        // pill's bottom, so the glide subtracts.
        return resting - Flip.clusterOffsetY(expanded: expanded, morph: morphProgress)
    }

    private static let modelMenuID = "composer-model"
    private static let traitsMenuID = "composer-traits"

    // MARK: - Slash menu

    @ViewBuilder
    private var slashCard: some View {
        if slash.isOpen {
            SupermuxZeronSlashMenu(
                theme: zeron,
                commands: zeronCommands,
                state: slash,
                onSelect: { slash.select(row: $0) },
                onAccept: { row in
                    slash.select(row: row)
                    acceptSlash()
                }
            )
            // Bottom-left at the `/` glyph's top-left, 6 pt of air, opening
            // upward.
            .fixedSize()
            .alignmentGuide(.top) { $0[.bottom] + 6 }
            .alignmentGuide(.leading) { _ in -Metrics.textBoxPadX }
        }
    }

    /// The view-model's `[String]` lifted into the shared command model.
    ///
    /// supermux's `system.init` advertises names only; zeron's row renders the
    /// description as an empty run when there is none, which is exactly what an
    /// empty string produces.
    private var zeronCommands: [SupermuxZeronSlashCommand] {
        slashCommands.map { SupermuxZeronSlashCommand(name: $0) }
    }

    private func syncSlash() {
        slash.sync(text: text, caret: caret, commands: zeronCommands)
    }

    private func acceptSlash() {
        guard let applied = slash.accept(in: text, commands: zeronCommands) else { return }
        text = applied.text
        caret = applied.caret
        syncSlash()
    }

    /// The slash menu redirects five keys while it is open; the input keeps
    /// focus and native text editing throughout.
    private func handleMenuKey(_ key: SupermuxZeronComposerMenuKey) -> Bool {
        guard slash.isOpen else { return false }
        switch key {
        case .up:
            slash.move(by: -1)
            return true
        case .down:
            slash.move(by: 1)
            return true
        case .tab:
            acceptSlash()
            return true
        case .accept:
            // Return accepts only while a row is highlighted; otherwise it
            // falls through to Submit.
            guard slash.acceptedCommand(from: zeronCommands) != nil else { return false }
            acceptSlash()
            return true
        case .dismiss:
            slash.dismiss()
            return true
        }
    }

    // MARK: - The flip

    /// Folds one layout pass into the committed mode and the pill's height.
    ///
    /// Called from the text view's measurement callback — never from `body` —
    /// so this never writes state during a view update (cmux #2586).
    private func applyMeasurement(_ measurement: Flip.Measurement) {
        contentHeight = measurement.contentHeight
        if measurement.lastWidth > 0 { innerWidth = measurement.lastWidth }
        let nowMS = Date().timeIntervalSince1970 * 1000
        let outcome = flip.evaluate(measurement, nowMS: nowMS)
        let nextExpanded = outcome.expanded
        let nextBase = Flip.baseHeight(
            expanded: nextExpanded,
            contentHeight: measurement.contentHeight
        )
        let nextTarget = nextBase // attachments are not staged on macOS yet

        guard outcome.committedFlip else {
            // Auto-grow: the target moves INSTANTLY. Only a flip morphs.
            expanded = nextExpanded
            baseHeight = nextBase
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { pillHeight = nextTarget }
            return
        }

        // One committed flip starts exactly one 180 ms `COLLAPSE` morph. The
        // layout below commits immediately — the caret never jumps and the text
        // view never remounts — while the pill's height and the transient
        // anchoring offsets ease to the new mode's geometry.
        //
        // SwiftUI, not a display link, drives it: `withAnimation` interpolates
        // the frame height and the pill's `animatableData`, retargets in flight
        // when auto-grow moves the target, and hands off from the presented
        // value on a reversal — the three properties `FlipMorph` exists to give.
        //
        // Known simplification: `morphProgress` is reset to 0 before the
        // animation, so a SECOND flip inside the first's 180 ms restarts the
        // 2.5 pt cluster offset rather than handing off. zeron's own comment
        // notes user-driven flips "need typing and can't land this fast".
        let from = pillHeight
        morphFromHeight = from
        expanded = nextExpanded
        baseHeight = nextBase
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { morphProgress = 0 }
        guard !reduceMotion else {
            // Reduced motion: the morph is never created (a one-shot snaps to
            // its END state).
            morphProgress = 1
            morphFromHeight = nil
            withTransaction(reset) { pillHeight = nextTarget }
            return
        }
        withAnimation(SupermuxZeronMetrics.Motion.collapse.animation) {
            pillHeight = nextTarget
            morphProgress = 1
        }
    }

    // MARK: - Send

    private var sendMode: SupermuxZeronSendMode {
        SupermuxZeronSendMode.mode(runLive: isBusy, hasText: hasText)
    }

    /// Trimmed input non-empty, or at least one staged attachment.
    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Dimmed to 0.35 and fully inert. supermux blocks only when the session
    /// cannot accept the prompt at all — `canSend` already encodes that.
    private var isSendBlocked: Bool { !canSend && !isBusy }

    private func submit() {
        // Return with a highlighted slash row is intercepted upstream, so
        // reaching here means the user meant to send.
        guard sendMode.submits, !isSendBlocked else { return }
        slash.dismiss()
        onSend()
    }

    // MARK: - Status strip

    /// Spec 04 §6.1's table, in its own precedence order.
    ///
    /// `.errored` is keyed on ``isRunFailed`` — the PROCESS died — and NOT on
    /// ``failure``. They are different signals with different surfaces: zeron's
    /// `Errored` indicator is the session's run state, while its composer error
    /// chip is a separate field, and supermux's `failure` (a spawn rejection, a
    /// refused control) is already fully rendered as the chip above the pill.
    /// Keying the strip off `failure` too painted the generic "Run failed"
    /// directly under the specific message that had just explained the problem.
    private var stripState: SupermuxZeronStatusStripState {
        if isSending { return .sending }
        if isBusy { return .working }
        if isRunFailed { return .errored }
        return .idle
    }

    private var visibleFailure: (severity: SupermuxZeronComposerNotice.Severity, message: String)? {
        guard let failure, failure != dismissedFailure else { return nil }
        // zeron keys "offline" off one exact message; supermux's equivalent is
        // a dead process, which the notice text already says.
        return (.failure, failure)
    }

    // MARK: - Chips

    /// The traits chip's label — supermux's effort/fast-mode ladder collapsed
    /// onto zeron's `traits_summary`: the parts joined by `" · "`.
    ///
    /// Returns `nil` when the model has neither a reasoning ladder nor fast
    /// mode, which OMITS the chip entirely — "a dead trigger reads as broken".
    /// All three segments resolve against the SHARED package's catalog, beside
    /// the placeholder — these keys do not exist in the app target, so
    /// `String(localized:)` without the bundle would ship the English
    /// `defaultValue` to Japanese users silently.
    private var effortChipLabel: String? {
        var parts: [String] = []
        if let effortLevel, !effortLevel.isEmpty {
            parts.append(effortLevel.capitalized)
        } else if !effortLevels.isEmpty {
            parts.append(
                String(
                    localized: "supermux.zeron.composer.traits",
                    defaultValue: "Traits",
                    bundle: .supermuxZeronUI
                )
            )
        }
        if fastMode {
            parts.append(
                String(
                    localized: "supermux.zeron.composer.fast",
                    defaultValue: "Fast",
                    bundle: .supermuxZeronUI
                )
            )
        }
        if maxThinkingTokens != nil {
            parts.append(
                String(
                    localized: "supermux.zeron.composer.thinking",
                    defaultValue: "Thinking",
                    bundle: .supermuxZeronUI
                )
            )
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Whether anything departs from the defaults, which brightens the chip's
    /// label from `textMuted` to `text @ 0.9`.
    private var effortCustomized: Bool {
        effortLevel != nil || fastMode || maxThinkingTokens != nil
    }

    // MARK: - Queue

    /// Entries the user can still act on. Acknowledged ones are history.
    private var visibleQueue: [ClaudeQueuedInput] {
        queue.filter { $0.state == .queued || $0.state == .dispatching || $0.state == .uncertain }
    }

    private var queueChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SupermuxZeronMetrics.Theme.spaceXS) {
                ForEach(visibleQueue) { entry in
                    SupermuxHarnessQueueChip(
                        entry: entry,
                        theme: zeron,
                        onCancel: { onCancelQueued(entry.id) }
                    )
                }
            }
        }
        .frame(maxHeight: 26)
    }

    // MARK: - Clearance

    /// Publishes the composer's own height for the transcript's last-row pad.
    /// A preference, not a `body` write — measuring must never mutate state
    /// during a view update.
    private var clearanceReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: SupermuxComposerHeightKey.self, value: proxy.size.height)
        }
    }
}

/// The measured composer + strip height, read by the transcript.
struct SupermuxComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Queue chip

/// One queued-prompt chip with its delivery state.
///
/// Retained from the pre-port composer: zeron has no queue, because it steers
/// mid-turn instead. supermux queues, and dropping the chips would drop a real
/// capability — so they keep their behavior and take the zeron palette.
struct SupermuxHarnessQueueChip: View {
    let entry: ClaudeQueuedInput
    let theme: SupermuxZeronTheme
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: SupermuxZeronMetrics.Theme.spaceXS) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(color)
            Text(entry.text)
                .font(SupermuxZeronFonts.sans(size: SupermuxZeronMetrics.Chips.textSize))
                .foregroundStyle(theme.textMuted)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            if entry.state == .queued {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, SupermuxZeronMetrics.Theme.spaceSM)
        .frame(height: SupermuxZeronMetrics.Composer.footerRowHeight)
        .background(Capsule(style: .continuous).fill(theme.ink(0.03)))
        .overlay(Capsule(style: .continuous).strokeBorder(theme.hairline(0.07), lineWidth: 1))
        .help(helpText)
    }

    private var symbol: String {
        switch entry.state {
        case .queued: "clock"
        case .dispatching: "paperplane"
        case .uncertain: "questionmark.circle"
        case .acknowledged: "checkmark"
        case .cancelled: "xmark"
        }
    }

    private var color: Color {
        switch entry.state {
        case .uncertain: theme.danger
        case .dispatching: theme.accent
        default: theme.textFaint
        }
    }

    private var helpText: String {
        switch entry.state {
        case .uncertain:
            String(
                localized: "supermux.harness.queue.uncertain",
                defaultValue: "Claude Code exited before confirming this prompt. It was not resent."
            )
        case .dispatching:
            String(
                localized: "supermux.harness.queue.dispatching",
                defaultValue: "Sending…"
            )
        default:
            String(
                localized: "supermux.harness.queue.queued",
                defaultValue: "Queued"
            )
        }
    }
}
