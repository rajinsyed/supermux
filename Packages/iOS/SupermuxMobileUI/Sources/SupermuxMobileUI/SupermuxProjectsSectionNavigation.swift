import Foundation
import SwiftUI

/// Navigation + error dressing for the Projects section, attached by the
/// section driver OUTSIDE the shell's `List` (m6-f1):
///
/// - The project DETAIL route: the row's info accessory and long-press menu
///   both set ``SupermuxProjectsSectionModel/detailProjectID``; this modifier
///   binds it to a `navigationDestination`, so both affordances share one
///   navigation path (tapping the row itself only toggles the inline
///   disclosure, mac-sidebar style).
/// - The nested-worktree open-failure alert (UI-03: visible, never silent).
///
/// Holding the model here is fine — this is a stable wrapper above the
/// `List`, not a row inside it.
struct SupermuxProjectsSectionNavigation: ViewModifier {
    let model: SupermuxProjectsSectionModel

    func body(content: Content) -> some View {
        // Read the observable fields in body (not just inside Binding
        // getters) so observation tracking re-evaluates this modifier when
        // they change.
        let isDetailPresented = model.detailProjectID != nil
        let openError = model.nestedOpenErrorMessage
        content
            .navigationDestination(isPresented: Binding(
                get: { isDetailPresented },
                set: { [weak model] presented in
                    if !presented {
                        model?.dismissProjectDetail()
                    }
                }
            )) {
                SupermuxProjectDetailResolvedScreen(model: model)
            }
            .alert(
                String(
                    localized: "supermux.worktrees.open.failed.title",
                    defaultValue: "Couldn’t Open Worktree",
                    bundle: .module
                ),
                isPresented: Binding(
                    get: { openError != nil },
                    set: { [weak model] presented in
                        if !presented {
                            model?.dismissNestedOpenError()
                        }
                    }
                ),
                presenting: openError
            ) { _ in
                Button(role: .cancel) {
                    model.dismissNestedOpenError()
                } label: {
                    Text(String(localized: "supermux.common.ok", defaultValue: "OK", bundle: .module))
                }
            } message: { message in
                Text(message)
            }
    }
}

/// Resolves the routed project id against the model's LIVE snapshot and
/// mounts ``SupermuxProjectDetailScreen`` — so the pushed detail keeps
/// updating (nested workspaces, run state) with the session. Falls back to a
/// localized placeholder when the project (or the session) went away while
/// the screen was pushed.
struct SupermuxProjectDetailResolvedScreen: View {
    let model: SupermuxProjectsSectionModel

    var body: some View {
        if let row = model.detailRow {
            let snapshot = model.snapshot
            let actions = model.actions
            SupermuxProjectDetailScreen(
                row: row,
                iconPNGData: actions.iconPNGData,
                selectWorkspace: actions.selectWorkspace,
                makeWorktreesStore: actions.makeWorktreesStore,
                editing: actions.editing,
                presets: snapshot.showsPresets ? snapshot.presets : [],
                showsPresets: snapshot.showsPresets,
                showsActions: snapshot.showsActions,
                runActions: actions.run
            )
        } else {
            Text(String(
                localized: "supermux.projects.detail.unavailable",
                defaultValue: "This project is no longer available.",
                bundle: .module
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding()
            .accessibilityIdentifier("SupermuxProjectDetailUnavailable")
        }
    }
}
