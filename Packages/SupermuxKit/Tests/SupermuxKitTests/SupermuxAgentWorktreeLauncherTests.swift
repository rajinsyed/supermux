import Foundation
import Testing
@testable import SupermuxKit

/// The shared "start Claude in a new worktree" path: names from the prompt
/// (AI when it answers, heuristic otherwise), a real worktree through the
/// projects model, remembered command/model/effort, and an open request that
/// runs the Claude command in the new workspace.
// Serialized: shells out to real `git`.
@Suite(.serialized)
@MainActor
struct SupermuxAgentWorktreeLauncherTests {
    private struct Fixture {
        let root: String
        let storeDirectory: URL
        let project: SupermuxProject
        let model: SupermuxProjectsModel
        let defaults: UserDefaults

        func cleanUp() {
            GitFixture.cleanUp(root)
            try? FileManager.default.removeItem(at: storeDirectory)
        }
    }

    private func makeFixture(setupCommands: [String] = []) async throws -> Fixture {
        let root = try GitFixture.makeFixtureRepo(prefix: "supermux-agent-launch")
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-agent-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        var project = SupermuxProject(name: "Fixture", rootPath: root)
        project.setupCommands = setupCommands
        let store = SupermuxProjectStore(fileURL: storeDirectory.appendingPathComponent("projects.json"))
        try await store.save(SupermuxProjectsFile(
            version: SupermuxProjectsFile.currentVersion,
            projects: [project],
            isSectionCollapsed: false
        ))
        let model = SupermuxProjectsModel(store: store, worktreeService: SupermuxGitWorktreeService())
        await model.loadIfNeeded()
        let suite = "SupermuxAgentWorktreeLauncherTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return Fixture(root: root, storeDirectory: storeDirectory, project: project, model: model, defaults: defaults)
    }

    @Test func aiNamesWinAndTheOpenRequestRunsTheCommand() async throws {
        let fixture = try await makeFixture(setupCommands: ["bun install"])
        defer { fixture.cleanUp() }
        let settings = SupermuxAgentLauncherSettings(defaults: fixture.defaults)
        settings.setCommands(["claude", "cc"])
        let namer = StubWorktreeNamer(names: SupermuxPromptNames(workspaceName: "Fix Login Redirect", branchName: "fix-login-redirect"))
        let launcher = SupermuxAgentWorktreeLauncher(projectsModel: fixture.model, namer: namer, settings: settings)

        let launch = try await launcher.start(SupermuxAgentLaunchRequest(
            projectId: fixture.project.id,
            prompt: "  the login redirect is broken\n",
            command: "cc",
            model: "opus",
            effort: "high",
            preservesUserFocus: true
        ))

        #expect(launch.namedByAI)
        #expect(launch.names == SupermuxPromptNames(workspaceName: "Fix Login Redirect", branchName: "fix-login-redirect"))
        #expect(launch.worktree.branch == "fix-login-redirect")
        #expect(launch.openRequest.title == "Fix Login Redirect")
        #expect(launch.openRequest.directory == launch.worktree.path)
        #expect(launch.openRequest.projectId == fixture.project.id)
        #expect(launch.openRequest.initialCommand == "cc --model 'opus' --effort 'high' -- $'the login redirect is broken'")
        #expect(launch.openRequest.setupScript == "bun install")
        #expect(launch.openRequest.setupEnvironment["SUPERMUX_WORKTREE_PATH"] == launch.worktree.path)
        #expect(launch.openRequest.preservesUserFocus)
        #expect(settings.selectedCommand == "cc")
        #expect(settings.lastChoice(for: "cc") == ("opus", "high"))
        #expect((fixture.model.worktreesByProjectId[fixture.project.id] ?? []).contains { $0.path == launch.worktree.path })
    }

