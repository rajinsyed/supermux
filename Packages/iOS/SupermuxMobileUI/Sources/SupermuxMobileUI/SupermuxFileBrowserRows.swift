import Foundation
import SupermuxMobileCore
import SwiftUI

/// Immutable value snapshot of one file-browser row, computed above the
/// `List` boundary. Row views render exclusively from this value plus the
/// closure ``SupermuxFileRowActions`` bundle — no store reference crosses
/// the boundary (repo snapshot-boundary rule).
struct SupermuxFileRowSnapshot: Equatable, Identifiable, Sendable {
    /// Entry names are unique within a directory — the row identity.
    var id: String { name }
    /// The entry's name (last path component).
    let name: String
    /// Whether the entry is a directory (navigable).
    let isDirectory: Bool
    /// Whether the entry is a symbolic link.
    let isSymlink: Bool
    /// Human-readable file size; `nil` for directories or when unknown.
    let sizeText: String?

    /// Maps one wire entry onto a row value.
    /// - Parameter entry: The wire entry.
    init(entry: SupermuxFileEntryDTO) {
        name = entry.name
        isDirectory = entry.isDir == true
        isSymlink = entry.isSymlink == true
        if entry.isDir != true, let size = entry.size {
            sizeText = Int64(size).formatted(.byteCount(style: .file))
        } else {
            sizeText = nil
        }
    }

    /// The row's leading SF symbol.
    var iconSystemName: String {
        if isSymlink { return "link" }
        return isDirectory ? "folder" : "doc.text"
    }

    /// Maps a listing onto row values, preserving the Mac's order.
    /// - Parameter entries: The wire entries.
    static func rows(from entries: [SupermuxFileEntryDTO]) -> [SupermuxFileRowSnapshot] {
        entries.map(SupermuxFileRowSnapshot.init(entry:))
    }
}

/// Closure action bundle for file-browser rows — the only way row-level
/// views reach back to the screen (no store reference crosses the `List`
/// boundary). "Request" actions open a confirm/prompt on the screen; the
/// others act immediately.
struct SupermuxFileRowActions {
    /// Descends into a directory entry.
    let open: @MainActor (_ name: String) -> Void
    /// Opens the rename prompt for an entry.
    let requestRename: @MainActor (_ name: String) -> Void
    /// `files.duplicate` for an entry (Mac picks the copy's name).
    let duplicate: @MainActor (_ name: String) -> Void
    /// Opens the destructive trash confirm for an entry.
    let requestTrash: @MainActor (_ name: String) -> Void
}

/// One file-browser row: icon + name (+ size), tappable for directories,
/// with the Rename / Duplicate / Move to Trash context menu and swipe
/// actions (desktop file-explorer parity).
struct SupermuxFileEntryRow: View {
    let row: SupermuxFileRowSnapshot
    let actions: SupermuxFileRowActions

    var body: some View {
        Group {
            if row.isDirectory {
                Button {
                    actions.open(row.name)
                } label: {
                    rowLabel
                }
                .buttonStyle(.plain)
            } else {
                rowLabel
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                actions.requestTrash(row.name)
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
            Button {
                actions.requestRename(row.name)
            } label: {
                Label {
                    Text(String(
                        localized: "supermux.files.menu.rename",
                        defaultValue: "Rename…",
                        bundle: .module
                    ))
                } icon: {
                    Image(systemName: "pencil")
                }
            }
        }
        .contextMenu {
            Button {
                actions.requestRename(row.name)
            } label: {
                Label {
                    Text(String(
                        localized: "supermux.files.menu.rename",
                        defaultValue: "Rename…",
                        bundle: .module
                    ))
                } icon: {
                    Image(systemName: "pencil")
                }
            }
            Button {
                actions.duplicate(row.name)
            } label: {
                Label {
                    Text(String(
                        localized: "supermux.files.menu.duplicate",
                        defaultValue: "Duplicate",
                        bundle: .module
                    ))
                } icon: {
                    Image(systemName: "plus.square.on.square")
                }
            }
            Divider()
            Button(role: .destructive) {
                actions.requestTrash(row.name)
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
        }
        .accessibilityIdentifier("SupermuxFileRow_\(row.name)")
    }

    private var rowLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: row.iconSystemName)
                .foregroundStyle(row.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let sizeText = row.sizeText {
                Text(sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if row.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The tappable root-relative breadcrumb above the listing: a home crumb for
/// the root plus one crumb per path segment. Renders from values only.
struct SupermuxFileBreadcrumbBar: View {
    /// The current directory's root-relative path segments.
    let segments: [String]
    /// Jumps to an ancestor: keeps the first `depth` segments (0 = root).
    let navigateToDepth: @MainActor (_ depth: Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    navigateToDepth(0)
                } label: {
                    Image(systemName: "house")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(segments.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .accessibilityLabel(String(
                    localized: "supermux.files.breadcrumb.root",
                    defaultValue: "Root folder",
                    bundle: .module
                ))
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Button {
                        navigateToDepth(index + 1)
                    } label: {
                        Text(segment)
                            .font(.footnote.weight(index == segments.count - 1 ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == segments.count - 1 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("SupermuxFileBreadcrumbBar")
    }
}
