import SwiftUI

/// The New Worktree sheet's "which Mac" choice: the Macs that have this
/// repository (the project's own Mac first), which one is selected, and
/// whether a switch is still fetching that Mac's branches.
public struct SupermuxNewWorktreeMacPicker {
    let options: [SupermuxNewWorktreeMacOption]
    let selectedPairingID: String
    /// The Mac being switched to while its branches load, if any.
    let preparingPairingID: String?
    /// Why the last switch failed, if it did.
    let errorMessage: String?
    let select: @MainActor (_ pairingID: String) -> Void

    /// Creates the picker state.
    /// - Parameters:
    ///   - options: The Macs to offer, own Mac first.
    ///   - selectedPairingID: The Mac the create currently targets.
    ///   - preparingPairingID: The Mac being switched to, if any.
    ///   - errorMessage: Why the last switch failed, if it did.
    ///   - select: Switches the create to another Mac.
    public init(
        options: [SupermuxNewWorktreeMacOption],
        selectedPairingID: String,
        preparingPairingID: String? = nil,
        errorMessage: String? = nil,
        select: @escaping @MainActor (_ pairingID: String) -> Void
    ) {
        self.options = options
        self.selectedPairingID = selectedPairingID
        self.preparingPairingID = preparingPairingID
        self.errorMessage = errorMessage
        self.select = select
    }
}

/// The picker's form section: a pop-up menu of Macs (a short, mutually
/// exclusive choice), shown at the top because the Mac decides everything
/// below it — branches, Claude options, where the worktree lives.
struct SupermuxNewWorktreeMacSection: View {
    let picker: SupermuxNewWorktreeMacPicker
    let isBusy: Bool

    var body: some View {
        Section {
            HStack {
                Picker(selection: Binding(
                    get: { picker.preparingPairingID ?? picker.selectedPairingID },
                    set: { picker.select($0) }
                )) {
                    ForEach(picker.options) { option in
                        Text(option.macName).tag(option.pairingID)
                    }
                } label: {
                    Label {
                        Text(String(localized: "supermux.newWorktree.mac.label", defaultValue: "Mac", bundle: .module))
                    } icon: {
                        Image(systemName: "desktopcomputer")
                    }
                }
                .pickerStyle(.menu)
                .disabled(isBusy || picker.preparingPairingID != nil)
                .accessibilityIdentifier("SupermuxNewWorktreeMacPicker")
                if picker.preparingPairingID != nil {
                    ProgressView()
                }
            }
        } footer: {
            if let errorMessage = picker.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else {
                Text(String(
                    localized: "supermux.newWorktree.mac.footer",
                    defaultValue: "The worktree is created in this Mac’s copy of the repository.",
                    bundle: .module
                ))
            }
        }
    }
}
