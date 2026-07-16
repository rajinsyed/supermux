public import SupermuxMobileKit
public import SwiftUI

/// The workspace file browser — the phone counterpart of the desktop file
/// explorer panel, over `mobile.supermux.files.*`. Breadcrumb navigation,
/// pull-to-refresh, a New File / New Folder menu, per-row Rename / Duplicate
/// / Move to Trash (context menu + swipe), multi-select batch trash, and a
/// destructive trash confirm with plural-aware copy — mirroring the desktop
/// `SupermuxFileExplorerPrompt` semantics.
///
/// Owns one ``SupermuxMobileFileBrowserStore`` per presentation. The files
/// namespace has no event topic, so the screen is pull-only: load on appear,
/// refresh on pull, and the store refetches after every operation.
public struct SupermuxFileBrowserScreen: View {
    private let title: String
    private let makeStore: @MainActor () -> SupermuxMobileFileBrowserStore?

    /// The presentation-owned browser session; `nil` while disconnected.
    @State private var store: SupermuxMobileFileBrowserStore?
    /// The open name prompt (new file / new folder / rename), if any.
    @State private var prompt: SupermuxFileNamePrompt?
    /// The prompt's text-field draft.
    @State private var nameInput = ""
    /// The entries awaiting the destructive trash confirm.
    @State private var trashCandidates: [String] = []
    /// Whether the trash confirm dialog is presenting.
    @State private var showingTrashConfirm = false
    /// The most recent operation failure, presented as an alert.
    @State private var operationErrorMessage: String?
    /// Multi-select state for batch trash (iOS edit mode).
    @State private var selection = Set<String>()
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif
    @Environment(\.dismiss) private var dismiss

