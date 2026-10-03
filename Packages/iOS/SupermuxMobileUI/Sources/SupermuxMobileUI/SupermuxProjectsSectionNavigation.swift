import Foundation
import SupermuxMobileKit
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
        let newWorktreeError = model.newWorktreeErrorMessage
        let isNewWorktreePresented = model.newWorktreePresentation != nil
        content
            .modifier(SupermuxNestedWorktreeRemovalAlerts(model: model))
            // The sidebar's New Worktree sheet (m7): anchored here — on the
            // stable wrapper above the list — because the requesting row
            // lives in a recycled UIKit cell, and a sheet anchored there
            // would be torn down with the cell mid-flow.
            .sheet(isPresented: Binding(
                get: { isNewWorktreePresented },
                set: { [weak model] presented in
                    if !presented { model?.dismissNewWorktree() }
                }
            )) {
                if let presentation = model.newWorktreePresentation {
                    // The create targets the row's own Mac, or whichever Mac
                    // with the same repository the picker switches to.
                    SupermuxNewWorktreeFlowSheet(
                        initialTarget: presentation.target,
                        options: presentation.options,
                        prepareTarget: { option in
                            try await model.prepareNewWorktreeTarget(option)
                        }
                    )
                }
            }
            .alert(
                String(
                    localized: "supermux.newWorktree.title",
                    defaultValue: "New Worktree",
                    bundle: .module
                ),
                isPresented: Binding(
                    get: { newWorktreeError != nil },
                    set: { [weak model] presented in
                        if !presented {
                            model?.dismissNewWorktreeError()
                        }
                    }
                ),
                presenting: newWorktreeError
            ) { _ in
                Button(role: .cancel) {
                    model.dismissNewWorktreeError()
                } label: {
                    Text(String(localized: "supermux.common.ok", defaultValue: "OK", bundle: .module))
                }
            } message: { message in
                Text(message)
            }
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
        if let context = model.detailContext {
            // Bound to the project's OWN Mac: every RPC the detail sends, and
            // every workspace it opens, goes to that Mac.
            SupermuxProjectDetailScreen(context: context)
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
