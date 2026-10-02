import CmuxSettings
import SwiftUI

/// SUPERMUX — "Remote Macs": the fork's controls for other Macs' workspaces.
///
/// - Four fork preferences: show other Macs' workspaces in the sidebar
///   (`supermux.devices.autoMirror`, live), forward their ports to this Mac
///   (`supermux.devices.forwardPorts`, live), sync projects across Macs
///   (`supermux.devices.syncProjects`), share the phone-notifications setup
///   (`supermux.devices.sharePush`).
/// - Whether this Mac is discoverable and whether it discovers other Macs,
///   with Turn On buttons that go through upstream's own
///   `ComputersSettingsActions` (the `DevicesPreferencesModel` /
///   `DevicesAccessCoordinator` path, including its consent sheet).
/// - Every known Mac with its link state, its forwarded ports and a Ports…
///   menu, and Show Hidden Workspaces.
///
/// Lives in this upstream package for the same reason as
/// ``SupermuxAISettingsCard`` (the section stack is closed to app injection);
/// rendered next to it by the `ai-settings` touchpoint in
/// ``AutomationSection``. App services arrive through
/// ``SupermuxRemoteMacsSettingsHosting``.
@MainActor
public struct SupermuxRemoteMacsSettingsCard: View {
    private let access: ComputersSettingsActions
    private let remote: SupermuxRemoteMacsSettingsActions?
    @State private var snapshot = SupermuxRemoteMacsSettingsSnapshot()
    @State private var accessSnapshot = ComputersSettingsSnapshot()
    @State private var discoveryManaged = ManagedDevicePolicy().isDeviceDiscoveryDisabled
    @State private var incomingAccessManaged = ManagedDevicePolicy().isIncomingDeviceAccessDisabled

