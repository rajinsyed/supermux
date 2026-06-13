import Foundation
import Testing
@testable import SupermuxKit

/// Unit tests for ``SupermuxTerminalPreset`` and the presets-on-disk encoding in
/// ``SupermuxProjectsFile`` (nil omitted vs. an explicitly empty list preserved).
struct SupermuxTerminalPresetTests {
    @Test func defaultsAreLaunchableWithUniqueIds() {
        let defaults = SupermuxTerminalPreset.defaults
        #expect(!defaults.isEmpty)
        #expect(defaults.allSatisfy { $0.isLaunchable })
        #expect(Set(defaults.map(\.id)).count == defaults.count)
        #expect(Set(defaults.map(\.name)).count == defaults.count)
    }

    @Test func isLaunchableRequiresNameAndCommand() {
        #expect(SupermuxTerminalPreset(name: "claude", command: "claude").isLaunchable)
        #expect(!SupermuxTerminalPreset(name: "  ", command: "claude").isLaunchable)
        #expect(!SupermuxTerminalPreset(name: "claude", command: "   ").isLaunchable)
        #expect(!SupermuxTerminalPreset(name: "", command: "").isLaunchable)
    }

    @Test func resolvedIconSymbolFallsBackToTerminal() {
        #expect(SupermuxTerminalPreset(name: "x", command: "x").resolvedIconSymbol == "terminal")
        #expect(SupermuxTerminalPreset(name: "x", command: "x", iconSymbol: "  ").resolvedIconSymbol == "terminal")
        #expect(SupermuxTerminalPreset(name: "x", command: "x", iconSymbol: "sparkle").resolvedIconSymbol == "sparkle")
    }

    @Test func codableRoundTripPreservesFields() throws {
        let preset = SupermuxTerminalPreset(
            name: "codex",
            command: "codex --high",
            iconSymbol: "chevron.left.forward.slash.chevron.right",
            colorHex: "#64748b"
        )
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(SupermuxTerminalPreset.self, from: data)
        #expect(decoded == preset)
    }

    @Test func decodingWithoutIdSynthesizesAFreshOne() throws {
        let json = #"{"name":"claude","command":"claude"}"#
        let decoded = try JSONDecoder().decode(SupermuxTerminalPreset.self, from: Data(json.utf8))
        #expect(decoded.name == "claude")
        #expect(decoded.command == "claude")
        #expect(decoded.iconSymbol == nil)
        #expect(decoded.colorHex == nil)
    }

    @Test func fileOmitsPresetsKeyWhenNil() throws {
        let file = SupermuxProjectsFile(version: 2, projects: [], isSectionCollapsed: false, presets: nil)
        let data = try JSONEncoder().encode(file)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["presets"] == nil)
    }

    @Test func fileDecodesMissingPresetsAsNilAndEmptyAsEmpty() throws {
        let missing = #"{"version":1,"projects":[],"isSectionCollapsed":false}"#
        let decodedMissing = try JSONDecoder().decode(SupermuxProjectsFile.self, from: Data(missing.utf8))
        #expect(decodedMissing.presets == nil)

        let empty = #"{"version":2,"projects":[],"isSectionCollapsed":false,"presets":[]}"#
        let decodedEmpty = try JSONDecoder().decode(SupermuxProjectsFile.self, from: Data(empty.utf8))
        #expect(decodedEmpty.presets == [])
    }

    @Test func filePresetsRoundTripThroughEncoding() throws {
        let presets = SupermuxTerminalPreset.defaults
        let file = SupermuxProjectsFile(version: 2, projects: [], isSectionCollapsed: true, presets: presets)
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(SupermuxProjectsFile.self, from: data)
        #expect(decoded.presets == presets)
    }
}
