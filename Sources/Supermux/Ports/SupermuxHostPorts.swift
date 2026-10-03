import CmuxIrxTransport
import Foundation
import SupermuxMobileCore

/// This Mac's ports as another of the user's Macs sees them
/// (`mobile.supermux.ports.list`): the ports this Mac's own cmux workspaces
/// listen on (the sidebar's port detection: each terminal's ports, then the
/// agent-reported ones), kept only while a loopback listener really serves
/// them, each with its workspace and terminal title.
///
/// Workspace attribution is what keeps system services (AirPlay, rapportd,
/// databases) and this app's own listeners out of auto-forwarding: they are
/// in no terminal's process tree. The live check drops ports restored from a
/// session snapshot that nothing serves any more, and ports bound only to a
/// LAN address, which a tunnel to loopback cannot reach. SSH and tmux
/// workspaces (their ports are on another host) and device mirrors (another
/// Mac's) are never listed. With `includeOther`, every other live loopback
/// listener's port is listed too, for a manual forward.
@MainActor
enum SupermuxHostPorts {
    static func list(includeOther: Bool) async -> SupermuxPortsListDTO {
        let attributed = attributedPorts()
        let live = await Task.detached(priority: .utility) {
            Set(IrxListeningPortScanner().loopbackListeningPorts().map(\.port))
        }.value
        let ports = unique(attributed.filter { live.contains($0.port) } + injectedPorts())
        let other = includeOther
            ? live.subtracting(attributed.map(\.port)).subtracting(SupermuxOwnListenerPorts.shared.all)
                .union(injectedOtherPorts()).sorted()
            : nil
        return SupermuxPortsListDTO(ports: ports, otherPorts: other)
    }

    /// Every port this Mac's own workspaces report, one entry per port and workspace.
    private static func attributedPorts() -> [SupermuxPortsListDTO.Port] {
        var ports: [SupermuxPortsListDTO.Port] = []
        for workspace in SupermuxDeviceWorkspaceIndex.allMainWindowWorkspaces() where isOwn(workspace) {
            let id = workspace.id.uuidString
            let terminals = workspace.surfaceListeningPorts.sorted { $0.key.uuidString < $1.key.uuidString }
            for (panelID, panelPorts) in terminals {
                for port in panelPorts {
                    ports.append(.init(port: port, workspaceID: id, workspaceTitle: workspace.title,
                                       terminalTitle: workspace.panelTitles[panelID]))
                }
            }
            for port in workspace.agentListeningPorts {
                ports.append(.init(port: port, workspaceID: id, workspaceTitle: workspace.title, terminalTitle: nil))
            }
        }
        return unique(ports)
    }

    /// Whether the workspace runs on this Mac: not an SSH or tmux workspace
    /// and not a mirror of another Mac's workspace.
    private static func isOwn(_ workspace: Workspace) -> Bool {
        !workspace.isRemoteWorkspace && !workspace.isRemoteTmuxMirror
            && !SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace)
    }

    /// The first entry per (port, workspace), ordered by port.
    private static func unique(_ ports: [SupermuxPortsListDTO.Port]) -> [SupermuxPortsListDTO.Port] {
        var seen = Set<String>()
        return ports
            .filter { seen.insert("\($0.port)|\($0.workspaceID)").inserted }
            .sorted { ($0.port, $0.workspaceID) < ($1.port, $1.workspaceID) }
    }

    /// Ports the DEBUG `tunnel.inject_other_port` driver reports under
    /// `other_ports`, live or not (none in Release builds).
    private static func injectedOtherPorts() -> Set<Int> {
        #if DEBUG
        SupermuxDeviceTunnelSocketCommands.injectedOtherPorts
        #else
        []
        #endif
    }

    /// Ports the DEBUG `tunnel.inject_port` driver reports as a workspace's,
    /// live or not (none in Release builds).
    private static func injectedPorts() -> [SupermuxPortsListDTO.Port] {
        #if DEBUG
        SupermuxDeviceTunnelSocketCommands.injectedHostPorts.flatMap { workspaceID, ports in
            let title = Workspace.liveWorkspace(id: workspaceID)?.title
            return ports.map {
                SupermuxPortsListDTO.Port(port: $0, workspaceID: workspaceID.uuidString, workspaceTitle: title, terminalTitle: nil)
            }
        }
        #else
        []
        #endif
    }
}
