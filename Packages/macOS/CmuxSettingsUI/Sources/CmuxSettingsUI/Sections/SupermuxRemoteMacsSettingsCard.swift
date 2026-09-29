import CmuxSettings
import SwiftUI

/// SUPERMUX — "Remote Macs": the fork's controls for other Macs' workspaces.
///
/// - Three fork preferences: show other Macs' workspaces in the sidebar
///   (`supermux.devices.autoMirror`, live), sync projects across Macs
///   (`supermux.devices.syncProjects`), share the phone-notifications setup
///   (`supermux.devices.sharePush`).
/// - Whether this Mac is discoverable and whether it discovers other Macs,
///   with Turn On buttons that go through upstream's own
///   `ComputersSettingsActions` (the `DevicesPreferencesModel` /
///   `DevicesAccessCoordinator` path, including its consent sheet).
/// - Every known Mac with its link state, and Show Hidden Workspaces.
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
            Text(String(localized: "supermux.settings.remoteMacs.title", defaultValue: "Remote Macs"))
                .font(.headline)
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
                    macRows
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

    /// The three fork preferences the card toggles.
    private enum Preference {
        case autoMirror, syncProjects, sharePush
    }

    @ViewBuilder
    private var preferenceRows: some View {
        toggleRow(
            .autoMirror,
            String(localized: "supermux.settings.remoteMacs.autoMirror", defaultValue: "Show other Macs' workspaces in the sidebar"),
            subtitle: String(localized: "supermux.settings.remoteMacs.autoMirror.subtitle", defaultValue: "Every workspace on your other Macs appears here under its project and stays in sync."),
            identifier: "SupermuxRemoteMacsAutoMirrorToggle"
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
                Label(String(localized: "supermux.settings.remoteMacs.access.on", defaultValue: "On"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
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
            : String(localized: "supermux.settings.remoteMacs.discovery.subtitle", defaultValue: "Needed to show your other Macs' workspaces here.")
    }

    // MARK: - Macs and hidden workspaces

    @ViewBuilder
    private var macRows: some View {
        if snapshot.macs.isEmpty {
            SettingsCardNote(String(localized: "supermux.settings.remoteMacs.empty", defaultValue: "No other Macs yet. Sign in to the same account on another Mac and make it discoverable."))
        } else {
            ForEach(snapshot.macs) { mac in
                SupermuxRemoteMacRow(mac: mac)
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

/// One known Mac in the Remote Macs card: its name, how many of
/// its workspaces this Mac sees, and its link state.
private struct SupermuxRemoteMacRow: View {
    let mac: SupermuxRemoteMacsSettingsSnapshot.Mac

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            HStack(spacing: 5) {
                Circle().fill(linkColor).frame(width: 7, height: 7)
                Text(linkText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("SupermuxRemoteMacRow")
    }

    private var subtitle: String {
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
