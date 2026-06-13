import Foundation
import SupermuxKit
import Testing

/// Tests for ``SupermuxProjectAction`` semantics and the way actions ride
/// along with ``SupermuxProject`` through Codable.
///
/// Covers launchability, icon fallback, project round-tripping of the
/// `actions` array, and backward-compatible decoding of older payloads that
/// predate both the `actions` key on projects and the `id` key on actions.
struct SupermuxProjectActionTests {
    // MARK: - Helpers

    /// A JSON encoder matching the store's on-disk shape: stable key order
    /// and ISO8601 dates, so encoded output is deterministic and comparable.
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// A JSON decoder paired with ``makeEncoder()`` for symmetric round-trips.
    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Whether two actions agree on every persisted field.
    private func actionsMatch(_ lhs: SupermuxProjectAction, _ rhs: SupermuxProjectAction) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.command == rhs.command
            && lhs.iconSymbol == rhs.iconSymbol
    }

    // MARK: - isLaunchable

    @Test func isLaunchableTrueWhenNameAndCommandAreNonEmpty() {
        let action = SupermuxProjectAction(name: "Dev server", command: "npm run dev")
        #expect(action.isLaunchable)
    }

    @Test func isLaunchableFalseWhenNameIsBlank() {
        let action = SupermuxProjectAction(name: "", command: "npm run dev")
        #expect(!action.isLaunchable)
    }

    @Test func isLaunchableFalseWhenCommandIsBlank() {
        let action = SupermuxProjectAction(name: "Dev server", command: "")
        #expect(!action.isLaunchable)
    }

    @Test func isLaunchableFalseWhenNameIsWhitespaceOnly() {
        let action = SupermuxProjectAction(name: "   \t\n", command: "npm run dev")
        #expect(!action.isLaunchable)
    }

    @Test func isLaunchableFalseWhenCommandIsWhitespaceOnly() {
        let action = SupermuxProjectAction(name: "Dev server", command: "   \t\n")
        #expect(!action.isLaunchable)
    }

    // MARK: - resolvedIconSymbol

    @Test func resolvedIconSymbolReturnsSetSymbol() {
        let action = SupermuxProjectAction(name: "Edit", command: "cursor .", iconSymbol: "pencil")
        #expect(action.resolvedIconSymbol == "pencil")
    }

    @Test func resolvedIconSymbolFallsBackToBoltWhenNil() {
        let action = SupermuxProjectAction(name: "Edit", command: "cursor .", iconSymbol: nil)
        #expect(action.resolvedIconSymbol == "bolt")
    }

    @Test func resolvedIconSymbolFallsBackToBoltWhenWhitespaceOnly() {
        let action = SupermuxProjectAction(name: "Edit", command: "cursor .", iconSymbol: "   \t\n")
        #expect(action.resolvedIconSymbol == "bolt")
    }

    // MARK: - Codable round-trip carries actions

    @Test func projectRoundTripCarriesActions() throws {
        let withIcon = SupermuxProjectAction(name: "Open in editor", command: "cursor .", iconSymbol: "pencil")
        let withoutIcon = SupermuxProjectAction(name: "Dev server", command: "npm run dev")
        let project = SupermuxProject(
            name: "Alpha",
            rootPath: "/tmp/alpha",
            actions: [withIcon, withoutIcon]
        )

        let data = try makeEncoder().encode(project)
        let decoded = try makeDecoder().decode(SupermuxProject.self, from: data)

        try #require(decoded.actions.count == 2)
        #expect(actionsMatch(decoded.actions[0], withIcon))
        #expect(actionsMatch(decoded.actions[1], withoutIcon))
        #expect(decoded.actions[0].iconSymbol == "pencil")
        #expect(decoded.actions[1].iconSymbol == nil)
    }

    // MARK: - Backward compatibility

    @Test func projectWithoutActionsKeyDecodesToEmptyActions() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Legacy","rootPath":"/tmp/legacy"}
        """
        let decoded = try makeDecoder().decode(SupermuxProject.self, from: Data(json.utf8))
        #expect(decoded.actions == [])
    }

    @Test func actionWithoutIdKeySynthesizesUUID() throws {
        let json = #"{"name":"x","command":"y"}"#
        let decoded = try makeDecoder().decode(SupermuxProjectAction.self, from: Data(json.utf8))
        #expect(decoded.name == "x")
        #expect(decoded.command == "y")
        // No explicit assertion on the value: a synthesized UUID is always
        // valid, and decoding above would have thrown if `id` were required.
    }
}
