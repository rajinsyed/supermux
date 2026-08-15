// SUPERMUX:begin simulator-stream-presentation-lifecycle
import CmuxMobileShell
import Foundation
import SwiftUI

/// Gives each mounted Simulator stream view a distinct lifecycle identity.
private struct SimulatorStreamPresentationLifecycleModifier: ViewModifier {
    @Environment(MobileSimulatorStreamStore.self) private var simulatorStreamStore
    @State private var presentationID = UUID()

    let panelID: String
    let workspaceID: String
    let isCurrentSelection: @MainActor () -> Bool
    let startStream: @MainActor () async -> Void
    let stopStream: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                let shouldStart = simulatorStreamStore.presentationDidAppear(
                    id: presentationID,
                    panelID: panelID,
                    in: workspaceID,
                    restoreSelectionIfNeeded: isCurrentSelection()
                )
                guard shouldStart else { return }
                Task { @MainActor in await startStream() }
            }
            .onDisappear {
                let shouldStop = simulatorStreamStore.presentationDidDisappear(
                    id: presentationID,
                    panelID: panelID,
                    in: workspaceID
                )
                guard shouldStop else { return }
                Task { @MainActor in await stopStream() }
            }
    }
}

extension View {
    /// Owns Simulator stream start/stop for one mounted SwiftUI presentation.
    func simulatorStreamPresentationLifecycle(
        panelID: String,
        workspaceID: String,
        isCurrentSelection: @escaping @MainActor () -> Bool,
        startStream: @escaping @MainActor () async -> Void,
        stopStream: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(SimulatorStreamPresentationLifecycleModifier(
            panelID: panelID,
            workspaceID: workspaceID,
            isCurrentSelection: isCurrentSelection,
            startStream: startStream,
            stopStream: stopStream
        ))
    }
}
// SUPERMUX:end simulator-stream-presentation-lifecycle
