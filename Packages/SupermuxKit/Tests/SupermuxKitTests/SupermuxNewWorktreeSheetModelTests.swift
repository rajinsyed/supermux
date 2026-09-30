import Foundation
import SupermuxMobileCore
import Testing

@testable import SupermuxKit

/// Ways the device-aware New Worktree sheet could misbehave (written before
/// the sheet model existed; the view only renders this model):
/// 1. Switching Mac drops the typed prompt, workspace name or branch.
/// 2. A branch list requested for the previous Mac lands after a switch and
///    replaces the new Mac's list.
/// 3. A starting branch picked on one Mac carries over to another Mac.
/// 4. Create / Start goes to the previously selected Mac, or sends this Mac's
///    project id to another Mac.
/// 5. Choosing an offline Mac or a "Set Up on <Mac>…" entry changes the create
///    target (set-up must only hand off to the setup sheet).
/// 6. Switching Mac while a create runs changes the target mid-flight.
/// 7. A successful create does not remember the Mac, or a failed one does.
/// 8. Another Mac's Claude commands are never loaded (the sheet keeps offering
///    this Mac's list), or switching back loses this Mac's list.
/// 9. The plain path asks for an AI branch although the branch was typed.
/// 10. A create on another Mac shows no "Creating on <Mac>…" progress, and a
///     failure there leaves the sheet stuck busy.
@MainActor
struct SupermuxNewWorktreeSheetModelTests {
    private let studio = SupermuxProjectDevice(machineID: "device:aaaa@default", name: "Studio", isOnline: true)
    private let air = SupermuxProjectDevice(machineID: "device:cccc@default", name: "Air", isOnline: false)
    private let unifiedID = UUID()
    private let localProjectID = UUID()
    private let studioProjectID = UUID()

    private struct Fixture {
        let model: SupermuxNewWorktreeSheetModel
        let local: FakeWorktreeTarget
        let remote: FakeWorktreeTarget
        let store: SupermuxWorktreeLastDeviceStore
        let setUps: SetUpRecorder
    }

    @MainActor final class SetUpRecorder {
        var destinations: [SupermuxProjectSetupDestination] = []
    }

    private func makeFixture(lastUsed: String? = nil) throws -> Fixture {
        let suite = "SupermuxNewWorktreeSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = SupermuxWorktreeLastDeviceStore(defaults: defaults)
        if let lastUsed { store.record(deviceKey: lastUsed, forProject: unifiedID) }
        let project = SupermuxUnifiedProject(
            id: unifiedID,
            name: "app",
            colorHex: nil,
            iconSymbol: nil,
            gitRemoteIdentity: nil,
            locations: [
                SupermuxProjectLocation(place: .thisMac, projectID: localProjectID, rootPath: "/src/app"),
                SupermuxProjectLocation(place: .device(studio), projectID: studioProjectID, rootPath: "/src/app"),
                SupermuxProjectLocation(place: .device(air), projectID: UUID(), rootPath: "/src/app"),
            ]
        )
        let entries = SupermuxWorktreeDevicePlanner.entries(
            for: project,
            availability: [:],
            setUpTargets: [.device(SupermuxProjectDevice(machineID: "device:dddd@default", name: "Mini", isOnline: true))]
        )
        let local = FakeWorktreeTarget(projectID: localProjectID, remoteDeviceName: nil)
        local.configuredDefaultBranch = "main"
        local.branches = ["main", "dev"]
        local.commandList = SupermuxAgentCommandList(commands: ["claude", "cc"], selected: "cc")
        let remote = FakeWorktreeTarget(projectID: studioProjectID, remoteDeviceName: "Studio")
        remote.configuredDefaultBranch = "trunk"
        remote.branches = ["trunk", "feature"]
        remote.commandList = SupermuxAgentCommandList(commands: [], selected: "")
        remote.remoteCommands = SupermuxAgentCommandList(commands: ["ccx"], selected: "ccx")
        let setUps = SetUpRecorder()
        let model = SupermuxNewWorktreeSheetModel(
            projectID: unifiedID,
            entries: entries,
            initialEntryID: SupermuxWorktreeDevicePlanner.defaultEntryID(
                in: entries,
                preferredDeviceKey: nil,
                lastUsedDeviceKey: store.deviceKey(forProject: unifiedID)
            ),
            makeTarget: { location in location.isThisMac ? local : (location.machineID == "device:aaaa@default" ? remote : nil) },
            lastDevices: store,
            onSetUp: { setUps.destinations.append($0) }
        )
        return Fixture(model: model, local: local, remote: remote, store: store, setUps: setUps)
    }

