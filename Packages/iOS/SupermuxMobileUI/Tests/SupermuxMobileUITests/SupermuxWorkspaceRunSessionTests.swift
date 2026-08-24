import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

@MainActor
@Suite struct SupermuxWorkspaceRunSessionTests {
    private let wait = TestWait()

    private static let projectID = "11111111-1111-1111-1111-111111111111"
    private static let capabilities: Set<String> = [
        SupermuxMobileCapability.projectsV1.rawValue,
        SupermuxMobileCapability.runV1.rawValue,
    ]

    @Test func entryUsesAuthoritativeCommandsAndPreservesTheirWireIndexes() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [
            Self.project(runCommands: ["npm run web", "   ", "npm run api"]),
        ])
        let session = SupermuxWorkspaceRunSession()
        let task = run(session, client: client)
        defer {
            task.cancel()
            client.finishEventStreams()
        }

        try await wait.until { session.showsEntry(forProjectID: Self.projectID) }
        let state = try #require(session.menuState(forProjectID: Self.projectID))

        #expect(state.commands.map(\.id) == [0, 2])
        #expect(state.commands.map(\.title) == ["npm run web", "npm run api"])
        #expect(!state.isRunning)
    }

    @Test func entryWaitsForAuthoritativeRunStateBeforeRendering() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [Self.project()])
        client.runStateResponse = SupermuxRunStateResponse(runs: [
            SupermuxRunStateDTO(projectId: Self.projectID, isRunning: true),
        ])
        client.runStateShouldHold = true
        let session = SupermuxWorkspaceRunSession()
        let task = run(session, client: client)
        defer {
            client.runStateShouldHold = false
            client.resumeRunState()
            task.cancel()
            client.finishEventStreams()
        }

        try await wait.until {
            session.hasLoadedProjects && client.runStateCallCount == 1
        }

        #expect(!session.showsEntry(forProjectID: Self.projectID))

        client.runStateShouldHold = false
        client.resumeRunState()
        try await wait.until { session.showsEntry(forProjectID: Self.projectID) }
        #expect(session.menuState(forProjectID: Self.projectID)?.isRunning == true)
    }

    @Test func entryStaysHiddenWithoutANonblankRunCommand() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [
            Self.project(runCommands: ["", "   "]),
        ])
        let session = SupermuxWorkspaceRunSession()
        let task = run(session, client: client)
        defer {
            task.cancel()
            client.finishEventStreams()
        }

        try await wait.until { session.hasLoadedProjects }

        #expect(!session.showsEntry(forProjectID: Self.projectID))
        #expect(session.menuIdentityToken(forProjectID: Self.projectID) == "hidden")
    }

    @Test func staleActionCompletionCannotMutateAReplacementSession() async throws {
        let oldClient = FakeSupermuxMacClient()
        oldClient.listResponse = SupermuxProjectsListResponse(projects: [Self.project()])
        oldClient.runStartShouldHold = true
        let session = SupermuxWorkspaceRunSession()
        let oldSessionTask = run(
            session,
            client: oldClient,
            connectionID: "old-connection"
        )
        defer {
            oldClient.runStartShouldHold = false
            oldClient.resumeRunStart()
            oldSessionTask.cancel()
            oldClient.finishEventStreams()
        }

        try await wait.until { session.showsEntry(forProjectID: Self.projectID) }
        let oldAction = Task {
            await session.startRun(projectID: Self.projectID, commandID: nil)
        }
        try await wait.until { oldClient.runStartCallCount == 1 }

        oldSessionTask.cancel()
        oldClient.finishEventStreams()
        let newClient = FakeSupermuxMacClient()
        newClient.listResponse = SupermuxProjectsListResponse(projects: [
            Self.project(runCommands: ["npm run next"]),
        ])
        newClient.runStartShouldHold = true
        let newSessionTask = run(
            session,
            client: newClient,
            connectionID: "new-connection"
        )
        defer {
            newClient.runStartShouldHold = false
            newClient.resumeRunStart()
            newSessionTask.cancel()
            newClient.finishEventStreams()
        }

        try await wait.until {
            session.menuState(forProjectID: Self.projectID)?.commands.first?.title
                == "npm run next"
        }
        let newAction = Task {
            await session.startRun(projectID: Self.projectID, commandID: nil)
        }
        try await wait.until { newClient.runStartCallCount == 1 }
        #expect(session.menuState(forProjectID: Self.projectID)?.isBusy == true)

        oldClient.runStartError = FakeSupermuxMacClientError.unscriptedIconRequest
        oldClient.runStartShouldHold = false
        oldClient.resumeRunStart()
        #expect(await oldAction.value == false)
        #expect(session.actionErrorDescription == nil)
        #expect(session.menuState(forProjectID: Self.projectID)?.isBusy == true)

        newClient.runStartShouldHold = false
        newClient.resumeRunStart()
        #expect(await newAction.value)
        #expect(session.menuState(forProjectID: Self.projectID)?.isBusy == false)
    }

    @Test func startAndStopUseTheSharedRunStoreAndRefreshMenuIdentity() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [Self.project()])
        client.runStateResponse = SupermuxRunStateResponse(runs: [
            SupermuxRunStateDTO(projectId: Self.projectID, isRunning: false),
        ])
        let session = SupermuxWorkspaceRunSession()
        let task = run(session, client: client)
        defer {
            task.cancel()
            client.finishEventStreams()
        }

        try await wait.until { session.showsEntry(forProjectID: Self.projectID) }
        let stoppedToken = session.menuIdentityToken(forProjectID: Self.projectID)

        #expect(await session.startRun(projectID: Self.projectID, commandID: nil))
        #expect(session.menuState(forProjectID: Self.projectID)?.isRunning == true)
        #expect(session.menuIdentityToken(forProjectID: Self.projectID) != stoppedToken)
        #expect(client.recordedWireCalls.last?.method == "mobile.supermux.run.start")

        #expect(await session.stopRun(projectID: Self.projectID))
        #expect(session.menuState(forProjectID: Self.projectID)?.isRunning == false)
        #expect(client.recordedWireCalls.last?.method == "mobile.supermux.run.stop")
    }

    private func run(
        _ session: SupermuxWorkspaceRunSession,
        client: FakeSupermuxMacClient,
        connectionID: String = "test-connection"
    ) -> Task<Void, Never> {
        Task {
            await session.runSession(
                client: client,
                hostCapabilities: Self.capabilities,
                connectionID: connectionID
            )
        }
    }

    private static func project(runCommands: [String]? = ["npm run dev"]) -> SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: projectID,
            name: "Alpha",
            rootPath: "/Users/dev/alpha",
            runCommands: runCommands
        )
    }
}
