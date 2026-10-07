import Foundation

/// Text parsing and messages for ``SupermuxProjectEditorSheet``.
extension SupermuxProjectEditorSheet {
    static func unreadableConfigMessage(_ relativePath: String) -> String {
        String(
            localized: "supermux.projectEditor.configUnreadable",
            defaultValue: "\(relativePath) couldn't be read. Fix or delete it."
        )
    }

    static func configSaveMessage(for error: any Error) -> String {
        switch error as? SupermuxProjectConfigWriter.WriteError {
        case .existingFileUnreadable:
            return unreadableConfigMessage(SupermuxProjectConfigWriter.relativePath)
        case .projectRootMissing:
            return String(
                localized: "supermux.projectEditor.configSaveFailed.rootMissing",
                defaultValue: "The project folder no longer exists."
            )
        case nil:
            return String(
                localized: "supermux.projectEditor.configSaveFailed",
                defaultValue: "Couldn't save .supermux/config.json: \(error.localizedDescription)"
            )
        }
    }

    /// Splits the run editor's text into one command per non-empty line.
    static func runEntries(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Stores a setup/teardown editor's text as a single multi-line script entry
    /// (internal newlines preserved), unlike run commands which split per line.
    static func scriptEntries(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }
}
