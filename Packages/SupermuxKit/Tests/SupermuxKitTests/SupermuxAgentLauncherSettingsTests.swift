import Foundation
import Testing
@testable import SupermuxKit

/// Command list, remembered selection, and per-command last model/effort.
struct SupermuxAgentLauncherSettingsTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "SupermuxAgentLauncherSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func freshInstallDefaultsToClaude() throws {
        let settings = SupermuxAgentLauncherSettings(defaults: try makeDefaults())
        #expect(settings.commands == ["claude"])
        #expect(settings.selectedCommand == "claude")
        #expect(settings.lastChoice(for: "claude") == (nil, nil))
    }

    @Test func setCommandsTrimsDedupesAndKeepsSurvivingSelection() throws {
        let settings = SupermuxAgentLauncherSettings(defaults: try makeDefaults())
        settings.setCommands([" claude", "cc", "cc", "", "ccx "])
        #expect(settings.commands == ["claude", "cc", "ccx"])
        settings.setSelectedCommand("cc")
        #expect(settings.selectedCommand == "cc")
        settings.setCommands(["cc", "ccx"])
        #expect(settings.selectedCommand == "cc")
        settings.setCommands(["ccx"])
        #expect(settings.selectedCommand == "ccx", "a dropped selection falls back to the first command")
        settings.setCommands([])
        #expect(settings.commands == ["claude"], "an empty list resets to the default")
    }

    /// Removing the selected command must clear its memory, not merely hide
    /// it — otherwise re-adding the command later silently re-selects it.
    @Test func aDroppedSelectionDoesNotResurrectWhenReAdded() throws {
        let settings = SupermuxAgentLauncherSettings(defaults: try makeDefaults())
        settings.setCommands(["claude", "cc"])
        settings.setSelectedCommand("cc")
        settings.setCommands(["claude"])
        #expect(settings.selectedCommand == "claude")
        settings.setCommands(["claude", "cc"])
        #expect(settings.selectedCommand == "claude", "the stale selection was cleared when cc was removed")
    }

    @Test func selectionIgnoresUnknownCommands() throws {
        let settings = SupermuxAgentLauncherSettings(defaults: try makeDefaults())
        settings.setSelectedCommand("nope")
        #expect(settings.selectedCommand == "claude")
    }

    @Test func lastChoiceIsKeptPerCommand() throws {
        let settings = SupermuxAgentLauncherSettings(defaults: try makeDefaults())
        settings.recordChoice(command: "claude", model: "opus", effort: "high")
        settings.recordChoice(command: "ccx", model: "gpt-5.6-sol", effort: nil)
        #expect(settings.lastChoice(for: "claude") == ("opus", "high"))
        #expect(settings.lastChoice(for: "ccx") == ("gpt-5.6-sol", nil))
        settings.recordChoice(command: "claude", model: nil, effort: nil)
        #expect(settings.lastChoice(for: "claude") == (nil, nil), "a default-model launch clears the memory")
    }
}
