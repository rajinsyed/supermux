import CmuxSurfaceCatalogModel
import Foundation

/// Failures of the fork's device facade and mirror opener.
enum SupermuxDeviceError: Error, LocalizedError, Equatable {
    /// No `DeviceSurfaceProvider` is registered for the machine.
    case unknownDevice(String)
    /// The device's link is not live.
    case notConnected(String)
    /// The other Mac answered with an error.
    case hostRejected(code: String?, message: String)
    /// The other Mac's reply did not have the expected shape.
    case malformedResponse(String)
    /// The remote workspace did not appear in the device's records in time.
    case remoteWorkspaceTimedOut(String)
    /// The remote workspace has nothing a local mirror can show.
    case nothingToMirror(String)
    /// The target window is gone.
    case windowUnavailable

    var errorDescription: String? {
        switch self {
        case .unknownDevice:
            return String(localized: "supermux.devices.error.unknownDevice", defaultValue: "That Mac is not available.")
        case .notConnected(let name):
            return String(localized: "supermux.devices.error.notConnected", defaultValue: "\(name) is not connected right now.")
        case .hostRejected(_, let message):
            return message
        case .malformedResponse:
            return String(localized: "supermux.devices.error.malformed", defaultValue: "The other Mac sent an unexpected reply. Update Supermux on both Macs and try again.")
        case .remoteWorkspaceTimedOut:
            return String(localized: "supermux.devices.error.remoteWorkspaceTimedOut", defaultValue: "The workspace did not appear on the other Mac in time.")
        case .nothingToMirror:
            return String(localized: "supermux.devices.error.nothingToMirror", defaultValue: "This workspace has no terminals to show yet.")
        case .windowUnavailable:
            return String(localized: "supermux.devices.error.windowUnavailable", defaultValue: "The window was closed.")
        }
    }

    /// A stable machine-readable code (socket errors, logs).
    var code: String {
        switch self {
        case .unknownDevice: return "unknown_device"
        case .notConnected: return "not_connected"
        case .hostRejected(let code, _): return code ?? "host_rejected"
        case .malformedResponse: return "malformed_response"
        case .remoteWorkspaceTimedOut: return "timeout"
        case .nothingToMirror: return "nothing_to_mirror"
        case .windowUnavailable: return "window_unavailable"
        }
    }

    /// Maps the upstream link error onto the fork's vocabulary.
    static func from(_ error: any Error, deviceName: String) -> any Error {
        guard let linkError = error as? DeviceLinkError else { return error }
        switch linkError {
        case .notConnected, .blocked, .identityUnproven, .identityMismatch:
            return SupermuxDeviceError.notConnected(deviceName)
        case .hostRejected(let code, let message):
            return SupermuxDeviceError.hostRejected(code: code, message: message)
        case .malformedResponse(let method):
            return SupermuxDeviceError.malformedResponse(method)
        }
    }
}

/// What a mirror tab whose terminal another Mac did not make says inside it
/// (the `device-pane-failure-mac-wording` touchpoint). Upstream's card is
/// worded for Cloud machines ("The Cloud operation failed…").
enum SupermuxDevicePaneFailureText {
    @MainActor
    static func detail(machine: SurfaceMachineID) -> String {
        guard let name = SupermuxComposition.devices.device(for: machine)?.displayName else {
            return String(
                localized: "supermux.devices.paneFailure.detailOtherMac",
                defaultValue: "The other Mac couldn’t complete this. Check that it is online and try again."
            )
        }
        return String(
            localized: "supermux.devices.paneFailure.detail",
            defaultValue: "\(name) couldn’t complete this. Check that it is online and try again."
        )
    }
}
