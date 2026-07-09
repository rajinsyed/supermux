import SupermuxMobileKit
import SwiftUI

/// The changes screen's sync toolbar (bottom bar on iOS): Pull and Push with
/// ahead/behind badges and in-flight spinners, plus a stash menu. Values +
/// closures only; the screen owns the store and the result-sheet state.
struct SupermuxChangesSyncToolbar: ToolbarContent {
    let ahead: Int
    let behind: Int
    let stashCount: Int
    let isBusy: Bool
    let activeOperation: SupermuxChangesSyncOperation?
    let pull: @MainActor () -> Void
    let push: @MainActor () -> Void
    let stash: @MainActor () -> Void
    let stashPop: @MainActor () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: placement) {
            Button(action: pull) {
                SupermuxSyncButtonLabel(
                    title: String(
                        localized: "supermux.changes.action.pull",
                        defaultValue: "Pull",
                        bundle: .module
                    ),
                    systemImage: "arrow.down.circle",
                    count: behind,
                    spinning: activeOperation == .pull
                )
            }
            .disabled(isBusy)
            .accessibilityIdentifier("SupermuxPullButton")

            Button(action: push) {
                SupermuxSyncButtonLabel(
                    title: String(
                        localized: "supermux.changes.action.push",
                        defaultValue: "Push",
                        bundle: .module
                    ),
                    systemImage: "arrow.up.circle",
                    count: ahead,
                    spinning: activeOperation == .push
                )
            }
            .disabled(isBusy)
            .accessibilityIdentifier("SupermuxPushButton")

            Spacer()

            Menu {
                Button(action: stash) {
                    Label {
                        Text(String(
                            localized: "supermux.changes.action.stash",
                            defaultValue: "Stash Changes",
                            bundle: .module
                        ))
                    } icon: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                }
                .accessibilityIdentifier("SupermuxStashButton")
                Button(action: stashPop) {
                    Label {
                        Text(String(
                            localized: "supermux.changes.action.stashPop",
                            defaultValue: "Pop Stash",
                            bundle: .module
                        ))
                    } icon: {
                        Image(systemName: "tray.and.arrow.up")
                    }
                }
                .disabled(stashCount == 0)
                .accessibilityIdentifier("SupermuxStashPopButton")
            } label: {
                Label {
                    Text(String(
                        localized: "supermux.changes.stashMenuLabel",
                        defaultValue: "Stash",
                        bundle: .module
                    ))
                } icon: {
                    Image(systemName: "tray")
                }
                .labelStyle(.iconOnly)
            }
            .disabled(isBusy)
            .accessibilityLabel(String(
                localized: "supermux.changes.stashMenuLabel",
                defaultValue: "Stash",
                bundle: .module
            ))
            .accessibilityIdentifier("SupermuxStashMenu")
        }
    }

    private var placement: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .automatic
        #endif
    }
}

/// A sync button's face: icon (or spinner while that operation is on the
/// wire), title, and the ahead/behind count badge when non-zero.
private struct SupermuxSyncButtonLabel: View {
    let title: String
    let systemImage: String
    let count: Int
    let spinning: Bool

    var body: some View {
        HStack(spacing: 4) {
            if spinning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.tint.opacity(0.15)))
            }
        }
    }
}
