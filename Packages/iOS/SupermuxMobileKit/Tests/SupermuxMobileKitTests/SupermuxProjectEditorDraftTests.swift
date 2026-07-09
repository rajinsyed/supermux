import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// The editor draft's diff: only keys the user actually changed reach the
/// patch (present-key semantics), normalization matches the desktop editor
/// (trimmed name, per-line run commands, single-entry scripts, sanitized
/// worktrees folder, launchable-only actions), and config-managed fields
/// never leave the phone.
@Suite struct SupermuxProjectEditorDraftTests {
    private func fixture(
        configPath: String? = nil
    ) -> SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: "11111111-1111-1111-1111-111111111111",
            name: "Alpha",
            rootPath: "/Users/dev/alpha",
            colorHex: "#3b82f6",
            iconSymbol: "folder",
            hasCustomIcon: false,
            defaultBranch: "main",
            worktreesDirName: ".worktrees",
            runCommands: ["bun run dev"],
            setupCommands: ["bun install"],
            teardownCommands: [],
            actions: [
                SupermuxProjectActionDTO(
                    id: "6F9B2E44-6F70-4E86-8D6F-111111111111",
                    name: "Build",
                    command: "make build",
                    iconSymbol: "hammer"
                ),
            ],
            configPath: configPath
        )
    }

    // MARK: Seeding

    @Test func draftSeedsFromTheDTOJoiningCommandArraysIntoEditorText() {
        let draft = SupermuxProjectEditorDraft(project: fixture())
        #expect(draft.name == "Alpha")
        #expect(draft.colorHex == "#3b82f6")
        #expect(draft.iconSymbol == "folder")
        #expect(draft.defaultBranch == "main")
        #expect(draft.worktreesDirName == ".worktrees")
        #expect(draft.runCommandsText == "bun run dev")
        #expect(draft.setupScriptText == "bun install")
        #expect(draft.teardownScriptText.isEmpty)
        #expect(draft.actions.count == 1)
    }

    @Test func seedingToleratesAbsentOptionalFields() {
        let sparse = SupermuxProjectDTO(
            id: "22222222-2222-2222-2222-222222222222",
            name: "Sparse",
            rootPath: "/Users/dev/sparse"
        )
        let draft = SupermuxProjectEditorDraft(project: sparse)
        #expect(draft.colorHex == nil)
        #expect(draft.iconSymbol == nil)
        #expect(draft.defaultBranch.isEmpty)
        #expect(draft.worktreesDirName == ".worktrees")
        #expect(draft.runCommandsText.isEmpty)
        #expect(draft.actions.isEmpty)
    }

    // MARK: Diff

    @Test func unchangedDraftProducesAnEmptyPatch() {
        let original = fixture()
        let draft = SupermuxProjectEditorDraft(project: original)
        #expect(draft.patch(from: original).isEmpty)
    }

    @Test func onlyChangedKeysArePresent() {
        let original = fixture()
        var draft = SupermuxProjectEditorDraft(project: original)
        draft.name = "  Renamed  "
        draft.colorHex = "#ef4444"
        let patch = draft.patch(from: original)
        #expect(patch.wireObject as NSDictionary == [
            "name": "Renamed",
            "color_hex": "#ef4444",
        ] as NSDictionary)
    }

    @Test func clearingNullableFieldsPatchesExplicitNull() {
        let original = fixture()
        var draft = SupermuxProjectEditorDraft(project: original)
        draft.colorHex = nil
        draft.iconSymbol = nil
        draft.defaultBranch = "   "
        let patch = draft.patch(from: original)
        #expect(patch.colorHex == .clear)
        #expect(patch.iconSymbol == .clear)
        #expect(patch.defaultBranch == .clear)
    }

    @Test func blankNameIsNeverPatched() {
        let original = fixture()
        var draft = SupermuxProjectEditorDraft(project: original)
        draft.name = "   "
        #expect(draft.patch(from: original).isEmpty)
    }

    @Test func runCommandsSplitPerLineDroppingBlanks() {
        let original = fixture()
        var draft = SupermuxProjectEditorDraft(project: original)
        draft.runCommandsText = "  bun run dev  \n\n  bun run worker "
        let patch = draft.patch(from: original)
        #expect(patch.runCommands == ["bun run dev", "bun run worker"])
    }

    @Test func scriptsStayOneMultilineEntry() {
        let original = fixture()
        var draft = SupermuxProjectEditorDraft(project: original)
        draft.setupScriptText = "bun install\nbun run build\n"
        draft.teardownScriptText = "   "
        let patch = draft.patch(from: original)
        #expect(patch.setupCommands == ["bun install\nbun run build"])
        // Teardown was already empty on the original — no change, no key.
        #expect(patch.teardownCommands == nil)
    }

    @Test func clearingSetupScriptSendsAnEmptyArray() {
        let original = fixture()
        var draft = SupermuxProjectEditorDraft(project: original)
        draft.setupScriptText = ""
        #expect(draft.patch(from: original).setupCommands == [])
    }

    @Test func worktreesDirNameIsSanitizedLikeTheDesktopEditor() {
        let original = fixture()
        var draft = SupermuxProjectEditorDraft(project: original)
        draft.worktreesDirName = " tre/es "
        #expect(draft.patch(from: original).worktreesDirName == "trees")

        draft.worktreesDirName = ".."
        // Sanitizes to the default, which matches the original — no key.
        #expect(draft.patch(from: original).worktreesDirName == nil)
    }

    @Test func actionsAreTrimmedFilteredAndReplacedWhole() throws {
        let original = fixture()
        var draft = SupermuxProjectEditorDraft(project: original)
        draft.actions[0].name = "  Build  "
        draft.actions.append(SupermuxProjectActionDTO(
            id: "6F9B2E44-6F70-4E86-8D6F-222222222222",
            name: "Deploy",
            command: "  make deploy ",
            iconSymbol: "  "
        ))
        draft.actions.append(SupermuxProjectEditorDraft.newAction()) // stays blank → dropped
        let patch = draft.patch(from: original)
        let actions = try #require(patch.actions)
        #expect(actions.count == 2)
        #expect(actions[0].name == "Build")
        #expect(actions[1].command == "make deploy")
        #expect(actions[1].iconSymbol == nil)
    }

    @Test func newActionsGetFreshUUIDIdentities() {
        let action = SupermuxProjectEditorDraft.newAction()
        #expect(UUID(uuidString: action.id) != nil)
        #expect(action.name.isEmpty)
        #expect(action.command.isEmpty)
    }

    @Test func configManagedFieldsNeverReachThePatch() {
        let original = fixture(configPath: ".supermux/config.json")
        var draft = SupermuxProjectEditorDraft(project: original)
        draft.runCommandsText = "changed"
        draft.setupScriptText = "changed"
        draft.teardownScriptText = "changed"
        draft.actions = []
        draft.name = "Still Editable"
        let patch = draft.patch(from: original)
        #expect(patch.runCommands == nil)
        #expect(patch.setupCommands == nil)
        #expect(patch.teardownCommands == nil)
        #expect(patch.actions == nil)
        #expect(patch.name == "Still Editable")
    }
}

