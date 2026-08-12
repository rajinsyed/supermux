import Foundation

/// Composer behavior for the Claude chat screen, kept off the view so the
/// send gate and the slash-command autocomplete are unit-testable.
///
/// lint:allow namespace-enum — stateless composer predicates.
public enum SupermuxClaudeComposerPresentation {
    /// Whether the send button is enabled.
    ///
    /// Whitespace-only drafts are rejected here rather than sent for the Mac
    /// to reject: a prompt of spaces would consume a real turn.
    ///
    /// - Parameters:
    ///   - draft: The composer's text.
    ///   - isSending: Whether a send is already on the wire.
    public static func canSend(draft: String, isSending: Bool) -> Bool {
        guard !isSending else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the composer's primary button is the STOP control.
    ///
    /// Sending stays available while a turn runs (the Mac queues it), so stop
    /// only takes over the primary slot when there is nothing to send — a
    /// composer that swapped its button out mid-typing would eat the tap the
    /// user aimed at Send.
    ///
    /// - Parameters:
    ///   - isWorking: Whether the session is running a turn.
    ///   - draft: The composer's text.
    public static func showsStop(isWorking: Bool, draft: String) -> Bool {
        isWorking && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The slash-command suggestions for the current draft, or an empty array
    /// when the autocomplete should be hidden.
    ///
    /// Only a draft that is a single leading-slash token autocompletes: once
    /// the user types a space the command has arguments and the list would be
    /// covering the text they are writing.
    ///
    /// - Parameters:
    ///   - draft: The composer's text.
    ///   - commands: The command names from `claude.options` (with or without
    ///     a leading slash — the Mac reports `system.init`'s list verbatim).
    ///   - limit: Maximum suggestions to show.
    public static func slashSuggestions(
        draft: String,
        commands: [String],
        limit: Int = 8
    ) -> [String] {
        guard draft.hasPrefix("/"), !draft.contains(" "), !draft.contains("\n") else { return [] }
        let query = draft.dropFirst().lowercased()
        let normalized = commands.map { command -> String in
            command.hasPrefix("/") ? String(command.dropFirst()) : command
        }
        let matches = normalized
            .filter { query.isEmpty || $0.lowercased().hasPrefix(query) }
            .sorted()
            .prefix(limit)
        return matches.map { "/" + $0 }
    }

    /// The draft after accepting a suggestion: the command plus a trailing
    /// space, so the user can type arguments without reaching for the
    /// spacebar first.
    /// - Parameter command: The accepted command, with its leading slash.
    public static func accept(command: String) -> String {
        command + " "
    }
}