    /// Creates the file-browser screen.
    /// - Parameters:
    ///   - title: The navigation title (the workspace's display name).
    ///   - makeStore: Builds the browser store against the live session, or
    ///     `nil` when disconnected (a not-connected placeholder shows).
    public init(
        title: String,
        makeStore: @escaping @MainActor () -> SupermuxMobileFileBrowserStore?
    ) {
        self.title = title
        self.makeStore = makeStore
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .accessibilityIdentifier("SupermuxFileBrowserScreen")
                .toolbar { toolbarContent }
                #if os(iOS)
                .environment(\.editMode, $editMode)
                #endif
        }
        .task {
            let store = self.store ?? makeStore()
            self.store = store
            await store?.load()
        }
        .alert(
            promptTitle,
            isPresented: Binding(
                get: { prompt != nil },
                set: { if !$0 { prompt = nil } }
            )
        ) {
            TextField(
                String(
                    localized: "supermux.files.prompt.name.placeholder",
                    defaultValue: "Name",
                    bundle: .module
                ),
                text: $nameInput
            )
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            Button(role: .cancel) {
                prompt = nil
            } label: {
                Text(String(localized: "supermux.common.cancel", defaultValue: "Cancel", bundle: .module))
            }
            Button(action: submitPrompt) {
                Text(promptConfirmTitle)
            }
        } message: {
            Text(promptMessage)
        }
        .confirmationDialog(
            trashConfirmTitle,
            isPresented: $showingTrashConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive, action: confirmTrash) {
                Text(String(
                    localized: "supermux.files.menu.moveToTrash",
                    defaultValue: "Move to Trash",
                    bundle: .module
                ))
            }
        } message: {
            Text(trashConfirmMessage)
        }
        .alert(
            String(
                localized: "supermux.files.error.title",
                defaultValue: "Couldn’t Complete the Operation",
                bundle: .module
            ),
            isPresented: Binding(
                get: { operationErrorMessage != nil },
                set: { if !$0 { operationErrorMessage = nil } }
            )
        ) {
            Button {
                operationErrorMessage = nil
            } label: {
                Text(String(localized: "supermux.common.ok", defaultValue: "OK", bundle: .module))
            }
        } message: {
            Text(operationErrorMessage ?? "")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let store {
            if store.hasLoaded {
                loadedBody(store)
            } else if let errorDescription = store.lastErrorDescription {
                // The first `files.list` failed: there's no event topic to
                // refetch and `.refreshable`/`.task` are both unreachable
                // from this state, so without an explicit retry this would
                // be stuck on the loading spinner forever.
                loadErrorPlaceholder(errorDescription) {
                    Task { await store.load() }
                }
            } else if store.showsFileBrowser {
                loadingPlaceholder
            } else {
                placeholder(String(
                    localized: "supermux.files.notConnected",
                    defaultValue: "Not connected to a Mac.",
                    bundle: .module
                ))
            }
        } else {
            placeholder(String(
                localized: "supermux.files.notConnected",
                defaultValue: "Not connected to a Mac.",
                bundle: .module
            ))
        }
    }

    private var loadingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(String(
                localized: "supermux.files.loading",
                defaultValue: "Loading files…",
                bundle: .module
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadErrorPlaceholder(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: retry) {
                Text(String(localized: "supermux.common.retry", defaultValue: "Retry", bundle: .module))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("SupermuxFileBrowserRetryButton")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadedBody(_ store: SupermuxMobileFileBrowserStore) -> some View {
        VStack(spacing: 0) {
            SupermuxFileBreadcrumbBar(
                segments: store.pathSegments,
                navigateToDepth: { depth in
                    let store = store
                    Task { await store.navigate(toDepth: depth) }
                }
            )
            Divider()
            listBody(store)
        }
    }

    private func listBody(_ store: SupermuxMobileFileBrowserStore) -> some View {
        let rows = SupermuxFileRowSnapshot.rows(from: store.entries)
        let actions = SupermuxFileRowActions(
            open: { name in
                let store = store
                Task { await store.navigate(into: name) }
            },
            requestRename: { name in
                nameInput = name
                prompt = .rename(name)
            },
            duplicate: { name in
                perform { try await store.duplicate(entryNamed: name) }
            },
            requestTrash: { name in
                trashCandidates = [name]
                showingTrashConfirm = true
            }
        )
        return List(selection: $selection) {
            if let errorDescription = store.lastErrorDescription {
                Section {
                    Text(errorDescription)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            if rows.isEmpty {
                Section {
                    Text(String(
                        localized: "supermux.files.empty",
                        defaultValue: "Empty folder",
                        bundle: .module
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            ForEach(rows) { row in
                SupermuxFileEntryRow(row: row, actions: actions)
                    .tag(row.name)
            }
        }
        .refreshable { await store.refresh() }
        .accessibilityIdentifier("SupermuxFileBrowserList")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button {
                dismiss()
            } label: {
                Text(String(localized: "supermux.common.done", defaultValue: "Done", bundle: .module))
            }
            .accessibilityIdentifier("SupermuxFileBrowserDoneButton")
        }
        if let store, store.hasLoaded {
            ToolbarItem(placement: addMenuPlacement) {
                Menu {
                    Button {
                        nameInput = ""
                        prompt = .newFile
                    } label: {
                        Label {
                            Text(String(
                                localized: "supermux.files.menu.newFile",
                                defaultValue: "New File…",
                                bundle: .module
                            ))
                        } icon: {
                            Image(systemName: "doc.badge.plus")
                        }
                    }
                    Button {
                        nameInput = ""
                        prompt = .newFolder
                    } label: {
                        Label {
                            Text(String(
                                localized: "supermux.files.menu.newFolder",
                                defaultValue: "New Folder…",
                                bundle: .module
                            ))
                        } icon: {
                            Image(systemName: "folder.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(store.isMutating)
                .accessibilityLabel(String(
                    localized: "supermux.files.menu.add",
                    defaultValue: "Add",
                    bundle: .module
                ))
                .accessibilityIdentifier("SupermuxFileBrowserAddMenu")
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
            if editMode.isEditing, !selection.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        trashCandidates = Array(selection)
                        showingTrashConfirm = true
                    } label: {
                        Label {
                            Text(String(
                                localized: "supermux.files.menu.moveToTrash",
                                defaultValue: "Move to Trash",
                                bundle: .module
                            ))
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .disabled(store.isMutating)
                    .accessibilityIdentifier("SupermuxFileBrowserTrashSelectionButton")
                }
            }
            #endif
        }
    }

    private var addMenuPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }

    // MARK: - Prompt handling

    private var promptTitle: String {
        switch prompt {
        case .newFile:
            String(localized: "supermux.files.prompt.newFile.title", defaultValue: "New File", bundle: .module)
        case .newFolder:
            String(localized: "supermux.files.prompt.newFolder.title", defaultValue: "New Folder", bundle: .module)
        case .rename:
            String(localized: "supermux.files.prompt.rename.title", defaultValue: "Rename", bundle: .module)
        case nil:
            ""
        }
    }

    private var promptMessage: String {
        switch prompt {
        case .newFile:
            String(
                localized: "supermux.files.prompt.newFile.message",
                defaultValue: "Enter a name for the new file.",
                bundle: .module
            )
        case .newFolder:
            String(
                localized: "supermux.files.prompt.newFolder.message",
                defaultValue: "Enter a name for the new folder.",
                bundle: .module
            )
        case let .rename(currentName):
            String(
                localized: "supermux.files.prompt.rename.message",
                defaultValue: "Enter a new name for “\(currentName)”.",
                bundle: .module
            )
        case nil:
            ""
        }
    }

    private var promptConfirmTitle: String {
        switch prompt {
        case .rename:
            String(localized: "supermux.files.prompt.rename.action", defaultValue: "Rename", bundle: .module)
        default:
            String(localized: "supermux.files.prompt.create", defaultValue: "Create", bundle: .module)
        }
    }

    private func submitPrompt() {
        guard let prompt, let store else { return }
        self.prompt = nil
        let name = nameInput
        if let issue = SupermuxFileName.issue(with: name) {
            operationErrorMessage = SupermuxFileOpErrorText.message(forIssue: issue, name: name)
            return
        }
        perform {
            switch prompt {
            case .newFile:
                try await store.createFile(named: name)
            case .newFolder:
                try await store.createFolder(named: name)
            case let .rename(currentName):
                try await store.rename(entryNamed: currentName, to: name)
            }
        }
    }

    // MARK: - Trash handling

    private var trashConfirmTitle: String {
        if trashCandidates.count == 1, let name = trashCandidates.first {
            String(
                localized: "supermux.files.trash.confirmTitleSingle",
                defaultValue: "Move “\(name)” to the Trash?",
                bundle: .module
            )
        } else {
            String(
                localized: "supermux.files.trash.confirmTitleMultiple",
                defaultValue: "Move \(trashCandidates.count) items to the Trash?",
                bundle: .module
            )
        }
    }

    private var trashConfirmMessage: String {
        if trashCandidates.count == 1 {
            String(
                localized: "supermux.files.trash.confirmMessageSingle",
                defaultValue: "You can restore it later from the Trash on your Mac.",
                bundle: .module
            )
        } else {
            String(
                localized: "supermux.files.trash.confirmMessageMultiple",
                defaultValue: "You can restore them later from the Trash on your Mac.",
                bundle: .module
            )
        }
    }

    private func confirmTrash() {
        guard let store, !trashCandidates.isEmpty else { return }
        let names = trashCandidates
        trashCandidates = []
        selection = Set()
        perform { try await store.trash(entryNames: names) }
    }

    // MARK: - Shared op runner

    /// Runs one store operation, routing failures to the error alert (never
    /// a silent failure).
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                operationErrorMessage = SupermuxFileOpErrorText.message(for: error)
            }
        }
    }
}

// `SupermuxFileNamePrompt` and `SupermuxFileOpErrorText` live in
// `SupermuxFileBrowserPrompts.swift`.
