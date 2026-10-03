import Foundation
import SupermuxKit

/// The device-link side of a mirror's remote Changes backend: RPCs go to the
/// owning Mac through the device facade, and that Mac's
/// `supermux.changes.updated` pokes for this workspace (plus link
/// reconnects) become change events.
@MainActor
final class SupermuxDeviceChangesTransport: SupermuxRemoteChangesTransport {
    let remoteWorkspaceID: String
    private let target: SupermuxMirrorTarget
    private let devices: SupermuxDevices

    init(target: SupermuxMirrorTarget, devices: SupermuxDevices) {
        self.target = target
        self.remoteWorkspaceID = target.remoteWorkspaceID
        self.devices = devices
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        try await devices.request(method, params: params, on: target.machine)
    }

    func errorCode(_ error: any Error) -> String? {
        (error as? SupermuxDeviceError)?.code
    }

    func events() -> AsyncStream<SupermuxRemoteChangesEvent> {
        let source = devices.events()
        let machine = target.machine
        let workspaceID = target.ref.workspaceID
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task { @MainActor in
                for await event in source where event.machine == machine {
                    switch event {
                    case .linkConnected:
                        continuation.yield(.reconnected)
                    case .topic(_, .changesUpdated, _):
                        let raw = event.payloadObject?["workspace_id"] as? String
                        if raw.map(SupermuxRemoteWorkspaceRef.canonicalWorkspaceID) == workspaceID {
                            continuation.yield(.changed)
                        }
                    default:
                        continue
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
