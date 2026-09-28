import SwiftUI

/// The item that presents ``SupermuxProjectSetupSheet``.
struct SupermuxProjectSetupTarget: Identifiable {
    let projectName: String
    let destination: SupermuxProjectSetupDestination
    /// Suggested folder: the project's root path on the Mac it comes from.
    let defaultPath: String
    /// The repository to clone, when the project has an origin.
    let remoteURL: String?

    var id: String { "\(projectName)|\(destination.name)|\(defaultPath)" }
}

/// "Set Up “<project>” on <Mac>…": register an existing folder there as the
/// project, or clone the repository into a folder there and register it.
struct SupermuxProjectSetupSheet: View {
    let target: SupermuxProjectSetupTarget
    let addExisting: (String) async throws -> Void
    let clone: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(
        target: SupermuxProjectSetupTarget,
        addExisting: @escaping (String) async throws -> Void,
        clone: @escaping (String, String) async throws -> Void
    ) {
        self.target = target
        self.addExisting = addExisting
        self.clone = clone
        _path = State(initialValue: target.defaultPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(
                localized: "supermux.projectSetup.title",
                defaultValue: "Set Up “\(target.projectName)” on \(target.destination.name)"
            ))
            .font(.headline)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "supermux.projectSetup.folder", defaultValue: "Folder on \(target.destination.name)"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            if let remoteURL = target.remoteURL {
                Text(String(localized: "supermux.projectSetup.repository", defaultValue: "Repository: \(remoteURL)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(String(
                localized: "supermux.projectSetup.hint",
                defaultValue: "Add Existing Folder registers a checkout that is already there. Clone downloads the repository into the folder first."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(String(localized: "supermux.common.cancel", defaultValue: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(String(localized: "supermux.projectSetup.clone", defaultValue: "Clone")) {
                    run { try await clone(target.remoteURL ?? "", trimmedPath) }
                }
                .disabled(isWorking || target.remoteURL == nil || trimmedPath.isEmpty)
                Button(String(localized: "supermux.projectSetup.addExisting", defaultValue: "Add Existing Folder")) {
                    run { try await addExisting(trimmedPath) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || trimmedPath.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await operation()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }
}
