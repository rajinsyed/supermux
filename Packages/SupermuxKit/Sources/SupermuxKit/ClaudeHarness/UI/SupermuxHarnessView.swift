//
//  SupermuxHarnessView.swift
//  SupermuxKit
//
//  The macOS chat pane. Plan §2.1: glass root → edge-faded transcript →
//  reserved status strip → composer.
//
//  ═══════════════════════════════════════════════════════════════════════════
//  THERE IS NO PANEL HEADER
//  ═══════════════════════════════════════════════════════════════════════════
//
//  zeron has none, and `SupermuxHarnessHeaderBar` is deleted with this rewrite.
//  Everything it carried has a new, better home (plan §2.1):
//
//  | Was in the header      | Now                                              |
//  |------------------------|--------------------------------------------------|
//  | working directory      | the composer FOOTER row's leading label          |
//  | git branch             | the composer FOOTER row's trailing label         |
//  | run state ("Working…") | the WORKING TRAILER under the transcript's last  |
//  |                        | row — a spinner, a flavour word, and the elapsed |
//  |                        | timer, which scroll away with the reply          |
//  | interrupt              | the composer's send→STOP morph (it always was    |
//  |                        | the only interrupt affordance; the header's      |
//  |                        | button was already removed)                      |
//  | total cost             | the RESULT META ROW at the end of the turn       |
//  | model name             | the composer's model TRIGGER CHIP                |
//
//  The consequence is deliberate: a Codex webview panel beside a Claude panel
//  now looks different, because the Ghostty-derived `SupermuxHarnessTheme` is
//  gone and zeron is a FIXED design system keyed only on `isDark`.
//
//  ═══════════════════════════════════════════════════════════════════════════
//  THE STACK, AND WHY IT IS A ZSTACK
//  ═══════════════════════════════════════════════════════════════════════════
//
//      SupermuxZeronWindowGlass            ← NSVisualEffectView + glass() tint
//        └ ZStack(alignment: .bottom)
//            ├ SupermuxHarnessTranscript   ← FULL BLEED, edge-faded, scrolls
//            │                               UNDER the composer stack
//            └ SupermuxHarnessComposer     ← status strip + pill, overlaid
//
//  The transcript is NOT a VStack sibling of the composer. It spans the whole
//  region and the composer floats over it, which is the premise of the entire
//  motion model: the last row pads itself by `bottomClearance + 24 + 8 +
//  runway` so pinned content clears the composer, and the fade's bottom band is
//  `stackHeight − 24` so content dissolves at the pill's top edge rather than
//  being clipped by a layout boundary (spec 02 §5.5/§6.3). Stacking them
//  vertically would make both of those numbers meaningless.
//
//  `bottomClearance` is measured by the composer and published through
//  `SupermuxComposerHeightKey`; the model stores it (with zeron's own sub-0.5 pt
//  jitter filter) and the transcript reads it back. ONE measurement, both
//  consumers — they cannot drift.
//
//  ═══════════════════════════════════════════════════════════════════════════
//  STATE OWNERSHIP
//  ═══════════════════════════════════════════════════════════════════════════
//
//  The model is passed in, never created here: `AgentSessionPanelView` renders
//  `Color.clear` when the panel is hidden, so a view-owned model would take the
//  running `claude` process down on every tab switch.
//
//  The syntax cache is `@State` here — ONE per pane, above the transcript's lazy
//  boundary, injected into the environment so every code block in every row
//  shares its LRU budget instead of each building its own.
//

public import SwiftUI
public import SupermuxZeronUI

internal import CmuxFoundation
internal import SupermuxClaudeHarness

/// The whole native Claude Code panel: transcript, status strip, composer.
public struct SupermuxHarnessView: View {
    @Bindable private var model: SupermuxHarnessViewModel
    private let theme: SupermuxZeronTheme
    private let stableSurfaceID: UUID?

    /// One highlight cache per pane. Without this every code block silently
    /// builds its own and shares no work (spec 05 / W3's handoff note).
    @State private var syntaxCache = SupermuxZeronSyntaxCache()

    /// Creates the harness panel view.
    /// - Parameters:
    ///   - model: The registry-owned session model for this panel.
    ///   - theme: The zeron palette, keyed only on the panel's appearance.
    ///   - stableSurfaceID: The panel's persisted identity, read lazily by the
    ///     mount (upstream adopts it after the panel is constructed).
    public init(
        model: SupermuxHarnessViewModel,
        theme: SupermuxZeronTheme,
        stableSurfaceID: UUID?
    ) {
        self.model = model
        self.theme = theme
        self.stableSurfaceID = stableSurfaceID
    }

