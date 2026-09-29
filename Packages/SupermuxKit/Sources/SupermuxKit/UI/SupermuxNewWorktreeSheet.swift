public import SwiftUI
public import AppKit
import Foundation
import SupermuxMobileCore

/// Modal sheet for creating a git worktree in a project — optionally with
/// Claude already running in it — on this Mac or another Mac that has the
/// project.
///
/// One sheet, two outcomes, chosen by whether the prompt is filled in:
///
/// - **Prompt empty** — the classic flow: a workspace name, an optional
///   branch (AI-named from the workspace name when a gateway key is set,
///   friendly-random otherwise), a starting branch. "Create" opens a clean
///   terminal.
/// - **Prompt filled** — the prompt is the primary input: workspace name and
///   branch default to names derived from it (typed values still win), the
///   Claude chips (command / model / effort) appear, and "Start Claude" opens
///   the workspace with its terminal already running the command with the
///   prompt as the first message. On this Mac that path goes through
///   ``SupermuxAgentWorktreeLauncher`` — the same path the phone uses.
///
/// When the project lives on several Macs (or other Macs could set it up), a
/// device picker at the top chooses where; another Mac creates the worktree
/// itself and its workspace opens here as a mirror. All state and flow live in
/// ``SupermuxNewWorktreeSheetModel``; this view only renders it.
///
/// Presented via `.sheet(item:)` from ``SupermuxProjectsSectionView``.
public struct SupermuxNewWorktreeSheet: View {
    @State var sheet: SupermuxNewWorktreeSheetModel
    /// The project record behind the header avatar (name, color, symbol).
    private let avatar: SupermuxProject
    /// The project's resolved avatar image (custom icon or detected logo),
    /// shared with the sidebar row so the header shows the same icon.
    private let projectIcon: NSImage?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State var showsCommandEditor = false

    private enum Field { case prompt, workspace, branch }

    /// Creates the device-aware sheet.
    /// - Parameters:
    ///   - model: The sheet model (targets, device picker, flow).
    ///   - avatar: The project record the header avatar renders.
    ///   - projectIcon: The project's resolved avatar image, if cached.
    public init(model: SupermuxNewWorktreeSheetModel, avatar: SupermuxProject, projectIcon: NSImage? = nil) {
        _sheet = State(initialValue: model)
        self.avatar = avatar
        self.projectIcon = projectIcon
    }

    /// Creates the sheet for this Mac only (no device picker).
    /// - Parameters:
    ///   - model: Shared projects model that performs the git work.
    ///   - project: Project the worktree is created in.
    ///   - projectIcon: The project's resolved avatar image, when the host has
    ///     one cached; `nil` falls back to the symbol or initial letter.
    ///   - agentLaunch: Claude launch collaborators; `nil` hides the prompt
    ///     path entirely (plain worktree sheet).
    ///   - onCreated: Called after a plain create with the new worktree and
    ///     the chosen workspace name (`nil` when left blank).
    ///   - onLaunched: Called after a Claude launch with the launch result;
    ///     the host opens `launch.openRequest`.
    public init(
        model: SupermuxProjectsModel,
        project: SupermuxProject,
        projectIcon: NSImage? = nil,
        agentLaunch: SupermuxAgentLaunchEnvironment? = nil,
        onCreated: @escaping (SupermuxProjectWorktree, String?) -> Void,
        onLaunched: @escaping (SupermuxAgentWorktreeLaunch) -> Void = { _ in }
    ) {
        let target = SupermuxLocalWorktreeCreationTarget(
            model: model,
            project: project,
            agentLaunch: agentLaunch,
            onCreated: onCreated,
            onLaunched: onLaunched
        )
        let location = SupermuxProjectLocation(place: .thisMac, projectID: project.id, rootPath: project.rootPath)
        let entry = SupermuxWorktreeDeviceEntry(
            deviceKey: SupermuxWorktreeDeviceEntry.thisMacKey,
            name: String(localized: "supermux.devices.thisMac", defaultValue: "This Mac"),
            availability: .online,
            action: .create(location)
        )
        self.init(
            model: SupermuxNewWorktreeSheetModel(
                projectID: project.id,
                entries: [entry],
                initialEntryID: entry.id,
                makeTarget: { _ in target }
            ),
            avatar: project,
            projectIcon: projectIcon
        )
    }

