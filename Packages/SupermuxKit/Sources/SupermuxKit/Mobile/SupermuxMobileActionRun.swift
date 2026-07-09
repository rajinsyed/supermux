public import Foundation

/// How `mobile.supermux.action.run` treats one project action.
public enum SupermuxMobileActionRunOutcome: Equatable, Sendable {
    /// The action's command is a single absolute http(s) URL: the Mac
    /// returns it (`{kind: "open_url", url}`) and executes NOTHING — the
    /// phone opens the URL locally (architecture §7, RPC-ACT-01).
    case openURL(URL)
    /// Any other launchable action (editor commands like `cursor .`
    /// included): the Mac executes it through the desktop launch path
    /// (``SupermuxTabManagerOpener/runAction(_:)``) and returns ok.
    case command(String)
}

/// Classifies project actions for the mobile `action.run` handler and builds
/// its wire results. Package-hosted so RPC-ACT-01's decision logic is
/// unit-testable without the app target.
///
/// The Mac's stored ``SupermuxProjectAction`` model has a single kind — a
/// shell command — so the `open_url` classification is derived at run time:
/// a command that IS one absolute http(s) URL is meaningless to run in a
/// terminal and is exactly the "open this in a browser" action the phone
/// should open locally. Commands that merely mention a URL (e.g.
/// `open https://…`) stay commands.
public enum SupermuxMobileActionRun {
    /// Classifies one action.
    /// - Parameter action: The stored project action.
    /// - Returns: The run outcome, or `nil` when the action is not
    ///   launchable (blank name or command — desktop parity with
    ///   ``SupermuxProjectAction/isLaunchable``).
    public static func outcome(for action: SupermuxProjectAction) -> SupermuxMobileActionRunOutcome? {
        guard action.isLaunchable else { return nil }
        let command = action.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = openableURL(command) {
            return .openURL(url)
        }
        return .command(command)
    }

    /// The `{kind: "open_url", url}` result for an `open_url` action.
    /// - Parameter url: The URL the phone opens locally.
    /// - Returns: The RPC result object.
    public static func openURLResult(url: URL) -> [String: Any] {
        [
            "kind": "open_url",
            "url": url.absoluteString,
        ]
    }

    /// The `{ok: true, kind: "command"}` result after a command action was
    /// launched mac-side.
    /// - Returns: The RPC result object.
    public static func commandResult() -> [String: Any] {
        [
            "ok": true,
            "kind": "command",
        ]
    }

    /// The command as an absolute http(s) URL, or `nil` when it is anything
    /// else (multiple words, other schemes, no host).
    private static func openableURL(_ command: String) -> URL? {
        guard !command.isEmpty, !command.contains(where: \.isWhitespace) else { return nil }
        guard let url = URL(string: command),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