    /// - Parameter hostActions: The settings host; its Devices actions drive the
    ///   discoverability rows, and its ``SupermuxRemoteMacsSettingsHosting``
    ///   conformance (when present) everything else.
    public init(hostActions: any SettingsHostActions) {
        access = hostActions.computersSettingsActions()
        remote = (hostActions as? any SupermuxRemoteMacsSettingsHosting)?.supermuxRemoteMacsSettingsActions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The settings' own header style, 2 pt right of the card like every other.
            SettingsSectionHeader(String(localized: "supermux.settings.remoteMacs.title", defaultValue: "Remote Macs"))
                .padding(.top, 6)
                .accessibilityIdentifier("SupermuxRemoteMacsHeading")
            SettingsCard {
                if remote != nil {
                    preferenceRows
                    SettingsCardDivider()
                }
                accessRow(.incomingAccess, enabled: accessSnapshot.incomingAccessEnabled, managed: incomingAccessManaged)
                SettingsCardDivider()
                accessRow(.discovery, enabled: accessSnapshot.discoveryEnabled, managed: discoveryManaged)
                if let remote {
                    SettingsCardDivider()
                    macRows(remote)
                    SettingsCardDivider()
                    hiddenRow(remote)
                }
            }
        }
        .task {
            for await value in access.updates() {
                guard !Task.isCancelled else { break }
                accessSnapshot = value
            }
        }
        .task {
            guard let remote else { return }
            for await value in remote.updates() {
                guard !Task.isCancelled else { break }
                snapshot = value
            }
        }
        .task {
            for await _ in ManagedDevicePolicy.changeSignals() {
                let policy = ManagedDevicePolicy()
                discoveryManaged = policy.isDeviceDiscoveryDisabled
                incomingAccessManaged = policy.isIncomingDeviceAccessDisabled
            }
        }
    }

    // MARK: - Fork preferences

    /// The fork preferences the card toggles.
    private enum Preference {
        case autoMirror, forwardPorts, syncProjects, sharePush
    }

    @ViewBuilder
    private var preferenceRows: some View {
        toggleRow(
            .autoMirror,
            String(localized: "supermux.settings.remoteMacs.autoMirror", defaultValue: "Show other Macs' workspaces in the sidebar"),
            subtitle: String(localized: "supermux.settings.remoteMacs.autoMirror.subtitle", defaultValue: "Every workspace on your other Macs appears in the sidebar under its project and stays in sync."),
            identifier: "SupermuxRemoteMacsAutoMirrorToggle"
        )
        SettingsCardDivider()
        toggleRow(
            .forwardPorts,
            String(localized: "supermux.ports.settings.forward", defaultValue: "Forward other Macs' ports to this Mac"),
            subtitle: String(localized: "supermux.ports.settings.forward.subtitle", defaultValue: "Servers you start in another Mac's workspaces open at localhost here, for browsers, the iOS Simulator and other apps. A port already in use here gets the next free one."),
            identifier: "SupermuxRemoteMacsForwardPortsToggle"
        )
        SettingsCardDivider()
        toggleRow(
            .syncProjects,
            String(localized: "supermux.settings.remoteMacs.syncProjects", defaultValue: "Sync projects across Macs"),
            subtitle: String(localized: "supermux.settings.remoteMacs.syncProjects.subtitle", defaultValue: "Adds a project on your other Macs when they have the same repository at the same path. Never clones or deletes."),
            identifier: "SupermuxRemoteMacsSyncProjectsToggle"
        )
        SettingsCardDivider()
        toggleRow(
            .sharePush,
            String(localized: "supermux.settings.remoteMacs.sharePush", defaultValue: "Share phone notifications setup with my other Macs"),
            subtitle: String(localized: "supermux.settings.remoteMacs.sharePush.subtitle", defaultValue: "The Mac that runs an agent can notify your iPhone, even while this Mac is closed."),
            identifier: "SupermuxRemoteMacsSharePushToggle"
        )
    }

    private func toggleRow(_ preference: Preference, _ title: String, subtitle: String, identifier: String) -> some View {
        SettingsCardRow(configurationReview: .settingsOnly, title, subtitle: subtitle) {
            Toggle(title, isOn: Binding(get: { value(of: preference) }, set: { set(preference, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier(identifier)
        }
    }

    private func value(of preference: Preference) -> Bool {
        switch preference {
        case .autoMirror: return snapshot.autoMirror
        case .forwardPorts: return snapshot.forwardPorts
        case .syncProjects: return snapshot.syncProjects
        case .sharePush: return snapshot.sharePush
        }
    }

    /// Shows the new value at once, then applies it through the app.
    private func set(_ preference: Preference, _ enabled: Bool) {
        switch preference {
        case .autoMirror:
            snapshot.autoMirror = enabled
            remote?.setAutoMirror(enabled)
        case .forwardPorts:
            snapshot.forwardPorts = enabled
            remote?.setForwardPorts(enabled)
        case .syncProjects:
            snapshot.syncProjects = enabled
            remote?.setSyncProjects(enabled)
        case .sharePush:
            snapshot.sharePush = enabled
            remote?.setSharePush(enabled)
        }
    }

    // MARK: - Discoverability (upstream's preference model)

    private func accessRow(_ preference: DevicesAccessCoordinator.Preference, enabled: Bool, managed: Bool) -> some View {
        let control = DeviceAccessControl(
            preference, enabled: enabled, managed: managed,
            unavailable: accessSnapshot.unavailableMessage != nil
        )
        let isIncoming = preference == .incomingAccess
        return SettingsCardRow(
            configurationReview: .settingsOnly,
            accessTitle(isIncoming: isIncoming, isOn: control.isOn),
            subtitle: accessSubtitle(isIncoming: isIncoming, control: control, managed: managed)
        ) {
            if control.isOn {
                HStack(spacing: 10) {
                    Label(String(localized: "supermux.settings.remoteMacs.access.on", defaultValue: "On"), systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    // Read-only here: Settings › Devices is where it is switched.
                    Button(String(localized: "supermux.settings.remoteMacs.access.change", defaultValue: "Change in Devices…")) {
                        Self.openDevicesSettings()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .accessibilityIdentifier(isIncoming ? "SupermuxRemoteMacsDiscoverableChange" : "SupermuxRemoteMacsDiscoveryChange")
                }
            } else {
                Button(String(localized: "supermux.settings.remoteMacs.access.turnOn", defaultValue: "Turn On")) {
                    Task {
                        if isIncoming { await access.setIncomingAccessEnabled(true) } else { await access.setDiscoveryEnabled(true) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!control.isEnabled)
                .accessibilityIdentifier(isIncoming ? "SupermuxRemoteMacsDiscoverableTurnOn" : "SupermuxRemoteMacsDiscoveryTurnOn")
            }
        }
    }

    /// Shows Settings › Remote & Devices › Devices, where both switches live.
    private static func openDevicesSettings() {
        NotificationCenter.default.post(
            name: SettingsWindowRoot.navigationRequestName,
            object: nil,
            userInfo: ["target": SettingsSectionID.computers.rawValue]
        )
    }

    private func accessTitle(isIncoming: Bool, isOn: Bool) -> String {
        switch (isIncoming, isOn) {
        case (true, true): return String(localized: "supermux.settings.remoteMacs.discoverable.on", defaultValue: "This Mac is discoverable")
        case (true, false): return String(localized: "supermux.settings.remoteMacs.discoverable.off", defaultValue: "This Mac is not discoverable")
        case (false, true): return String(localized: "supermux.settings.remoteMacs.discovery.on", defaultValue: "Discovering other Macs")
        case (false, false): return String(localized: "supermux.settings.remoteMacs.discovery.off", defaultValue: "Not discovering other Macs")
        }
    }

    private func accessSubtitle(isIncoming: Bool, control: DeviceAccessControl, managed: Bool) -> String {
        if managed { return control.help }
        if let unavailable = accessSnapshot.unavailableMessage { return unavailable }
        return isIncoming
            ? String(localized: "supermux.settings.remoteMacs.discoverable.subtitle", defaultValue: "Needed for your other Macs to show this Mac's workspaces.")
            : String(localized: "supermux.settings.remoteMacs.discovery.subtitle", defaultValue: "Needed to show your other Macs' workspaces in the sidebar.")
    }

    // MARK: - Macs and hidden workspaces

    @ViewBuilder
    private func macRows(_ remote: SupermuxRemoteMacsSettingsActions) -> some View {
        if snapshot.macs.isEmpty {
            SettingsCardNote(String(localized: "supermux.settings.remoteMacs.empty", defaultValue: "No other Macs yet. Sign in to the same account on another Mac and make it discoverable."))
        } else {
            ForEach(snapshot.macs) { mac in
                SupermuxRemoteMacRow(mac: mac, remote: remote)
                if mac.id != snapshot.macs.last?.id { SettingsCardDivider() }
            }
        }
    }

    private func hiddenRow(_ remote: SupermuxRemoteMacsSettingsActions) -> some View {
        let count = snapshot.hiddenWorkspaceCount
        return SettingsCardRow(
            configurationReview: .action,
            String(localized: "supermux.settings.remoteMacs.hidden", defaultValue: "Hidden workspaces"),
            subtitle: count == 0
                ? String(localized: "supermux.settings.remoteMacs.hidden.none", defaultValue: "None. Closing another Mac's workspace with Hide Here hides it on this Mac only.")
                : String(localized: "supermux.settings.remoteMacs.hidden.count", defaultValue: "Hidden on this Mac: \(count)")
        ) {
            Button(String(localized: "supermux.settings.remoteMacs.hidden.show", defaultValue: "Show Hidden Workspaces")) {
                remote.showHiddenWorkspaces()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(count == 0)
            .accessibilityIdentifier("SupermuxRemoteMacsShowHidden")
        }
    }
}

/// One known Mac in the Remote Macs card, laid out like a row of the
/// Settings › Devices list (``ComputersSettingsRow``): its name, then its
/// link state and how many of its workspaces this Mac sees (or why the link
/// is down), and while connected its forwarded ports, with a Ports… menu
/// while it can forward or a forward is still pending.
private struct SupermuxRemoteMacRow: View {
    let mac: SupermuxRemoteMacsSettingsSnapshot.Mac
    let remote: SupermuxRemoteMacsSettingsActions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(mac.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .help(mac.name)
                HStack(spacing: 5) {
                    Circle()
                        .fill(linkColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(linkText)
                    Text(verbatim: "·")
                    Text(detail).lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if mac.link == .connected {
                    Text(portsLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("SupermuxRemoteMacPorts")
                }
            }
            Spacer(minLength: 8)
            if mac.showsPortsMenu {
                portsMenu
            }
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("SupermuxRemoteMacRow")
    }

    /// `Ports: :3000 · :8081 → here :8082`, or why there are none.
    private var portsLine: String {
        if let note = mac.portsNote { return note }
        let forwarded = mac.ports.filter(\.isForwarded).map(\.lineText)
        guard !forwarded.isEmpty else {
            return String(localized: "supermux.ports.settings.none", defaultValue: "No forwarded ports")
        }
        let list = forwarded.joined(separator: " · ")
        return String(localized: "supermux.ports.settings.line", defaultValue: "Ports: \(list)")
    }

    /// Each port's items as the app decides them (a pending forward offers
    /// Stop Forwarding even while the Mac cannot forward), then Forward a
    /// Port… while it can.
    private var portsMenu: some View {
        let ports = mac.ports.filter { !$0.actions.isEmpty }
        return Menu(String(localized: "supermux.ports.settings.menu", defaultValue: "Ports…")) {
            ForEach(ports) { port in
                Menu(port.menuLabel) {
                    ForEach(port.actions, id: \.self) { action in
                        Button(Self.title(of: action)) { remote.portAction(mac.id, port.remotePort, action) }
                    }
                }
            }
            if mac.canForwardPorts {
                if !ports.isEmpty { Divider() }
                Button(String(localized: "supermux.ports.menu.forwardPort", defaultValue: "Forward a Port…")) {
                    remote.forwardPort(mac.id)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12))
        .accessibilityIdentifier("SupermuxRemoteMacPortsMenu")
    }

    private static func title(of action: SupermuxRemoteMacPortAction) -> String {
        switch action {
        case .openInBrowser:
            return String(localized: "supermux.ports.menu.openDefault", defaultValue: "Open in Default Browser")
        case .copyLocalURL:
            return String(localized: "supermux.ports.menu.copy", defaultValue: "Copy Local URL")
        case .stopForwarding:
            return String(localized: "supermux.ports.menu.stop", defaultValue: "Stop Forwarding")
        case .forward:
            return String(localized: "supermux.ports.menu.forward", defaultValue: "Forward to This Mac")
        }
    }

    private var detail: String {
        if mac.link != .connected, let detail = mac.detail, !detail.isEmpty { return detail }
        return String(localized: "supermux.settings.remoteMacs.mac.workspaces", defaultValue: "Workspaces: \(mac.workspaceCount)")
    }

    private var linkText: String {
        switch mac.link {
        case .connected:
            return String(localized: "supermux.settings.remoteMacs.link.connected", defaultValue: "Connected")
        case .connecting:
            return String(localized: "supermux.settings.remoteMacs.link.connecting", defaultValue: "Connecting…")
        case .offline:
            return String(localized: "supermux.settings.remoteMacs.link.offline", defaultValue: "Offline")
        }
    }

    private var linkColor: Color {
        switch mac.link {
        case .connected: return .green
        case .connecting: return .orange
        case .offline: return .secondary
        }
    }
}