    @Test func fallsBackToHeuristicNamesWhenAIIsSilent() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let launcher = SupermuxAgentWorktreeLauncher(
            projectsModel: fixture.model,
            namer: StubWorktreeNamer(names: nil),
            settings: SupermuxAgentLauncherSettings(defaults: fixture.defaults)
        )
        let launch = try await launcher.start(SupermuxAgentLaunchRequest(
            projectId: fixture.project.id,
            prompt: "Add retry to the uploader",
            command: "claude"
        ))
        #expect(!launch.namedByAI)
        #expect(launch.names.workspaceName == "Add Retry Uploader")
        #expect(launch.worktree.branch == "add-retry-uploader")
        #expect(launch.openRequest.initialCommand == "claude -- $'Add retry to the uploader'")
        #expect(launch.openRequest.setupScript == nil)
    }

    /// The launch line is quoted for the shell the new terminal will run.
    @Test func quotesTheLaunchLineForTheUsersShell() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let launcher = SupermuxAgentWorktreeLauncher(
            projectsModel: fixture.model,
            namer: nil,
            settings: SupermuxAgentLauncherSettings(defaults: fixture.defaults),
            shell: .fish
        )
        let launch = try await launcher.start(SupermuxAgentLaunchRequest(
            projectId: fixture.project.id, prompt: "Add retry\nit's flaky", command: "claude"
        ))
        #expect(launch.openRequest.initialCommand == "claude -- 'Add retry'\\n'it\\'s flaky'")
        #expect(launcher.shellLine(command: "claude", model: nil, effort: nil, prompt: "x") == "claude -- 'x'")
    }

    @Test func typedNamesWinOverDerivedOnes() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let namer = StubWorktreeNamer(names: SupermuxPromptNames(workspaceName: "AI Title", branchName: "ai-branch"))
        let launcher = SupermuxAgentWorktreeLauncher(
            projectsModel: fixture.model,
            namer: namer,
            settings: SupermuxAgentLauncherSettings(defaults: fixture.defaults)
        )
        // Only the branch typed: the title still comes from AI.
        let partial = try await launcher.start(SupermuxAgentLaunchRequest(
            projectId: fixture.project.id, prompt: "fix the thing", command: "claude", branchName: " my-branch "
        ))
        #expect(partial.names == SupermuxPromptNames(workspaceName: "AI Title", branchName: "my-branch"))
        #expect(partial.namedByAI)
        #expect(partial.worktree.branch == "my-branch")
        // Both typed: AI is not consulted at all.
        let full = try await launcher.start(SupermuxAgentLaunchRequest(
            projectId: fixture.project.id, prompt: "fix the thing", command: "claude",
            workspaceName: "Typed Title", branchName: "typed-branch"
        ))
        #expect(full.names == SupermuxPromptNames(workspaceName: "Typed Title", branchName: "typed-branch"))
        #expect(!full.namedByAI)
        #expect(full.openRequest.title == "Typed Title")
    }

    @Test func fillerOnlyPromptStillGetsAWorktree() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let launcher = SupermuxAgentWorktreeLauncher(
            projectsModel: fixture.model,
            namer: nil,
            settings: SupermuxAgentLauncherSettings(defaults: fixture.defaults)
        )
        let launch = try await launcher.start(SupermuxAgentLaunchRequest(
            projectId: fixture.project.id, prompt: "please just do it", command: "claude"
        ))
        #expect(launch.names.workspaceName == "please just do it")
        #expect(launch.worktree.branch?.isEmpty == false, "the service picks a random branch name")
        #expect(launch.names.branchName == launch.worktree.branch)
    }

    @Test func rejectsBlankPromptAndUnknownProjectBeforeGit() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let launcher = SupermuxAgentWorktreeLauncher(
            projectsModel: fixture.model,
            namer: nil,
            settings: SupermuxAgentLauncherSettings(defaults: fixture.defaults)
        )
        await #expect(throws: SupermuxAgentLaunchError.emptyPrompt) {
            try await launcher.start(SupermuxAgentLaunchRequest(projectId: fixture.project.id, prompt: " \n", command: "claude"))
        }
        await #expect(throws: SupermuxAgentLaunchError.unknownProject) {
            try await launcher.start(SupermuxAgentLaunchRequest(projectId: UUID(), prompt: "x", command: "claude"))
        }
        #expect((fixture.model.worktreesByProjectId[fixture.project.id] ?? []).isEmpty)
    }
}

private struct StubWorktreeNamer: SupermuxAIWorktreeNaming {
    let names: SupermuxPromptNames?
    func isConfigured() async -> Bool { names != nil }
    func suggestNames(forPrompt prompt: String) async -> SupermuxPromptNames? { names }
}
