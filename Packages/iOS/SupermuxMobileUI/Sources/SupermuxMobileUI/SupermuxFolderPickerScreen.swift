public import SupermuxMobileKit
public import SwiftUI

/// One browsable root the folder picker offers: a project registered on the
/// Mac (`project_id`-rooted `files.*` browsing).
public struct SupermuxFolderPickerRootOption: Equatable, Sendable, Identifiable {
    /// The project's UUID string (the picker browses `.project(id:)`).
    public var id: String { projectID }
    /// The project's UUID string.
    public let projectID: String
    /// The project's display name.
    public let name: String
    /// The project root's absolute path on the Mac.
    public let rootPath: String

    /// Creates one root option.
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - name: The project's display name.
    ///   - rootPath: The project root's absolute Mac path.
    public init(projectID: String, name: String, rootPath: String) {
        self.projectID = projectID
        self.name = name
        self.rootPath = rootPath
    }
}

/// The project editor's Mac folder-picker seam: which roots can be browsed
/// (the registered projects — the `files.*` wire confines browsing to a
/// `workspace_id`/`project_id` root, so arbitrary Mac paths still go through
/// the editor's text field) and a browser-store factory bound to the live
/// session. `nil` root options or a `nil` store mean the session went away.
public struct SupermuxProjectRootPathPicking {
    /// The browsable roots, freshest first-party projects at call time.
    public let rootOptions: @MainActor () -> [SupermuxFolderPickerRootOption]
    /// Builds a `project_id`-rooted browser store against the live session,
    /// or `nil` while disconnected.
    public let makeBrowserStore: @MainActor (_ projectID: String) -> SupermuxMobileFileBrowserStore?

    /// Memberwise initializer.
    /// - Parameters:
    ///   - rootOptions: The browsable roots at call time.
    ///   - makeBrowserStore: Builds a browser store for one project root.
    public init(
        rootOptions: @escaping @MainActor () -> [SupermuxFolderPickerRootOption],
        makeBrowserStore: @escaping @MainActor (_ projectID: String) -> SupermuxMobileFileBrowserStore?
    ) {
        self.rootOptions = rootOptions
        self.makeBrowserStore = makeBrowserStore
    }
}

/// Path arithmetic for the picker's result, kept off the views for unit
/// testing.
enum SupermuxFolderPickerPath {
    /// The picked folder's absolute Mac path: the root's absolute path joined
    /// with the browsed root-relative subpath.
    /// - Parameters:
    ///   - rootPath: The root's absolute Mac path.
    ///   - relativePath: The browsed root-relative path ("" = the root).
    static func absolutePath(rootPath: String, relativePath: String) -> String {
        guard !relativePath.isEmpty else { return rootPath }
        return rootPath.hasSuffix("/") ? rootPath + relativePath : rootPath + "/" + relativePath
    }
}

/// The folder-picker sheet: choose a project root, browse its folders, and
/// confirm one — the picked ABSOLUTE Mac path lands in `onPick` (the project
/// editor's root-path field).
public struct SupermuxFolderPickerSheet: View {
    private let picking: SupermuxProjectRootPathPicking
    private let onPick: @MainActor (String) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Creates the picker sheet.
    /// - Parameters:
    ///   - picking: The live session's picker seam.
    ///   - onPick: Receives the picked folder's absolute Mac path.
    public init(
        picking: SupermuxProjectRootPathPicking,
        onPick: @escaping @MainActor (String) -> Void
    ) {
        self.picking = picking
        self.onPick = onPick
    }

    public var body: some View {
        NavigationStack {
            rootList
                .navigationTitle(String(
                    localized: "supermux.files.picker.title",
                    defaultValue: "Choose Folder",
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
                }
        }
        .accessibilityIdentifier("SupermuxFolderPickerSheet")
    }

    private var rootList: some View {
        List(picking.rootOptions()) { option in
            NavigationLink {
                SupermuxFolderPickerBrowser(
                    option: option,
                    makeStore: picking.makeBrowserStore,
                    pick: { path in
                        onPick(path)
                        dismiss()
                    }
                )
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.name)
                            .font(.body.weight(.medium))
                        Text(option.rootPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }
}

/// One root's folder browser: breadcrumb + directories-only listing + the
/// "Use This Folder" confirm for the current directory.
struct SupermuxFolderPickerBrowser: View {
    let option: SupermuxFolderPickerRootOption
    let makeStore: @MainActor (_ projectID: String) -> SupermuxMobileFileBrowserStore?
    let pick: @MainActor (String) -> Void

    @State private var store: SupermuxMobileFileBrowserStore?

    var body: some View {
        VStack(spacing: 0) {
            if let store, store.hasLoaded {
                SupermuxFileBreadcrumbBar(
                    segments: store.pathSegments,
                    navigateToDepth: { depth in
                        let store = store
                        Task { await store.navigate(toDepth: depth) }
                    }
                )
                Divider()
                folderList(store)
            } else {
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
        }
        .navigationTitle(option.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom) {
            chooseButton
        }
        .task {
            let store = self.store ?? makeStore(option.projectID)
            self.store = store
            await store?.load()
        }
        .accessibilityIdentifier("SupermuxFolderPickerBrowser")
    }

    private func folderList(_ store: SupermuxMobileFileBrowserStore) -> some View {
        let folders = SupermuxFileRowSnapshot.rows(from: store.entries).filter(\.isDirectory)
        return List {
            if let errorDescription = store.lastErrorDescription {
                Section {
                    Text(errorDescription)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            if folders.isEmpty {
                Section {
                    Text(String(
                        localized: "supermux.files.picker.noSubfolders",
                        defaultValue: "No subfolders",
                        bundle: .module
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            ForEach(folders) { row in
                Button {
                    let store = store
                    Task { await store.navigate(into: row.name) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .refreshable { await store.refresh() }
    }

    private var chooseButton: some View {
        Button {
            pick(SupermuxFolderPickerPath.absolutePath(
                rootPath: option.rootPath,
                relativePath: store?.currentPath ?? ""
            ))
        } label: {
            Text(String(
                localized: "supermux.files.picker.choose",
                defaultValue: "Use This Folder",
                bundle: .module
            ))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .disabled(store?.hasLoaded != true)
        .accessibilityIdentifier("SupermuxFolderPickerChooseButton")
    }
}
