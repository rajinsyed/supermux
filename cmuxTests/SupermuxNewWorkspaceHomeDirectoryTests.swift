import XCTest
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the supermux `new-workspace-home-dir` touchpoint.
///
/// Bug: with "Inherit Workspace Working Directory" turned OFF, a workspace
/// created from the sidebar empty-area double-click or the sidebar `+` button
/// still opened in the focused workspace's directory.
///
/// Root cause: `implicitWorkingDirectoryForNewWorkspace` returned nil when the
/// setting is off, the new terminal surface then spawned with no explicit cwd,
/// and Ghostty's own `tab-inherit-working-directory` (default on) reused the
/// focused surface's pwd — reintroducing exactly the inheritance the setting
/// disables. The fix pins the home directory explicitly instead of nil.
@MainActor
final class SupermuxNewWorkspaceHomeDirectoryTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SupermuxNewWorkspaceHomeDirectoryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeManager() -> TabManager {
        TabManager(
            autoWelcomeIfNeeded: false,
            settings: UserDefaultsSettingsClient(defaults: defaults)
        )
    }

    private var inheritSettingKey: String {
        SettingCatalog().app.workspaceInheritWorkingDirectory.userDefaultsKey
    }

    func testInheritDisabledPinsNewWorkspaceToHomeDirectory() throws {
        defaults.set(false, forKey: inheritSettingKey)
        let manager = makeManager()
        let source = try XCTUnwrap(manager.selectedWorkspace)
        source.currentDirectory = "/private/tmp"

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            manager.implicitWorkingDirectoryForNewWorkspace(from: source),
            home,
            "With inheritance off the new workspace must be pinned to the home directory; a nil directory lets Ghostty's tab-inherit-working-directory reuse the focused surface's cwd."
        )

        let workspace = manager.addWorkspace(autoWelcomeIfNeeded: false)
        let terminal = try XCTUnwrap(
            workspace.panels.values.compactMap { $0 as? TerminalPanel }.first,
            "Expected the new workspace to boot with a terminal panel."
        )
        XCTAssertEqual(
            terminal.requestedWorkingDirectory,
            home,
            "The initial terminal surface must request the home directory explicitly so Ghostty-level inheritance cannot kick in."
        )
    }

    // The end-to-end inherit-ON contract is unchanged upstream behavior and is
    // already covered by WorkspaceUnitTests'
    // testNewWorkspaceInheritsSourceWorkingDirectoryByDefault; assert only the
    // helper here so the fenced home-directory return can't overshoot into the
    // ON path.
    func testInheritEnabledUsesFocusedWorkspaceDirectory() throws {
        defaults.set(true, forKey: inheritSettingKey)
        let manager = makeManager()
        let source = try XCTUnwrap(manager.selectedWorkspace)
        source.currentDirectory = "/private/tmp"

        XCTAssertEqual(
            manager.implicitWorkingDirectoryForNewWorkspace(from: source),
            "/private/tmp"
        )
    }
}
