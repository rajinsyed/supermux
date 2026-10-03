import SupermuxMobileKit
import SwiftUI

/// The New Worktree sheet plus its Mac picker — the ONE create sheet both the
/// sidebar and the project detail present.
///
/// Owns which Mac the create targets. Picking another Mac fetches that Mac's
/// branches, then swaps in stores bound to ITS client: the create (and the
/// Claude start) run on that Mac without making it the foreground, and the
/// navigation afterwards lands on that Mac's workspace row. What the user
/// already typed stays, because the sheet itself is never rebuilt.
struct SupermuxNewWorktreeFlowSheet: View {
    let options: [SupermuxNewWorktreeMacOption]
    let prepareTarget: @MainActor (SupermuxNewWorktreeMacOption) async throws -> SupermuxNewWorktreeTarget

    @State private var target: SupermuxNewWorktreeTarget
    @State private var preparingPairingID: String?
    @State private var pickerError: String?

    /// Creates the flow.
    /// - Parameters:
    ///   - initialTarget: The create target on the project's own Mac.
    ///   - options: The Macs with the same repository, own Mac first.
    ///   - prepareTarget: Retargets the create to another Mac.
    init(
        initialTarget: SupermuxNewWorktreeTarget,
        options: [SupermuxNewWorktreeMacOption],
        prepareTarget: @escaping @MainActor (SupermuxNewWorktreeMacOption) async throws -> SupermuxNewWorktreeTarget
    ) {
        self.options = options
        self.prepareTarget = prepareTarget
        _target = State(initialValue: initialTarget)
    }

    var body: some View {
        let store = target.store
        SupermuxNewWorktreeSheet(
            projectName: target.projectName,
            branches: store.branches,
            defaultBaseBranch: target.defaultBranch,
            showsBaseBranchPicker: store.supportsStartingBranchSelection,
            agentStore: target.agentStore,
            macPicker: options.count > 1
                ? SupermuxNewWorktreeMacPicker(
                    options: options,
                    selectedPairingID: target.pairingID,
                    preparingPairingID: preparingPairingID,
                    errorMessage: pickerError,
                    select: select
                )
                : nil,
            suggestBranch: { workspaceName in
                try await store.suggestBranchName(workspaceName: workspaceName).branchName
            },
            createWorktree: { workspaceName, branchName, baseBranch, open in
                try await store.createWorktree(
                    workspaceName: workspaceName,
                    branchName: branchName,
                    baseBranch: baseBranch,
                    open: open
                ).workspaceId
            },
            openWorkspace: target.openWorkspace
        )
    }

    /// Switches the create to another Mac once its branches have loaded; a
    /// failure keeps the current Mac and says why under the picker.
    private func select(_ pairingID: String) {
        guard pairingID != target.pairingID, preparingPairingID == nil,
              let option = options.first(where: { $0.pairingID == pairingID }) else { return }
        preparingPairingID = pairingID
        pickerError = nil
        Task {
            defer { preparingPairingID = nil }
            do {
                target = try await prepareTarget(option)
            } catch {
                pickerError = error.localizedDescription
            }
        }
    }
}