    private func finish(_ task: Task<Void, Never>?) async {
        await task?.value
    }

    @Test func defaultsToTheLastUsedMacAndLoadsItsBranches() async throws {
        let fixture = try makeFixture(lastUsed: "device:aaaa@default")
        #expect(fixture.model.selectedEntryID == "device:aaaa@default")
        #expect(fixture.model.target === fixture.remote)
        #expect(fixture.model.baseBranch == "trunk")
        await fixture.model.load()
        #expect(fixture.model.localBranches == ["trunk", "feature"])
        #expect(fixture.model.commands == ["ccx"])
        #expect(fixture.model.command == "ccx")
    }

    @Test func switchingMacKeepsTypedTextAndResetsPerMacState() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        #expect(model.target === fixture.local)
        await model.load()
        #expect(model.commands == ["claude", "cc"])
        model.prompt = "Fix the login bug"
        model.workspaceName = "login"
        model.branchInput = "fix/login"
        model.baseBranch = "dev"
        model.baseBranchWasEdited = true
        model.selectEntry(id: "device:aaaa@default")
        #expect(model.target === fixture.remote)
        #expect(model.prompt == "Fix the login bug")
        #expect(model.workspaceName == "login")
        #expect(model.branchInput == "fix/login")
        #expect(model.baseBranch == "trunk")
        #expect(model.baseBranchWasEdited == false)
        await model.load()
        #expect(model.localBranches == ["trunk", "feature"])
        #expect(model.commands == ["ccx"])
        model.selectEntry(id: SupermuxWorktreeDeviceEntry.thisMacKey)
        #expect(model.commands == ["claude", "cc"])
        #expect(model.command == "cc")
    }

    @Test func staleBranchListFromThePreviousMacIsDropped() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let gate = FakeGate()
        fixture.local.branchGate = gate
        let slowLoad = Task { await model.loadBranches() }
        await gate.waitUntilEntered()
        model.selectEntry(id: "device:aaaa@default")
        await model.loadBranches()
        gate.open()
        await slowLoad.value
        #expect(model.localBranches == ["trunk", "feature"])
        #expect(model.target === fixture.remote)
    }

    @Test func offlineMacsAndSetUpEntriesNeverBecomeTheTarget() throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.selectEntry(id: "device:cccc@default")
        #expect(model.target === fixture.local)
        let setUp = try #require(model.entries.first { $0.setUpDestination != nil })
        model.selectEntry(id: setUp.id)
        #expect(model.target === fixture.local)
        #expect(fixture.setUps.destinations == [setUp.setUpDestination].compactMap { $0 })
    }

    @Test func plainCreateGoesToTheSelectedMacAndRemembersIt() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.selectEntry(id: "device:aaaa@default")
        await model.load()
        model.workspaceName = "  login  "
        model.branchInput = "fix/login"
        var finished = false
        await finish(model.submit { finished = true })
        #expect(finished)
        #expect(fixture.local.createdRequests.isEmpty)
        #expect(fixture.remote.createdRequests.count == 1)
        let request = try #require(fixture.remote.createdRequests.first)
        #expect(request.branchName == "fix/login")
        #expect(request.baseBranch == nil)
        #expect(request.workspaceName == "login")
        #expect(fixture.remote.suggestCalls == 0)
        #expect(fixture.store.deviceKey(forProject: unifiedID) == "device:aaaa@default")
    }

    @Test func blankBranchAsksThatMacForAnAIName() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.selectEntry(id: "device:aaaa@default")
        fixture.remote.aiConfigured = true
        fixture.remote.suggestion = "fix-login-flow"
        model.workspaceName = "Fix login"
        await finish(model.submit {})
        #expect(fixture.remote.suggestCalls == 1)
        #expect(fixture.remote.createdRequests.first?.branchName == "fix-login-flow")
    }

    @Test func promptStartUsesThatMacsProjectAndShowsProgress() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.selectEntry(id: "device:aaaa@default")
        await model.load()
        model.prompt = "Add dark mode"
        let gate = FakeGate()
        fixture.remote.startGate = gate
        let task = model.submit {}
        await gate.waitUntilEntered()
        #expect(model.phase == .runningGit)
        #expect(model.statusMessage?.contains("Studio") == true)
        // A switch mid-flight is refused.
        model.selectEntry(id: SupermuxWorktreeDeviceEntry.thisMacKey)
        #expect(model.target === fixture.remote)
        gate.open()
        await finish(task)
        let request = try #require(fixture.remote.startedRequests.first)
        #expect(request.projectId == studioProjectID)
        #expect(request.command == "ccx")
        #expect(request.prompt == "Add dark mode")
        #expect(fixture.local.startedRequests.isEmpty)
    }

    @Test func failedCreateIsReportedAndNotRemembered() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.selectEntry(id: "device:aaaa@default")
        fixture.remote.createError = FakeFailure(message: "Studio is offline.")
        var finished = false
        await finish(model.submit { finished = true })
        #expect(!finished)
        #expect(model.phase == .idle)
        #expect(model.errorMessage == "Studio is offline.")
        #expect(fixture.store.deviceKey(forProject: unifiedID) == nil)
    }

    @Test func thisMacOnlyProjectHidesThePicker() throws {
        let project = SupermuxUnifiedProject(
            id: unifiedID, name: "solo", colorHex: nil, iconSymbol: nil, gitRemoteIdentity: nil,
            locations: [SupermuxProjectLocation(place: .thisMac, projectID: localProjectID, rootPath: "/src/solo")]
        )
        let local = FakeWorktreeTarget(projectID: localProjectID, remoteDeviceName: nil)
        let entries = SupermuxWorktreeDevicePlanner.entries(for: project, availability: [:], setUpTargets: [])
        let model = SupermuxNewWorktreeSheetModel(
            projectID: unifiedID,
            entries: entries,
            initialEntryID: entries.first?.id,
            makeTarget: { _ in local }
        )
        #expect(!model.showsDevicePicker)
        #expect(model.target === local)
    }
}

