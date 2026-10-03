import AppKit
import CmuxMobileSimulatorStream
import CmuxSimulatorStreamKit
import SwiftUI

/// A remote-simulator viewer tab: a toolbar (the owning Mac's device menu,
/// Home, App Switcher, Lock, rotate, software keyboard, quality, Recover),
/// the live video, a status line over it while it is not streaming, and a
/// field that types text on the simulator.
struct SupermuxRemoteSimulatorPanelView: View {
    let panel: SupermuxRemoteSimulatorPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void
    @State private var typedText = ""
    @State private var visibilityHostID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                SupermuxRemoteSimulatorDisplayHost(view: panel.displayView)
                    .opacity(panel.store?.phase == .streaming ? 1 : 0.4)
                if let status {
                    statusOverlay(status)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            typeTextRow
        }
        .background(SupermuxRemoteSimulatorFocusArea(panel: panel))
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .environment(\.colorScheme, cmuxReadableColorScheme(for: appearance.backgroundColor))
        .onAppear {
            panel.displayView.onFocusRequest = onRequestPanelFocus
            panel.setVisible(isVisibleInUI, hostID: visibilityHostID)
            if isFocused { panel.focus() }
        }
        .onChange(of: isVisibleInUI) { _, visible in
            panel.setVisible(visible, hostID: visibilityHostID)
        }
        .onChange(of: isFocused) { _, focused in
            if focused { panel.focus() }
        }
        .onDisappear {
            panel.setVisible(false, hostID: visibilityHostID)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            deviceMenu
            Spacer(minLength: 8)
            toolbarButton("house", Strings.home) { panel.press(.home) }
            toolbarButton("square.stack.3d.up", Strings.appSwitcher) { panel.press(.appSwitcher) }
            toolbarButton("lock", Strings.lock) { panel.press(.lock) }
            if panel.supportsControls {
                toolbarButton("rotate.left", Strings.rotateLeft) { panel.runControl("rotate_left") }
                toolbarButton("rotate.right", Strings.rotateRight) { panel.runControl("rotate_right") }
                toolbarButton("keyboard", Strings.keyboard) { panel.runControl("toggle_software_keyboard") }
            }
            qualityMenu
            if needsRecover {
                Button(Strings.recover) { panel.recover() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var deviceMenu: some View {
        Menu {
            Section(Strings.devicesTitle(panel.macName)) {
                if panel.devicesAreSlow {
                    Text(Strings.slow(panel.macName))
                } else if panel.devices.isEmpty {
                    Text(Strings.noSimulators(panel.macName))
                }
                ForEach(panel.devices, id: \.udid) { device in
                    Button {
                        Task { await panel.selectDevice(device.udid) }
                    } label: {
                        if device.udid == panel.deviceUDID {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            }
        } label: {
            Label(panel.deviceName ?? panel.macName, systemImage: "iphone")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Strings.devicesTitle(panel.macName))
        .onAppear { Task { await panel.refreshDevices() } }
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(SupermuxRemoteSimulatorQuality.allCases, id: \.self) { quality in
                Button {
                    panel.setQuality(quality)
                } label: {
                    if quality == panel.quality {
                        Label(quality.title, systemImage: "checkmark")
                    } else {
                        Text(quality.title)
                    }
                }
            }
        } label: {
            Image(systemName: "dial.medium")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Strings.quality)
    }

    private func toolbarButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }

    private var needsRecover: Bool {
        panel.store?.hostStatus == .workerCrashed || panel.store?.hostStatus == .failed
    }

    // MARK: - Type text

    private var typeTextRow: some View {
        HStack(spacing: 6) {
            TextField(Strings.typeTextPlaceholder, text: $typedText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendTypedText)
            Button(Strings.send, action: sendTypedText)
                .disabled(typedText.isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func sendTypedText() {
        guard !typedText.isEmpty else { return }
        panel.sendText(typedText)
        typedText = ""
    }

    // MARK: - Status

    private struct Status {
        let text: String
        var actionTitle: String?
        var action: (@MainActor () -> Void)?
    }

    /// What the viewer says while it is not streaming, or nil when it is.
    private var status: Status? {
        let mac = panel.macName
        switch panel.attachment {
        case .finding:
            return Status(text: Strings.starting(mac))
        case .closedOnHost:
            return Status(text: Strings.closed(mac), actionTitle: Strings.openAgain, action: { panel.openAgain() })
        case .failed(let message):
            return Status(text: message, actionTitle: Strings.openAgain, action: { panel.openAgain() })
        case .attached:
            break
        }
        if panel.isSuperseded {
            return Status(text: Strings.superseded, actionTitle: Strings.showHere, action: { panel.showHere() })
        }
        guard let store = panel.store else { return Status(text: Strings.starting(mac)) }
        if store.hostDetail == "simulator_disabled" {
            return Status(text: Strings.disabled(mac))
        }
        switch store.phase {
        case .streaming:
            return needsRecover ? Status(text: Strings.failed(mac), actionTitle: Strings.recover, action: { panel.recover() }) : nil
        case .idle, .connecting:
            if panel.devicesAreSlow, panel.devices.isEmpty {
                return Status(text: Strings.slow(mac))
            }
            if store.hostStatus == .deviceUnavailable, panel.devices.isEmpty {
                return Status(text: Strings.noSimulators(mac))
            }
            if store.hostStatus == .preparing, let device = panel.deviceName {
                return Status(text: Strings.booting(device, mac))
            }
            return Status(text: Strings.starting(mac))
        case .reconnecting:
            return Status(text: Strings.waiting(mac))
        case .stopped:
            return nil
        case .unavailable(let detail):
            switch detail {
            case "superseded":
                return Status(text: Strings.superseded, actionTitle: Strings.showHere, action: { panel.showHere() })
            case "simulator_disabled":
                return Status(text: Strings.disabled(mac))
            default:
                return Status(text: Strings.failed(mac), actionTitle: Strings.showHere, action: { panel.showHere() })
            }
        }
    }

    private func statusOverlay(_ status: Status) -> some View {
        VStack(spacing: 10) {
            Text(status.text)
                .font(.callout)
                .multilineTextAlignment(.center)
            if let title = status.actionTitle, let action = status.action {
                Button(title, action: action)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(24)
    }
}

/// Hosts the panel's one display view (it outlives SwiftUI's re-renders and
/// keeps its decoder); a new container simply adopts it.
private struct SupermuxRemoteSimulatorDisplayHost: NSViewRepresentable {
    let view: SupermuxRemoteSimulatorDisplayView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        adopt(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { adopt(into: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for subview in container.subviews { subview.removeFromSuperview() }
    }

    private func adopt(into container: NSView) {
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}

/// An invisible view over the whole tab that the panel measures focus
/// against (as upstream's `SimulatorFocusOwnershipBridge` does), so its
/// type-text field counts as the panel's own focus.
private struct SupermuxRemoteSimulatorFocusArea: NSViewRepresentable {
    let panel: SupermuxRemoteSimulatorPanel

    func makeNSView(context: Context) -> NSView {
        let view = ClickThroughView()
        panel.focusArea = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        panel.focusArea = view
    }

    private final class ClickThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The viewer's user-facing text.
private enum Strings {
    static var home: String { String(localized: "supermux.remoteSimulator.button.home", defaultValue: "Home") }
    static var appSwitcher: String {
        String(localized: "supermux.remoteSimulator.button.appSwitcher", defaultValue: "App Switcher")
    }
    static var lock: String { String(localized: "supermux.remoteSimulator.button.lock", defaultValue: "Lock") }
    static var rotateLeft: String {
        String(localized: "supermux.remoteSimulator.button.rotateLeft", defaultValue: "Rotate Left")
    }
    static var rotateRight: String {
        String(localized: "supermux.remoteSimulator.button.rotateRight", defaultValue: "Rotate Right")
    }
    static var keyboard: String {
        String(localized: "supermux.remoteSimulator.button.keyboard", defaultValue: "Software Keyboard")
    }
    static var recover: String { String(localized: "supermux.remoteSimulator.button.recover", defaultValue: "Recover") }
    static var quality: String { String(localized: "supermux.remoteSimulator.quality.title", defaultValue: "Quality") }
    static var typeTextPlaceholder: String {
        String(localized: "supermux.remoteSimulator.typeText.placeholder", defaultValue: "Type text")
    }
    static var send: String { String(localized: "supermux.remoteSimulator.typeText.send", defaultValue: "Send") }
    static var superseded: String {
        String(
            localized: "supermux.remoteSimulator.state.superseded",
            defaultValue: "This simulator is showing on another device"
        )
    }
    static var showHere: String { String(localized: "supermux.remoteSimulator.action.showHere", defaultValue: "Show Here") }
    static var openAgain: String {
        String(localized: "supermux.remoteSimulator.action.openAgain", defaultValue: "Open Again")
    }

    static func devicesTitle(_ mac: String) -> String {
        String(localized: "supermux.remoteSimulator.devices.title", defaultValue: "Simulators on \(mac)")
    }

    static func slow(_ mac: String) -> String {
        SupermuxRemoteSimulatorHostClient.slowText(mac)
    }

    static func noSimulators(_ mac: String) -> String {
        String(localized: "supermux.remoteSimulator.devices.empty", defaultValue: "No simulators on \(mac)")
    }

    static func starting(_ mac: String) -> String {
        String(localized: "supermux.remoteSimulator.state.starting", defaultValue: "Starting the simulator on \(mac)…")
    }

    static func booting(_ device: String, _ mac: String) -> String {
        String(localized: "supermux.remoteSimulator.state.booting", defaultValue: "Booting \(device) on \(mac)…")
    }

    static func waiting(_ mac: String) -> String {
        String(localized: "supermux.remoteSimulator.state.waiting", defaultValue: "Waiting for \(mac)…")
    }

    static func closed(_ mac: String) -> String {
        String(localized: "supermux.remoteSimulator.state.closed", defaultValue: "Closed on \(mac)")
    }

    static func disabled(_ mac: String) -> String {
        String(localized: "supermux.remoteSimulator.state.disabled", defaultValue: "Simulators are turned off on \(mac)")
    }

    static func failed(_ mac: String) -> String {
        String(localized: "supermux.remoteSimulator.state.failed", defaultValue: "The simulator on \(mac) stopped")
    }
}
