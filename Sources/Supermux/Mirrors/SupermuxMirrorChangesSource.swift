import Foundation
import Observation
import SupermuxKit

/// Decides which Changes model one window's panel shows: the window's local
/// model for a local workspace, or a remote model — git on the owning Mac —
/// while a device mirror is selected.
///
/// Re-resolves on selection changes (``track(_:)``) and on every device
/// revision (records arrive after the mirror opens; the remote directory can
/// change), but republishes ``target`` / ``remoteModel`` only when they
/// actually change, so the panel is not invalidated per catalog tick.
@MainActor
@Observable
final class SupermuxMirrorChangesSource {
    /// The selected mirror, or `nil` while a local workspace is selected.
    private(set) var target: SupermuxMirrorTarget?
    /// The selected mirror's Changes model (one per remote workspace).
    private(set) var remoteModel: SupermuxChangesModel?

    @ObservationIgnored private let resolver: SupermuxMirrorResolver
    @ObservationIgnored private let devices: SupermuxDevices
    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private var revisionTask: Task<Void, Never>?

    init(resolver: SupermuxMirrorResolver, devices: SupermuxDevices) {
        self.resolver = resolver
        self.devices = devices
    }

    deinit {
        revisionTask?.cancel()
    }

    /// Follows the window's selected workspace.
    func track(_ workspace: Workspace?) {
        self.workspace = workspace
        startFollowingRevisions()
        resolve()
    }

    /// The Changes model for a mirror (remote backend + remote AI commit).
    static func makeModel(for target: SupermuxMirrorTarget, devices: SupermuxDevices) -> SupermuxChangesModel {
        let backend = SupermuxRemoteChangesBackend(
            transport: SupermuxDeviceChangesTransport(target: target, devices: devices)
        )
        let model = SupermuxChangesModel(backend: backend, commitGenerator: SupermuxRemoteCommitMessenger(backend: backend))
        model.setDirectory(target.remoteDirectory ?? "/")
        return model
    }

    private func resolve() {
        let next = resolver.target(for: workspace)
        guard next != target else { return }
        let previous = target
        target = next
        guard let next else {
            remoteModel = nil
            return
        }
        if previous?.ref != next.ref || remoteModel == nil {
            remoteModel = Self.makeModel(for: next, devices: devices)
        } else if let directory = next.remoteDirectory {
            remoteModel?.setDirectory(directory)
        }
    }

    private func startFollowingRevisions() {
        guard revisionTask == nil else { return }
        revisionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let devices = self?.devices else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = devices.revision
                    } onChange: {
                        continuation.resume()
                    }
                }
                // onChange fires at willSet: let the bump land first.
                await Task.yield()
                self?.resolve()
            }
        }
    }
}