    public var body: some View {
        SupermuxZeronWindowGlass(theme: theme) {
            switch model.phase {
            case .setup:
                setupContent
            case .session:
                sessionContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.supermuxZeronSyntaxCache, syntaxCache)
        .task(id: stableSurfaceID) {
            guard let stableSurfaceID else { return }
            await model.adopt(stableSurfaceID: stableSurfaceID)
        }
        // The footer's branch label. Re-resolved when the directory changes,
        // which is the only thing that can change it from this pane.
        .task(id: model.workingDirectory) {
            await model.refreshGitBranch()
        }
    }

    // MARK: - Setup

    /// The empty canvas + directory / launcher / model pickers.
    ///
    /// ── Why the canvas is inside a min-height `ScrollView` ──
    ///
    /// zeron's onboarding canvas does not scroll, and it does not need to: it is
    /// a title, a subtitle and one button. supermux's carries a whole form —
    /// directory, three launcher chips, an optional executable-path field, the
    /// model picker, an error line and two buttons — and a harness panel can be
    /// a short horizontal split. Unscrolled, the Start button leaves the pane
    /// and the session cannot be started at all.
    ///
    /// The `GeometryReader` + `minHeight` pairing is what keeps BOTH behaviors:
    /// the canvas fills and centres exactly as it does standalone whenever the
    /// pane is tall enough, and only a pane too short for the form scrolls. A
    /// bare `ScrollView` would collapse the canvas to its content height and
    /// break the centring; a bare canvas clips.
    private var setupContent: some View {
        GeometryReader { proxy in
            ScrollView {
                setupForm.frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var setupForm: some View {
        SupermuxHarnessSetupView(
            workingDirectory: model.workingDirectory,
            launcher: model.launcher,
            availability: availability,
            models: model.availableModels,
            selectedModel: model.selectedModel,
            resumableSessionID: model.resumableSessionID,
            errorMessage: model.startupError,
            theme: theme,
            onPickDirectory: { model.setWorkingDirectory($0) },
            onSelectLauncher: { kind, path in
                model.selectLauncher(kind: kind, path: path)
            },
            onSelectModel: { model.setModelSelection($0) },
            onStart: { resume in
                Task { await model.start(resume: resume) }
            }
        )
        // Width only. `maxHeight: .infinity` under a scroll view resolves
        // against a nil height proposal, so it would contribute nothing here
        // while reading as if it set the height — the `minHeight` above is what
        // actually fills the viewport.
        .frame(maxWidth: .infinity)
        .task {
            // Preselect the first available launcher so the common case is one
            // click, not three.
            guard model.launcher == nil else { return }
            for kind in [ClaudeLauncher.Kind.claude, .ccx] where model.isLauncherAvailable(kind: kind) {
                model.selectLauncher(kind: kind)
                break
            }
        }
    }

    /// Availability probed once per setup render (a PATH stat, not a spawn).
    private var availability: [ClaudeLauncher.Kind: Bool] {
        [
            .claude: model.isLauncherAvailable(kind: .claude),
            .ccx: model.isLauncherAvailable(kind: .ccx),
            .custom: true,
        ]
    }

    // MARK: - Session

    /// Transcript full-bleed, composer floating over it. See the header.
    private var sessionContent: some View {
        ZStack(alignment: .bottom) {
            transcript
            SupermuxHarnessComposer(
                text: $model.draft,
                queue: model.queue,
                slashCommands: model.slashCommands,
                modelLabel: modelLabel ?? Self.defaultModelLabel,
                models: model.availableModels,
                selectedModel: model.selectedModel,
                effortLevels: model.supportedEffortLevels,
                effortLevel: model.effortLevel,
                supportsFastMode: model.supportsFastMode,
                fastMode: model.fastMode,
                maxThinkingTokens: model.maxThinkingTokens,
                isBusy: model.isBusy,
                canSend: canSend,
                theme: theme,
                onSend: { Task { await model.send() } },
                onInterrupt: { Task { await model.interrupt() } },
                onCancelQueued: { id in Task { await model.cancelQueued(id: id) } },
                onSelectModel: { value in Task { await model.setModel(value) } },
                onSelectEffort: { level in Task { await model.setEffort(level) } },
                onToggleFastMode: { enabled in Task { await model.setFastMode(enabled) } },
                onSetThinkingBudget: { tokens in
                    Task { await model.setMaxThinkingTokens(tokens) }
                },
                isSending: model.isSendingBridge,
                isRunFailed: model.isRunFailed,
                // The startup error is a failure OUTSIDE the transcript (a spawn
                // failure, a rejected control). It was a transcript row before;
                // zeron's home for it is the composer's notice chip, which is
                // dismissible and does not pollute the conversation.
                failure: model.startupError,
                footer: footerDirectory,
                footerBranch: footerBranch,
                // The one measurement both the last row's pad and the fade's
                // bottom band read.
                onMeasureClearance: { model.setBottomClearance($0) }
            )
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if model.rows.isEmpty {
            // A live session with no messages renders NOTHING — zeron's `.blank`
            // canvas is deliberately empty (the composer's own placeholder is
            // the affordance). The empty box still holds the region so the
            // composer's measurement and the glass ground are unchanged.
            SupermuxZeronEmptyCanvas(kind: .blank, theme: theme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SupermuxHarnessTranscript(
                rows: model.rows,
                sessionKey: model.sessionKey,
                theme: theme,
                bottomClearance: model.bottomClearance,
                runway: model.ownTurnAnchor?.runway ?? 0,
                // `isBusy` ALONE, deliberately — not `|| isSendingBridge`.
                //
                // zeron splits the two windows and shows exactly one indicator
                // in each. The trailer mounts on `indicator == Working` (spec 02
                // §2.6); the strip shows "Sending…" only when the indicator is
                // `None` AND the composer is sending (spec 04 §6.1). During the
                // bridge the indicator IS None, so OR-ing it here paints
                // "Sending…" twice — once under the last row and once in the
                // strip 30 pt below it.
                isWorking: model.isBusy,
                // Still threaded through: zeron's trailer has its own bridge
                // branch for a send that lands while a turn is already Working
                // and is fresher than that turn's start. supermux captures
                // `turnStartedAt` on the first non-idle transition, so the
                // timer is never stale and this branch does not currently
                // trigger — but the wiring costs nothing and keeps the two
                // sides of the bridge in one place.
                isSendingBridge: model.isSendingBridge,
                elapsedSeconds: model.elapsedSeconds,
                flavourSeed: model.flavourSeed
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Footer row

    /// The composer footer's leading item: the working directory's leaf.
    ///
    /// zeron's own left label is the literal `"Local checkout"` / `"Worktree"`,
    /// which is meaningful there because a zeron chat can run in a worktree of
    /// the space it belongs to. A supermux harness panel has exactly one
    /// directory and nothing to contrast it against, so the leaf name — the part
    /// that actually identifies the project — carries the same 12 pt slot with
    /// the same `folder` icon.
    ///
    /// `nil` only when both items are absent, which removes the whole row.
    private var footerDirectory: SupermuxZeronComposerFooter.Item? {
        guard model.isGitCheckout else { return nil }
        let leaf = (model.workingDirectory as NSString).lastPathComponent
        guard !leaf.isEmpty else { return nil }
        return SupermuxZeronComposerFooter.Item(icon: .folder, label: leaf)
    }

    /// The trailing item: the git ref, or `"No ref"` on a detached HEAD.
    ///
    /// The row is gated on the project HAVING GIT (`space.git_detected`), not on
    /// the branch resolving: zeron renders `"No ref"` rather than dropping the
    /// item, so a detached HEAD does not silently delete half the footer.
    /// Outside a repository both items are `nil` and the row is absent entirely.
    private var footerBranch: SupermuxZeronComposerFooter.Item? {
        guard model.isGitCheckout else { return nil }
        let label = model.gitBranch.flatMap { $0.isEmpty ? nil : $0 } ?? Self.noRefLabel
        return SupermuxZeronComposerFooter.Item(icon: .gitBranch, label: label)
    }

    private static var noRefLabel: String {
        String(localized: "supermux.harness.footer.noRef", defaultValue: "No ref")
    }

    // MARK: - Derived

    private var canSend: Bool {
        model.isRunning
            && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var modelLabel: String? {
        if let descriptor = model.activeModelDescriptor {
            return descriptor.displayName ?? descriptor.value
        }
        return model.selectedModel ?? model.initialization?.model
    }

    private static var defaultModelLabel: String {
        String(
            localized: "supermux.harness.model.default",
            defaultValue: "Claude Code default"
        )
    }
}
