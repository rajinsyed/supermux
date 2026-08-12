import Foundation
import SupermuxClaudeHarness
import Testing
@testable import SupermuxKit

/// View-model session identity: the registry key must equal the persisted
/// record key, or the phone cannot see desktop sessions (and a phone-side
/// resume would spawn a second child for the same provider session).
@MainActor
struct SupermuxHarnessViewModelTests {
    /// A fake child that auto-acknowledges every outbound control, so
    /// `loadModels()` resolves immediately instead of waiting out the
    /// multiplexer timeout.
    final class AutoRespondingProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<ClaudeProcessEvent>.Continuation?

        func handle() -> ClaudeProcessHandle {
            let (events, continuation) = AsyncStream<ClaudeProcessEvent>.makeStream()
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            return ClaudeProcessHandle(
                events: events,
                writeStdin: { [weak self] data in
                    self?.autoRespond(to: data)
                },
                closeStdin: { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let continuation = self.continuation
                    self.continuation = nil
                    self.lock.unlock()
                    continuation?.yield(.exited(status: 0))
                    continuation?.finish()
                },
                terminate: {},
                kill: {}
            )
        }

        private func autoRespond(to data: Data) {
            guard
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["type"] as? String == "control_request",
                let requestID = object["request_id"] as? String
            else { return }
            let response = #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(requestID)","response":{}}}"#
            lock.lock()
            let continuation = self.continuation
            lock.unlock()
            continuation?.yield(.stdoutLine(Data(response.utf8)))
        }
    }

    struct AutoRespondingRunner: ClaudeProcessRunning {
        let process: AutoRespondingProcess

        func run(
            executablePath: String,
            arguments: [String],
            workingDirectory: String?,
            environment: [String: String]?
        ) throws -> ClaudeProcessHandle {
            process.handle()
        }
    }

    private func temporaryBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeModel(
        registry: ClaudeSessionRegistry,
        store: SupermuxHarnessSessionStore,
        panelID: UUID = UUID()
    ) -> SupermuxHarnessViewModel {
        let model = SupermuxHarnessViewModel(
            panelID: panelID,
            workingDirectory: "/tmp",
            registry: registry,
            store: store
        )
        model.setLauncher(ClaudeLauncher(
            kind: .claude, executablePath: "/fake/claude", displayName: "fake"
        ))
        return model
    }

    @Test func startKeysTheRegistryByTheStableSurfaceID() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = ClaudeSessionRegistry(
            runner: AutoRespondingRunner(process: AutoRespondingProcess())
        )
        let store = SupermuxHarnessSessionStore(baseDirectory: base)
        let model = makeModel(registry: registry, store: store)

        let stableSurfaceID = UUID()
        await model.adopt(stableSurfaceID: stableSurfaceID)
        await model.start()

        // Registry key == persisted record key: this is what lets the mobile
        // host find the live session for a record, and what makes a resume
        // request attach instead of double-spawning.
        #expect(registry.sessionIDs == [stableSurfaceID])
        #expect(registry.session(id: stableSurfaceID) != nil)
        #expect(await store.load(stableSurfaceID: stableSurfaceID) != nil)
        await registry.removeAll()
    }

    @Test func startFallsBackToThePanelIDWithoutAStableSurfaceID() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = ClaudeSessionRegistry(
            runner: AutoRespondingRunner(process: AutoRespondingProcess())
        )
        let store = SupermuxHarnessSessionStore(baseDirectory: base)
        let panelID = UUID()
        let model = makeModel(registry: registry, store: store, panelID: panelID)

        await model.start()

        #expect(registry.sessionIDs == [panelID])
        await registry.removeAll()
    }

    @Test func startAttachesToALiveSessionUnderTheSameKey() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = ClaudeSessionRegistry(
            runner: AutoRespondingRunner(process: AutoRespondingProcess())
        )
        let store = SupermuxHarnessSessionStore(baseDirectory: base)
        let stableSurfaceID = UUID()

        // The phone resumed this panel's session while the desktop showed the
        // setup form: a live session already sits under the panel's key.
        let launcher = ClaudeLauncher(
            kind: .claude, executablePath: "/fake/claude", displayName: "fake"
        )
        _ = try await registry.create(configuration: ClaudeSessionConfiguration(
            id: stableSurfaceID,
            launcher: launcher,
            workingDirectory: "/tmp",
            identity: .new(sessionID: UUID().uuidString.lowercased())
        ))

        let model = makeModel(registry: registry, store: store)
        await model.adopt(stableSurfaceID: stableSurfaceID)
        await model.start()

        // Attached, not duplicated, and not a startup error.
        #expect(registry.sessionIDs == [stableSurfaceID])
        #expect(model.phase == .session)
        #expect(model.startupError == nil)
        await registry.removeAll()
    }
}
