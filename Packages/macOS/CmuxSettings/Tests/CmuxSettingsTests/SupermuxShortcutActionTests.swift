import Testing

@testable import CmuxSettings

/// SUPERMUX — pins the five supermux shortcut actions in the package enum
/// that drives the Settings UI (`ShortcutAction.settingsVisibleActions` and
/// `detectConflict` both iterate this enum, not the app-target one).
///
/// The raw values and default strokes are a contract with the app target's
/// `KeyboardShortcutSettings.Action` cases (`supermux-*-shortcut-*` fences in
/// `Sources/KeyboardShortcutSettings.swift`); a drift on either side makes
/// the shortcuts invisible/un-rebindable in Settings or excludes them from
/// conflict detection (the original regression this suite guards against).
@Suite("Supermux shortcut actions in the settings package")
struct SupermuxShortcutActionTests {
    private static let expectedDefaults: [ShortcutAction: ShortcutStroke] = [
        .supermuxToggleRun: ShortcutStroke(key: "g", command: true),
        .supermuxWorkspaceSwitcherNext: ShortcutStroke(key: "`", command: true),
        .supermuxWorkspaceSwitcherPrevious: ShortcutStroke(key: "`", command: true, shift: true),
        .supermuxCommit: ShortcutStroke(key: "\r", command: true),
        .supermuxCommitAccelerator: ShortcutStroke(key: "\r", command: true, shift: true),
    ]

    @Test func rawValuesMatchAppTargetActionIdentifiers() {
        // Raw values are the stable ids persisted in cmux.json and shared with
        // the app-target enum — never rename one side alone.
        #expect(ShortcutAction.supermuxToggleRun.rawValue == "supermuxToggleRun")
        #expect(ShortcutAction.supermuxWorkspaceSwitcherNext.rawValue == "supermuxWorkspaceSwitcherNext")
        #expect(ShortcutAction.supermuxWorkspaceSwitcherPrevious.rawValue == "supermuxWorkspaceSwitcherPrevious")
        #expect(ShortcutAction.supermuxCommit.rawValue == "supermuxCommit")
        #expect(ShortcutAction.supermuxCommitAccelerator.rawValue == "supermuxCommitAccelerator")
    }

    @Test func defaultStrokesMirrorAppTargetDefaults() {
        for (action, expected) in Self.expectedDefaults {
            #expect(action.defaultStroke == expected, "\(action) default stroke drifted from the app-target table")
        }
    }

    @Test func allSupermuxActionsAreVisibleInSettings() {
        let visible = Set(ShortcutAction.settingsVisibleActions)
        for action in Self.expectedDefaults.keys {
            #expect(visible.contains(action), "\(action) must be shown in Settings → Keyboard Shortcuts")
        }
    }

    @Test func supermuxActionsUseApplicationContextWithoutPriorityRouting() {
        // The app target maps these to the `.application` context with no
        // pre-routing; the package must agree or conflict detection diverges
        // (the app-side drift test asserts the same pairing).
        for action in Self.expectedDefaults.keys {
            #expect(action.defaultFocusWhenClause == .always, "\(action) when-clause drifted")
            #expect(!action.hasPriorityShortcutRouting, "\(action) priority routing drifted")
        }
    }
}