/// The preset draft's create params and update diff.
@Suite struct SupermuxPresetDraftTests {
    private let original = SupermuxTerminalPresetDTO(
        id: "33333333-3333-3333-3333-333333333333",
        name: "Claude",
        command: "claude",
        iconSymbol: "sparkles",
        colorHex: "#a855f7"
    )

    @Test func createRequestRequiresNameAndCommand() {
        var draft = SupermuxPresetDraft()
        #expect(!draft.canSave)
        #expect(draft.createRequest() == nil)
        draft.name = " Claude "
        draft.command = " claude "
        #expect(draft.canSave)
        let request = draft.createRequest()
        #expect(request?.wireParams as NSDictionary? == [
            "name": "Claude",
            "command": "claude",
        ] as NSDictionary)
    }

    @Test func createRequestCarriesOptionalStyleFieldsOnlyWhenSet() {
        var draft = SupermuxPresetDraft()
        draft.name = "Claude"
        draft.command = "claude"
        draft.iconSymbol = "sparkles"
        draft.colorHex = "#a855f7"
        #expect(draft.createRequest()?.wireParams as NSDictionary? == [
            "name": "Claude",
            "command": "claude",
            "icon_symbol": "sparkles",
            "color_hex": "#a855f7",
        ] as NSDictionary)
    }

    @Test func unchangedDraftProducesAnEmptyPatch() {
        let draft = SupermuxPresetDraft(preset: original)
        #expect(draft.patch(from: original).isEmpty)
    }

    @Test func diffPatchesOnlyChangedKeysAndClearsWithNull() {
        var draft = SupermuxPresetDraft(preset: original)
        draft.command = " claude --resume "
        draft.colorHex = nil
        let patch = draft.patch(from: original)
        let object = patch.wireObject
        #expect(object.count == 2)
        #expect(object["command"] as? String == "claude --resume")
        #expect(object["color_hex"] is NSNull)
    }

    @Test func blankNameOrCommandIsNeverPatched() {
        var draft = SupermuxPresetDraft(preset: original)
        draft.name = "  "
        draft.command = ""
        #expect(draft.patch(from: original).isEmpty)
    }
}
