public import SwiftUI
import CmuxFoundation
import SupermuxClaudeHarness

/// The whole native Claude Code panel: header, transcript, composer.
///
/// The model is passed in (owned by the fork's panel registry), never created
/// here: the panel view unmounts whenever the tab is hidden, and a view-owned
/// model would take the running process with it.
public struct SupermuxHarnessView: View {
    @Bindable private var model: SupermuxHarnessViewModel
    private let theme: SupermuxHarnessTheme
    private let stableSurfaceID: UUID?

    @State private var markdownCache = SupermuxHarnessMarkdownCache()

    /// Creates the harness panel view.
    /// - Parameters:
    ///   - model: The registry-owned session model for this panel.
    ///   - theme: Colours resolved from the panel's appearance.
    ///   - stableSurfaceID: The panel's persisted identity, read lazily by the
    ///     mount (upstream adopts it after the panel is constructed).
    public init(
        model: SupermuxHarnessViewModel,
        theme: SupermuxHarnessTheme,
        stableSurfaceID: UUID?
    ) {
        self.model = model
        self.theme = theme
        self.stableSurfaceID = stableSurfaceID
    }

    public var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .setup:
                setupContent
            case .session:
                sessionContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.pageBackground)
        .environment(\.supermuxHarnessMarkdownCache, markdownCache)
        .task(id: stableSurfaceID) {
            guard let stableSurfaceID else { return }
            await model.adopt(stableSurfaceID: stableSurfaceID)
        }
    }

    // MARK: - Setup

    private var setupContent: some View {
        ScrollView {
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
        }
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

    private var sessionContent: some View {
        VStack(spacing: 0) {
            SupermuxHarnessHeaderBar(
                workingDirectory: model.workingDirectory,
                modelLabel: modelLabel,
                stateLabel: SupermuxHarnessStatePresentation.label(
                    process: model.processPhase, turn: model.turnPhase
                ),
                stateColor: SupermuxHarnessStatePresentation.color(
                    process: model.processPhase, turn: model.turnPhase, theme: theme
                ),
                totalCostUSD: model.latestResult?.totalCostUSD,
                isBusy: model.isBusy,
                theme: theme,
                onInterrupt: { Task { await model.interrupt() } }
            )

            if model.rows.isEmpty {
                emptyTranscript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SupermuxHarnessTranscript(
                    rows: model.rows,
                    sessionKey: model.resumableSessionID ?? model.panelID.uuidString,
                    theme: theme
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let startupError = model.startupError {
                SupermuxHarnessNoticeRow(
                    notice: SupermuxHarnessNotice(severity: .error, title: startupError),
                    theme: theme
                )
                .padding(.horizontal, SupermuxHarnessTokens.spacing12)
            }

            SupermuxHarnessComposer(
                text: $model.draft,
                queue: model.queue,
                slashCommands: model.slashCommands,
                modelLabel: modelLabel ?? String(
                    localized: "supermux.harness.model.default",
                    defaultValue: "Claude Code default"
                ),
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
                }
            )
        }
    }

    /// A fresh session before the first prompt: restate where the session
    /// lives and how to send, instead of showing a blank slab.
    private var emptyTranscript: some View {
        VStack(spacing: SupermuxHarnessTokens.spacing8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.mutedText.opacity(0.7))
            Text(
                String(
                    localized: "supermux.harness.empty.title",
                    defaultValue: "Claude Code is ready"
                )
            )
            .cmuxFont(size: SupermuxHarnessTokens.headline, weight: .medium)
            .foregroundStyle(theme.softText)
            Text(model.workingDirectory)
                .cmuxFont(size: SupermuxHarnessTokens.caption, design: .monospaced)
                .foregroundStyle(theme.mutedText)
                .lineLimit(1)
                .truncationMode(.head)
            Text(
                String(
                    localized: "supermux.harness.empty.hint",
                    defaultValue: "Type a message and press Return to send. Shift-Return inserts a newline."
                )
            )
            .cmuxFont(size: SupermuxHarnessTokens.caption)
            .foregroundStyle(theme.mutedText)
        }
        .padding(SupermuxHarnessTokens.spacing12)
    }

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
}
