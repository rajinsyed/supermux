import Foundation

/// The live Changes-panel mounts' mirror sources (held weakly), so the E2E
/// socket can inspect the exact model a window's panel is showing.
@MainActor
final class SupermuxMirrorChangesPanels {
    private let table = NSHashTable<SupermuxMirrorChangesSource>.weakObjects()

    /// Registers a mount's source (dropped automatically when it goes away).
    func insert(_ source: SupermuxMirrorChangesSource) {
        table.add(source)
    }

    /// The source of a mounted panel currently showing the given mirror.
    func source(showing localWorkspaceID: UUID) -> SupermuxMirrorChangesSource? {
        table.allObjects.first { $0.target?.localWorkspaceID == localWorkspaceID && $0.remoteModel != nil }
    }
}
