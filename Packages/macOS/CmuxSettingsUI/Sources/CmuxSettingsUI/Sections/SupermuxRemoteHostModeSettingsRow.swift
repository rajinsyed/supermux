import CmuxSettings
import SwiftUI

/// SUPERMUX — the stored Remote Host Mode preference.
///
/// A plain UserDefaults preference (no `cmux.json` key, like the fork's other
/// settings rows). The app reads it through `SupermuxRemoteHostMode` and
/// applies a change when the defaults change.
public enum SupermuxRemoteHostModeSetting {
    /// Whether this Mac runs as a headless remote host: no main window on
    /// screen and no Dock icon, with every workspace still running.
    public static let key = DefaultsKey<Bool>(
        id: "supermux.remoteHostMode",
        defaultValue: false,
        userDefaultsKey: "supermux.remoteHostMode"
    )
}

/// SUPERMUX — the "Remote Host Mode" row in Settings › App, right after
/// Menu Bar Only (`remote-host-mode` touchpoint in ``AppSection``).
///
/// The toggle only writes the preference; the app hides or shows its windows
/// when it sees the change. The subtitle points at the existing Keep Mac Awake
/// item in the menu bar item, which keeps the Mac reachable (no power
/// management of the fork's own).
@MainActor
struct SupermuxRemoteHostModeSettingsRow: View {
    @State private var enabled: DefaultsValueModel<Bool>

    init(defaultsStore: UserDefaultsSettingsStore) {
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: SupermuxRemoteHostModeSetting.key))
    }

    var body: some View {
        let title = String(localized: "supermux.remoteHost.settings.title", defaultValue: "Remote Host Mode")
        SettingsCardRow(
            configurationReview: .settingsOnly,
            title,
            subtitle: String(
                localized: "supermux.remoteHost.settings.subtitle",
                defaultValue: "Run with no windows and no Dock icon while you use this Mac from your iPhone or another Mac. Workspaces keep running; the menu bar item shows Supermux. Turn on Keep Mac Awake there so this Mac stays reachable."
            )
        ) {
            Toggle(title, isOn: Binding(get: { enabled.current }, set: { enabled.set($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("SupermuxRemoteHostModeToggle")
        }
        .task { enabled.startObserving() }
    }
}