    /// The sheet content.
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if sheet.showsDevicePicker {
                SupermuxNewWorktreeDevicePicker(sheet: sheet)
            }
            if sheet.showsPromptEditor {
                promptEditor
            }
            nameFields
            if sheet.hasPrompt, let line = sheet.previewLine {
                commandPreview(line)
            }
            chipRow
            if let statusMessage = sheet.statusMessage {
                HStack(spacing: 6) {
                    if sheet.remoteDeviceName != nil, sheet.phase == .runningGit {
                        ProgressView().controlSize(.mini)
                    }
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if let message = sheet.errorMessage ?? sheet.branchLoadError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if sheet.branchLoadError != nil, sheet.errorMessage == nil {
                        Spacer(minLength: 0)
                        Button(String(localized: "common.retry", defaultValue: "Retry")) {
                            Task { await sheet.loadBranches() }
                        }
                        .controlSize(.small)
                    }
                }
            }
            buttons
        }
        .padding(16)
        .frame(width: sheet.showsPromptEditor || sheet.showsDevicePicker ? 460 : 380)
        .animation(.snappy(duration: 0.18), value: sheet.hasPrompt)
        .onAppear {
            focusedField = sheet.showsPromptEditor ? .prompt : .workspace
        }
        // Loads the selected Mac's branches and Claude options, again after
        // every device switch and when that Mac (re)connects.
        .task(id: sheet.loadKey) { await sheet.load() }
        .onChange(of: sheet.configuredDefaultBranch) { _, _ in
            sheet.configuredDefaultBranchChanged()
        }
        .onChange(of: sheet.selectedModel) { _, _ in sheet.clampEffort() }
        // If the sheet goes away while the (possibly slow) AI-naming phase is
        // in flight, abort it so no worktree is created behind the user's
        // back. Cancel is disabled once git runs, so this only covers
        // programmatic dismissal — and once git has run, the created worktree
        // is still delivered by the target.
        .onDisappear { sheet.cancel() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            SupermuxProjectAvatarView(project: avatar, detectedIcon: projectIcon, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "supermux.newWorktree.title", defaultValue: "New Worktree"))
                    .font(.headline)
                Text(avatar.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var promptEditor: some View {
        ZStack(alignment: .topLeading) {
            if sheet.prompt.isEmpty {
                Text(String(
                    localized: "supermux.newWorktree.prompt.placeholder",
                    defaultValue: "What should Claude work on? Leave empty for a plain worktree."
                ))
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .allowsHitTesting(false)
            }
            TextEditor(text: $sheet.prompt)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .focused($focusedField, equals: .prompt)
                .disabled(sheet.phase != .idle)
        }
        .frame(minHeight: 76, maxHeight: 160)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    focusedField == .prompt ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12),
                    lineWidth: 1
                )
        )
    }

    /// Workspace name and branch side by side, equal width and in one font
    /// (so they line up and the branch placeholder fits). With a prompt,
    /// their placeholders show the names that will be derived, so leaving
    /// them blank is the normal case and typing overrides.
    private var nameFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField(workspacePlaceholder, text: $sheet.workspaceName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .workspace)
                    .onSubmit(create)
                    .disabled(sheet.phase != .idle)
                    .frame(maxWidth: .infinity)
                TextField(branchPlaceholder, text: $sheet.branchInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .branch)
                    .onSubmit(create)
                    .disabled(sheet.phase != .idle)
                    .frame(maxWidth: .infinity)
            }
            Text(nameHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The exact shell line the new terminal will run, so what the chips
    /// mean is never a guess (hidden when it is not known here).
    private func commandPreview(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(String(localized: "supermux.common.cancel", defaultValue: "Cancel")) {
                sheet.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            // Cancelling can abort the AI-naming phase, but not a git process
            // (or another Mac) already creating the worktree.
            .disabled(sheet.phase == .runningGit)
            Button(action: create) {
                HStack(spacing: 5) {
                    if sheet.phase != .idle {
                        ProgressView().controlSize(.small)
                    } else if sheet.hasPrompt {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                    }
                    Text(sheet.hasPrompt
                        ? String(localized: "supermux.newWorktree.startClaude", defaultValue: "Start Claude")
                        : String(localized: "supermux.newWorktree.create", defaultValue: "Create"))
                    if sheet.hasPrompt {
                        Text("⌘↩").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .keyboardShortcut(sheet.hasPrompt ? .init(.return, modifiers: .command) : .defaultAction)
            .disabled(!sheet.canCreate)
        }
    }

    // MARK: - Text

    /// Offline preview of the names the prompt would produce (AI refines at
    /// submit when configured).
    private var derivedNames: SupermuxPromptNames? {
        sheet.hasPrompt ? SupermuxPromptNaming.names(from: sheet.prompt) : nil
    }

    private var workspacePlaceholder: String {
        derivedNames?.workspaceName
            ?? String(localized: "supermux.newWorktree.workspace.placeholder", defaultValue: "Workspace name")
    }

    private var branchPlaceholder: String {
        derivedNames?.branchName
            ?? String(localized: "supermux.newWorktree.branch.placeholder.optional", defaultValue: "Branch name (optional)")
    }

    /// Subtitle under the fields: what the names will be, or a sanitized
    /// preview when the typed branch differs from what git will use.
    private var nameHint: String {
        let typedBranch = sheet.branchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sanitized = SupermuxBranchName().sanitize(sheet.branchInput), sanitized != typedBranch {
            return String(
                localized: "supermux.newWorktree.branch.preview",
                defaultValue: "Will be created as “\(sanitized)”"
            )
        }
        if sheet.hasPrompt {
            return sheet.aiNamingConfigured
                ? String(
                    localized: "supermux.newWorktree.prompt.aiHint",
                    defaultValue: "Blank fields are named from the prompt by AI; typed values are kept."
                )
                : String(
                    localized: "supermux.newWorktree.prompt.hint",
                    defaultValue: "Blank fields are named from the prompt; typed values are kept."
                )
        }
        if !typedBranch.isEmpty { return "" }
        if sheet.aiNamingConfigured, !sheet.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(
                localized: "supermux.newWorktree.branch.aiHint",
                defaultValue: "AI will suggest a branch name from the workspace name; a random name is used if that fails."
            )
        }
        return String(
            localized: "supermux.newWorktree.branch.randomHint",
            defaultValue: "Leave blank for a random name like “cheerful-umbrella”"
        )
    }

    // MARK: - Actions

    private func create() {
        sheet.submit { dismiss() }
    }

    // Kept for the package tests that pin the base-branch rules.
    static func initialBaseBranch(configuredDefault: String?, branches: [String]) -> String {
        SupermuxNewWorktreeSheetModel.initialBaseBranch(configuredDefault: configuredDefault, branches: branches)
    }

    static func requestedBaseBranch(selection: String, wasEdited: Bool) -> String? {
        SupermuxNewWorktreeSheetModel.requestedBaseBranch(selection: selection, wasEdited: wasEdited)
    }
}
