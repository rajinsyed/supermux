import SupermuxMobileKit

/// The file-browser name prompts: what the single text-field alert is
/// currently collecting a name for.
enum SupermuxFileNamePrompt: Equatable {
    /// `files.create {kind: file}` in the current directory.
    case newFile
    /// `files.create {kind: folder}` in the current directory.
    case newFolder
    /// `files.rename` of the entry with the given current name.
    case rename(String)
}

/// Localized user-facing text for file-operation failures: client-side name
/// validation gets dedicated copy; wire errors surface the Mac's message
/// under the shared alert title — mirroring the desktop
/// `SupermuxFileExplorerPrompt` error semantics.
/// lint:allow namespace-enum — stateless issue→localized-text mapping kept off the views for package unit tests.
enum SupermuxFileOpErrorText {
    /// The message for a client-side name-validation failure.
    /// - Parameters:
    ///   - issue: What is wrong with the name.
    ///   - name: The offending name, as typed.
    static func message(forIssue issue: SupermuxFileNameIssue, name: String) -> String {
        switch issue {
        case .empty:
            String(
                localized: "supermux.files.error.emptyName",
                defaultValue: "Enter a name.",
                bundle: .module
            )
        case .containsSlash, .reserved:
            String(
                localized: "supermux.files.error.invalidName",
                defaultValue: "“\(name)” isn’t a valid name.",
                bundle: .module
            )
        }
    }

    /// The message for a failed operation: validation copy for name issues,
    /// the Mac's wire message verbatim otherwise.
    /// - Parameter error: The error the store threw.
    static func message(for error: any Error) -> String {
        if let nameError = error as? SupermuxInvalidFileNameError {
            return message(forIssue: nameError.issue, name: nameError.name)
        }
        return SupermuxWireErrorCode.message(from: error) ?? error.localizedDescription
    }
}
