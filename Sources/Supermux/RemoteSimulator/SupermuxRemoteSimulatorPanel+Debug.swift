#if DEBUG
import CmuxMobileSimulatorStream
import CmuxSimulatorStreamKit
import Foundation

/// What the `supermux.devices.mirror.simulator.*` DEBUG drivers read and do
/// on a viewer (``SupermuxRemoteSimulatorSocketCommands``).
extension SupermuxRemoteSimulatorPanel: SupermuxRemoteSimulatorDebugInspectable {
    func debugState() -> [String: Any] {
        let phase = store?.phase ?? .idle
        return [
            "phase": Self.phaseName(phase),
            "phase_detail": Self.phaseDetail(phase) ?? NSNull(),
            "attachment": Self.attachmentName(attachment),
            "host_status": store?.hostStatus.map { "\($0)" } ?? NSNull(),
            "host_detail": store?.hostDetail ?? "",
            "presented_frames": Int(store?.presentedFrameCount ?? 0),
            "configs_applied": configsApplied,
            "config": lastConfig.map(Self.configPayload) ?? NSNull(),
            "quality": quality.rawValue,
            "max_long_side": Int(currentLongSide),
            "superseded": isSuperseded,
            "supports_controls": supportsControls,
            "devices_slow": devicesAreSlow,
            "devices_count": devices.count,
            "devices_answers": devicesAnswerCount,
            "renderer_status": displayView.rendererStatusName,
            "binding": [
                "machine": machine.rawValue,
                "remote_workspace_id": remoteWorkspaceID,
                "host_panel_id": hostPanelID?.uuidString ?? NSNull(),
                "udid": deviceUDID ?? NSNull(),
            ] as [String: Any],
        ]
    }

    func debugPerform(_ action: String, params: [String: Any]) async throws -> [String: Any] {
        switch action {
        case "input":
            guard let event = Self.inputEvent(params["event"] as? [String: Any] ?? [:]) else {
                throw SupermuxRemoteSimulatorSocketCommands.InvalidParams(
                    message: "event must be {button}, {text}, {key, down} or {touch, x, y}"
                )
            }
            let streaming = store?.phase == .streaming
            send(event)
            return ["accepted": streaming]
        case "control":
            guard let hostPanelID, let control = params["action"] as? String else { return ["accepted": false] }
            try await hostClient.control(control, panelID: hostPanelID)
            return ["accepted": true]
        case "quality":
            guard let preset = (params["preset"] as? String).flatMap(SupermuxRemoteSimulatorQuality.init(rawValue:)) else {
                throw SupermuxRemoteSimulatorSocketCommands.InvalidParams(
                    message: "preset must be auto, high, balanced or dataSaver"
                )
            }
            setQuality(preset)
            return ["accepted": true, "max_long_side": Int(currentLongSide)]
        case "select_device":
            guard hostPanelID != nil, let udid = params["udid"] as? String else { return ["accepted": false] }
            await selectDevice(udid)
            return ["accepted": true]
        case "show_here":
            showHere()
            return ["accepted": true]
        case "devices":
            await refreshDevices()
            return ["devices": devices.map { device -> [String: Any] in
                ["udid": device.udid, "name": device.name, "state": device.state, "is_selected": device.isSelected]
            }]
        default:
            throw SupermuxRemoteSimulatorSocketCommands.InvalidParams(message: "unknown viewer action \(action)")
        }
    }

    private static func inputEvent(_ raw: [String: Any]) -> SimStreamInputEvent? {
        if let name = raw["button"] as? String {
            let buttons: [String: SimStreamHardwareButton] = [
                "home": .home, "lock": .lock, "app_switcher": .appSwitcher, "siri": .siri,
                "side_button": .sideButton, "volume_up": .volumeUp, "volume_down": .volumeDown,
            ]
            return buttons[name].map(SimStreamInputEvent.button)
        }
        if let text = raw["text"] as? String {
            return .text(text)
        }
        if let usage = (raw["key"] as? NSNumber)?.uint16Value {
            return .key(usage: usage, isDown: raw["down"] as? Bool ?? true)
        }
        if let phaseName = raw["touch"] as? String,
           let x = (raw["x"] as? NSNumber)?.floatValue, let y = (raw["y"] as? NSNumber)?.floatValue {
            let phases: [String: SimStreamTouchPhase] = ["began": .began, "moved": .moved, "ended": .ended]
            guard let phase = phases[phaseName] else { return nil }
            return .touch(phase: phase, pointerID: 0, x: x, y: y, timestampMicroseconds: 0)
        }
        return nil
    }

    private static func phaseName(_ phase: SimStreamViewerPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .connecting: "connecting"
        case .streaming: "streaming"
        case .reconnecting: "reconnecting"
        case .unavailable: "unavailable"
        case .stopped: "stopped"
        }
    }

    private static func phaseDetail(_ phase: SimStreamViewerPhase) -> String? {
        if case .unavailable(let detail) = phase { return detail }
        return nil
    }

    private static func attachmentName(_ attachment: HostAttachment) -> String {
        switch attachment {
        case .finding: "finding"
        case .attached: "attached"
        case .closedOnHost: "closed_on_host"
        case .failed(let message): "failed: \(message)"
        }
    }

    private static func configPayload(_ config: SimStreamConfig) -> [String: Any] {
        let orientations: [SimStreamOrientation: String] = [
            .portrait: "portrait", .landscapeLeft: "landscape_left",
            .portraitUpsideDown: "portrait_upside_down", .landscapeRight: "landscape_right",
        ]
        return [
            "codec": config.codec == .hevc ? "hevc" : "h264",
            "width": Int(config.pixelWidth),
            "height": Int(config.pixelHeight),
            "orientation": orientations[config.orientation] ?? "unknown",
            "display_scale": Double(config.displayScale),
        ]
    }
}
#endif
