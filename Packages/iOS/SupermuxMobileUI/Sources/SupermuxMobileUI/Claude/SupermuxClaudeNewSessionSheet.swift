public import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// The new-session sheet: pick a working directory, a launcher, a model and
/// effort, optionally write a first prompt, and start.
///
/// The Mac's `claude.options` is the single source of truth for what can be
/// chosen — model catalog, effort levels, and launcher availability are all
/// live PATH/CLI facts, so the sheet fetches them on appear rather than
/// offering a hard-coded list the Mac would then reject.
public struct SupermuxClaudeNewSessionSheet: View {
    private let store: SupermuxClaudeSessionsStore
    private let quickPicks: [SupermuxClaudeDirectoryQuickPick]
    private let onCreated: @MainActor (SupermuxClaudeSessionDTO) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var cwd = ""
    @State private var launcher: SupermuxClaudeLauncher = .claude
    @State private var customLauncherPath = ""
    @State private var model: String?
    @State private var effort: String?
    @State private var fastMode = false
    @State private var initialPrompt = ""
    @State private var options: SupermuxClaudeOptionsDTO?
    @State private var isLoadingOptions = false
    @State private var isCreating = false
    @State private var failureMessage: String?
    @State private var isPresentingRuntimePicker = false

    /// Creates the sheet.
    /// - Parameters:
    ///   - store: The live sessions session (owns the create call).
    ///   - quickPicks: Known project/worktree directories offered as one-tap
    ///     choices, so the common case needs no typing.
    ///   - onCreated: Receives the created session.
    public init(
        store: SupermuxClaudeSessionsStore,
        quickPicks: [SupermuxClaudeDirectoryQuickPick] = [],
        onCreated: @escaping @MainActor (SupermuxClaudeSessionDTO) -> Void
    ) {
        self.store = store
        self.quickPicks = quickPicks
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            Form {
                directorySection
                launcherSection
                runtimeSection
                promptSection
                if let failureMessage {
                    Section {
                        Label {
                            Text(failureMessage)
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(String(
                localized: "supermux.claude.newSession",
                defaultValue: "New Session",
                bundle: .module
            ))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(String(
                            localized: "supermux.common.cancel",
                            defaultValue: "Cancel",
                            bundle: .module
                        ))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        Text(String(
                            localized: "supermux.claude.start",
                            defaultValue: "Start",
                            bundle: .module
                        ))
                    }
                    .disabled(!canStart)
                }
            }
            .task { await loadOptions() }
        }
        .accessibilityIdentifier("SupermuxClaudeNewSessionSheet")
    }

    /// Whether Start is enabled: an absolute directory, a resolvable
    /// launcher, and nothing already on the wire.
    private var canStart: Bool {
        SupermuxClaudeNewSessionValidation.canStart(
            cwd: cwd,
            launcher: resolvedLauncher,
            isCreating: isCreating
        )
    }

    /// The launcher as configured, resolving the custom row's typed path.
    private var resolvedLauncher: SupermuxClaudeLauncher {
        if case .custom = launcher {
            return .custom(path: customLauncherPath)
        }
        return launcher
    }

    // MARK: Sections

