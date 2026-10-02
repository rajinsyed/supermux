import AppKit
import CmuxSurfaceCatalogModel

/// "Forward a Port…": asks for a port a server on another Mac listens on (one
/// started outside cmux, say) and forwards it to this Mac by hand.
@MainActor
enum SupermuxPortForwardPrompt {
    static func present(machine: SurfaceMachineID, macName: String) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = String(
                localized: "supermux.ports.prompt.title",
                defaultValue: "Forward a Port from \(macName)"
            )
            alert.informativeText = String(
                localized: "supermux.ports.prompt.message",
                defaultValue: "Enter the port a server on \(macName) listens on. It opens at localhost on this Mac."
            )
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            field.placeholderString = "3000"
            alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "supermux.ports.prompt.confirm", defaultValue: "Forward"))
            alert.addButton(withTitle: String(localized: "supermux.common.cancel", defaultValue: "Cancel"))
            alert.window.initialFirstResponder = field
            let response = await SupermuxAlertPresentation.present(alert, preferring: NSApp.keyWindow)
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let port = Int(text), (1...65_535).contains(port) else {
                let invalid = NSAlert()
                invalid.messageText = String(
                    localized: "supermux.ports.prompt.invalid",
                    defaultValue: "Enter a port number from 1 to 65535."
                )
                SupermuxAlertPresentation.show(invalid, preferring: NSApp.keyWindow)
                return
            }
            await SupermuxComposition.portForwards.forward(machine: machine, remotePort: port)
        }
    }
}
