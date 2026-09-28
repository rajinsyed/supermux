import SwiftUI

struct PaneDropTargetRepresentable: NSViewRepresentable {
    let dropContext: PaneDropContext?
    // SUPERMUX:begin claude-harness-file-drop-passthrough
    var capturesFileDrops = true
    // SUPERMUX:end claude-harness-file-drop-passthrough

    func makeNSView(context: Context) -> PaneDropTargetView {
        PaneDropTargetView(frame: .zero)
    }

    func updateNSView(_ nsView: PaneDropTargetView, context: Context) {
        nsView.dropContext = dropContext
        nsView.hostedView = nil
        // SUPERMUX:begin claude-harness-file-drop-passthrough
        nsView.capturesFileDrops = capturesFileDrops
        // SUPERMUX:end claude-harness-file-drop-passthrough
        if dropContext == nil {
            nsView.draggingExited(nil)
        }
    }
}