    private var directorySection: some View {
        Section {
            TextField(
                String(
                    localized: "supermux.claude.cwd.placeholder",
                    defaultValue: "/Users/you/project",
                    bundle: .module
                ),
                text: $cwd
            )
            .font(SupermuxClaudeStyle.mono())
            .textContentType(.none)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            ForEach(quickPicks) { pick in
                Button {
                    cwd = pick.path
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: pick.systemImage)
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pick.name)
                                .font(SupermuxClaudeStyle.body(weight: .medium))
                            Text(pick.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                        if cwd == pick.path {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(String(
                localized: "supermux.claude.cwd.title",
                defaultValue: "Working Directory",
                bundle: .module
            ))
        }
    }

    private var launcherSection: some View {
        Section {
            ForEach(launcherRows, id: \.id) { row in
                Button {
                    launcher = row.launcher
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(SupermuxClaudeStyle.body())
                                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                            if let detail = row.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if isSelected(row.launcher) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!row.isAvailable)
            }
            if case .custom = launcher {
                TextField(
                    String(
                        localized: "supermux.claude.launcher.customPath",
                        defaultValue: "/absolute/path/to/launcher",
                        bundle: .module
                    ),
                    text: $customLauncherPath
                )
                .font(SupermuxClaudeStyle.mono())
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            }
        } header: {
            Text(String(
                localized: "supermux.claude.launcher.title",
                defaultValue: "Launcher",
                bundle: .module
            ))
        } footer: {
            Text(String(
                localized: "supermux.claude.launcher.footer",
                defaultValue: "The session keeps this launcher for its whole life, including resume.",
                bundle: .module
            ))
        }
    }

    private var runtimeSection: some View {
        Section {
            Button {
                isPresentingRuntimePicker = true
            } label: {
                HStack(spacing: 8) {
                    Text(String(
                        localized: "supermux.claude.model",
                        defaultValue: "Model",
                        bundle: .module
                    ))
                    Spacer(minLength: 0)
                    Text(SupermuxClaudeRuntimeLabels.modelTitle(model, options: options))
                        .foregroundStyle(.secondary)
                    if let effort {
                        Text(effort)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoadingOptions && options == nil)
        } header: {
            Text(String(
                localized: "supermux.claude.runtime.title",
                defaultValue: "Runtime",
                bundle: .module
            ))
        }
        .supermuxClaudeRuntimePicker(
            isPresented: $isPresentingRuntimePicker,
            options: options,
            isLoading: isLoadingOptions,
            model: $model,
            effort: $effort,
            fastMode: $fastMode
        )
    }

    private var promptSection: some View {
        Section {
            TextField(
                String(
                    localized: "supermux.claude.prompt.placeholder",
                    defaultValue: "What should Claude do?",
                    bundle: .module
                ),
                text: $initialPrompt,
                axis: .vertical
            )
            .lineLimit(3 ... 8)
            .font(SupermuxClaudeStyle.body())
        } header: {
            Text(String(
                localized: "supermux.claude.prompt.title",
                defaultValue: "First Prompt",
                bundle: .module
            ))
        }
    }

    // MARK: Launcher rows

    private struct LauncherRow {
        let id: String
        let launcher: SupermuxClaudeLauncher
        let title: String
        let detail: String?
        let isAvailable: Bool
    }

    /// The launcher choices, driven by the Mac's availability probe.
    ///
    /// Before options land the built-in launchers show as available: the
    /// alternative is a sheet whose every row is disabled for a beat, and
    /// the Mac re-validates on create regardless.
    private var launcherRows: [LauncherRow] {
        let advertised = options?.launchers ?? []
        func availability(_ launcher: SupermuxClaudeLauncher) -> SupermuxClaudeLauncherAvailabilityDTO? {
            advertised.first { $0.launcher == launcher }
        }
        let claudeInfo = availability(.claude)
        let ccxInfo = availability(.ccx)
        return [
            LauncherRow(
                id: "claude",
                launcher: .claude,
                title: claudeInfo?.displayName ?? "claude",
                detail: claudeInfo?.unavailableReason,
                isAvailable: claudeInfo?.available ?? true
            ),
            LauncherRow(
                id: "ccx",
                launcher: .ccx,
                title: ccxInfo?.displayName ?? "ccx",
                detail: ccxInfo?.unavailableReason,
                isAvailable: ccxInfo?.available ?? advertised.isEmpty
            ),
            LauncherRow(
                id: "custom",
                launcher: .custom(path: ""),
                title: String(
                    localized: "supermux.claude.launcher.custom",
                    defaultValue: "Custom path",
                    bundle: .module
                ),
                detail: nil,
                isAvailable: true
            ),
        ]
    }

    private func isSelected(_ candidate: SupermuxClaudeLauncher) -> Bool {
        switch (launcher, candidate) {
        case (.claude, .claude), (.ccx, .ccx): true
        case (.custom, .custom): true
        default: false
        }
    }

    // MARK: Actions

    private func loadOptions() async {
        isLoadingOptions = true
        defer { isLoadingOptions = false }
        guard let loaded = try? await store.options() else { return }
        options = loaded
        if model == nil { model = loaded.models.first?.value }
        if effort == nil {
            effort = SupermuxClaudeRuntimeLabels.effortLevels(for: model, options: loaded).last
        }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        failureMessage = nil
        let prompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await store.createSession(SupermuxClaudeSessionCreateRequestDTO(
                cwd: cwd.trimmingCharacters(in: .whitespaces),
                launcher: resolvedLauncher,
                model: model,
                effort: effort,
                fastMode: fastMode,
                initialPrompt: prompt.isEmpty ? nil : prompt
            ))
            // A session that failed to START is still a session: it is listed
            // with its diagnostic, and the sheet says so instead of pretending
            // the create failed outright.
            if result.session.state == .failed {
                failureMessage = result.stderrExcerpt ?? String(
                    localized: "supermux.claude.start.failed",
                    defaultValue: "Claude could not start on your Mac.",
                    bundle: .module
                )
                return
            }
            onCreated(result.session)
            dismiss()
        } catch {
            failureMessage = String(
                localized: "supermux.claude.start.failed",
                defaultValue: "Claude could not start on your Mac.",
                bundle: .module
            )
        }
    }
}

/// A one-tap working-directory choice (a project root or a worktree).
public struct SupermuxClaudeDirectoryQuickPick: Identifiable, Equatable, Sendable {
    /// The absolute Mac path (also its identity).
    public let path: String
    /// The row's display name.
    public let name: String
    /// The row's SF Symbol.
    public let systemImage: String

    /// The stable identifier used by the list.
    public var id: String { path }

    /// Creates a quick pick.
    /// - Parameters:
    ///   - path: The absolute Mac path.
    ///   - name: The row's display name.
    ///   - systemImage: The row's SF Symbol.
    public init(path: String, name: String, systemImage: String = "folder") {
        self.path = path
        self.name = name
        self.systemImage = systemImage
    }
}

/// Start-button validation, kept off the view so it is unit-testable.
///
/// lint:allow namespace-enum — a stateless predicate.
public enum SupermuxClaudeNewSessionValidation {
    /// Whether the sheet may start a session.
    ///
    /// The directory must be ABSOLUTE: the Mac resolves it verbatim, and a
    /// relative path would silently land wherever the host process happens to
    /// be. A custom launcher likewise needs an absolute path, since "never
    /// silently fall back to plain claude" means there is no second guess.
    ///
    /// - Parameters:
    ///   - cwd: The typed working directory.
    ///   - launcher: The configured launcher.
    ///   - isCreating: Whether a create is already on the wire.
    public static func canStart(
        cwd: String,
        launcher: SupermuxClaudeLauncher,
        isCreating: Bool
    ) -> Bool {
        guard !isCreating else { return false }
        guard cwd.trimmingCharacters(in: .whitespaces).hasPrefix("/") else { return false }
        if case .custom(let path) = launcher {
            return path.trimmingCharacters(in: .whitespaces).hasPrefix("/")
        }
        return true
    }
}
