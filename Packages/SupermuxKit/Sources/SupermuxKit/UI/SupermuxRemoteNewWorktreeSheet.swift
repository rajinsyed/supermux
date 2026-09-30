import AppKit
import SwiftUI

/// The item that presents ``SupermuxRemoteNewWorktreeSheet``.
struct SupermuxRemoteNewWorktreeTarget: Identifiable {
    let location: SupermuxProjectLocation
    let projectName: String
    let avatar: SupermuxProject
    let icon: NSImage?

    var id: String { location.id }
}

/// The minimal New Worktree sheet for a project copy on another Mac:
/// workspace name, branch and starting branch. The other Mac creates the
/// worktree (and names a blank branch itself); its workspace then opens here
/// as a mirror. The full device-aware sheet replaces this later.
struct SupermuxRemoteNewWorktreeSheet: View {
    let target: SupermuxRemoteNewWorktreeTarget
    let create: (SupermuxRemoteWorktreeRequest) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var request = SupermuxRemoteWorktreeRequest()
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private var deviceName: String { target.location.device?.name ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SupermuxProjectAvatarView(project: target.avatar, detectedIcon: target.icon, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "supermux.newWorktree.title", defaultValue: "New Worktree"))
                        .font(.headline)
                    Text(target.projectName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let device = target.location.device {
                    SupermuxDeviceChip(device: device)
                }
            }
            field(
                String(localized: "supermux.newWorktree.workspaceName", defaultValue: "Workspace name"),
                text: $request.workspaceName,
                prompt: String(localized: "supermux.remoteWorktree.workspacePlaceholder", defaultValue: "Named after the branch")
            )
            .focused($nameFocused)
            field(
                String(localized: "supermux.newWorktree.branch", defaultValue: "Branch"),
                text: $request.branchName,
                prompt: String(localized: "supermux.remoteWorktree.branchPlaceholder", defaultValue: "Leave empty to generate one")
            )
            field(
                String(localized: "supermux.remoteWorktree.baseBranch", defaultValue: "Starting branch"),
                text: $request.baseBranch,
                prompt: String(localized: "supermux.remoteWorktree.basePlaceholder", defaultValue: "The project's default branch")
            )
            Text(String(
                localized: "supermux.remoteWorktree.hint",
                defaultValue: "The worktree is created on \(deviceName) and opens here."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(String(localized: "supermux.common.cancel", defaultValue: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button(String(localized: "supermux.remoteWorktree.create", defaultValue: "Create")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { nameFocused = true }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func submit() {
        isCreating = true
        errorMessage = nil
        let request = self.request
        Task { @MainActor in
            do {
                try await create(request)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
