// SUPERMUX:begin runtime-ssh-tmux-tui-template-regressions
#if RUNTIME_SSH_TMUX_TUI_HARNESS
import CmuxFoundation
import Foundation
import Testing

struct RuntimeSshTmuxTuiTests {
    private func commandOptions(_ sshOptions: [String]) -> CMUXCLI.SSHCommandOptions {
        .init(destination: "audit@localhost", port: nil, identityFile: nil, workspaceName: nil,
              noFocus: false, sshOptions: sshOptions, remoteCommand: SSHRemoteCommand(undelimitedArguments: []),
              localSocketPath: "fixture", remoteRelayPort: 43210)
    }

    private func handoff(original: [String], route: String?) async throws -> [String] {
        let cli = CMUXCLI()
        let options = commandOptions(original)
        // Read-only OpenSSH expansion; no user configuration, hooks or network.
        let config = cli.resolvedSSHConfigurationResult(for: options, configurationFile: "/dev/null")
        #expect(config.status == 0)
        var resolved = options
        resolved.sshOptions = cli.resolvedCmuxControlPathOptions(for: options, configurationOutput: config.stdout)
        if original.contains(where: { $0.hasSuffix("/%C") }) {
            #expect(!resolved.sshOptions.contains(where: { $0.hasSuffix("/%C") }))
        }
        let fixture = try RuntimeSshTmuxProgressSocket()
        defer { fixture.cleanup() }
        fixture.start()
        fixture.releaseReply.signal()
        let client = SocketClient(path: fixture.path)
        try client.connect()
        defer { client.close() }
        try cli.runSSHTui(options: resolved, configuredRemoteCommand: nil, client: client,
                          jsonOutput: true, idFormat: .refs, routeIdentifier: route,
                          preResolutionSSHOptions: original)
        client.close()
        await fixture.completed.wait()
        let (method, failure) = fixture.result()
        #expect(method == "workspace.ssh.open")
        #expect(failure == nil)
        return try #require(fixture.parameters()["ssh_options"] as? [String])
    }

    @Test func resolvedDefaultTemplateHandoffReusesDefaultMaster() async throws {
        let sharing = SSHConnectionSharingOptions()
        _ = try #require(sharing.defaultControlPath)
        let route = String(repeating: "a", count: 64)
        let original = sharing.mergingDefaults(into: [], routeIdentifier: route)
        let options = try await handoff(original: original, route: route)
        #expect(!options.contains(where: { $0.lowercased().hasPrefix("__cmux_route_sensitive=") }))
        #expect(!options.contains(where: { $0.lowercased().hasPrefix("controlpath=") }))
        let restored = sharing.mergingDefaults(into: options, routeIdentifier: route)
        #expect(sharing.cmuxOwnedControlPath(in: restored) == sharing.defaultControlPath)
    }

    @Test func concreteSensitiveRouteKeepsMarkerAndMaster() async throws {
        let sharing = SSHConnectionSharingOptions()
        let route = String(repeating: "b", count: 64)
        let original = sharing.mergingDefaults(into: ["IdentityFile=/fixture/key"], routeIdentifier: route)
        let path = try #require(sharing.cmuxOwnedControlPath(in: original))
        #expect(!path.contains("%"))
        let options = try await handoff(original: original, route: route)
        #expect(options.contains("__cmux_route_sensitive=\(route)"))
        #expect(options.contains("IdentityFile=/fixture/key"))
        let restored = sharing.mergingDefaults(into: options, routeIdentifier: route)
        #expect(sharing.cmuxOwnedControlPath(in: restored) == path)
    }

    @Test func callerOwnedTemplateIsNotReplaced() async throws {
        let original = ["ControlMaster=auto", "ControlPath=/tmp/caller-%C"]
        let options = try await handoff(original: original, route: String(repeating: "c", count: 64))
        #expect(options == original)
    }
}
#endif
// SUPERMUX:end runtime-ssh-tmux-tui-template-regressions