// MARK: - Fakes

struct FakeFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Holds an async call until the test opens it.
@MainActor final class FakeGate {
    private var entered = false
    private var isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        openWaiters.forEach { $0.resume() }
        openWaiters = []
    }
}

@MainActor final class FakeWorktreeTarget: SupermuxWorktreeCreationTarget {
    struct CreateRequest {
        let branchName: String
        let baseBranch: String?
        let workspaceName: String?
    }

    let projectID: UUID
    let remoteDeviceName: String?
    var configuredDefaultBranch: String?
    var branches: [String] = []
    var branchGate: FakeGate?
    var aiConfigured = false
    var suggestion: String?
    var suggestCalls = 0
    var createError: (any Error)?
    var createdRequests: [CreateRequest] = []
    var startedRequests: [SupermuxAgentLaunchRequest] = []
    var startGate: FakeGate?
    var commandList = SupermuxAgentCommandList(commands: [], selected: "")
    var remoteCommands: SupermuxAgentCommandList?

    init(projectID: UUID, remoteDeviceName: String?) {
        self.projectID = projectID
        self.remoteDeviceName = remoteDeviceName
    }

    func loadBranches() async throws -> [String] {
        await branchGate?.pass()
        return branches
    }

    func isAINamingConfigured() async -> Bool { aiConfigured }
    func isAIBranchNamingConfigured() async -> Bool { aiConfigured }

    func suggestBranchName(forWorkspaceName name: String) async -> String? {
        suggestCalls += 1
        return suggestion
    }

    func createWorktree(branchName: String, baseBranch: String?, workspaceName: String?) async throws {
        if let createError { throw createError }
        createdRequests.append(CreateRequest(branchName: branchName, baseBranch: baseBranch, workspaceName: workspaceName))
    }

    var supportsAgentLaunch: Bool { true }
    var canEditAgentCommands: Bool { remoteDeviceName == nil }
    var initialAgentCommands: SupermuxAgentCommandList { commandList }

    func setAgentCommands(_ commands: [String]) -> SupermuxAgentCommandList {
        commandList = SupermuxAgentCommandList(commands: commands, selected: commands.first ?? "")
        return commandList
    }

    func rememberAgentCommand(_ command: String) {}

    func agentOptions(for command: String, forceRefresh: Bool) async -> SupermuxAgentLaunchOptionsDTO {
        let list = remoteCommands ?? commandList
        return SupermuxAgentLaunchOptionsDTO(
            commands: list.commands,
            selectedCommand: command.isEmpty ? list.selected : command,
            models: [],
            modelsSource: .cache
        )
    }

    func shellLinePreview(command: String, model: String?, effort: String?, prompt: String) -> String? {
        remoteDeviceName == nil ? "\(command) \(prompt)" : nil
    }

    func startAgent(
        _ request: SupermuxAgentLaunchRequest,
        willCreateWorktree: @escaping @MainActor () -> Void
    ) async throws {
        willCreateWorktree()
        await startGate?.pass()
        if let createError { throw createError }
        startedRequests.append(request)
    }
}
