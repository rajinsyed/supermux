import Foundation

/// What a mirror's Files panel says when the owning Mac refuses a file call:
/// each host code becomes a sentence that names that Mac.
enum SupermuxDeviceFileError: LocalizedError, Equatable {
    /// `stale_root`: the workspace's folder there changed since the panel loaded.
    case folderChanged(deviceName: String)
    /// `invalid_params` for a path that escapes the folder (a symlink out of it).
    case outsideFolder(deviceName: String)
    /// `not_found`.
    case missing(deviceName: String)
    /// The file is larger than a preview may copy.
    case tooLarge(deviceName: String)
    /// `rg_missing`: that Mac has no ripgrep.
    case searchNeedsRipgrep(deviceName: String)
    /// Any other refusal, in the host's own words.
    case host(message: String)

    var errorDescription: String? {
        switch self {
        case .folderChanged(let name):
            return String(localized: "supermux.mirror.files.error.folderChanged", defaultValue: "The folder on \(name) changed.")
        case .outsideFolder(let name):
            return String(localized: "supermux.mirror.files.error.outsideFolder", defaultValue: "Outside this workspace's folder on \(name).")
        case .missing(let name):
            return String(localized: "supermux.mirror.files.error.missing", defaultValue: "No longer exists on \(name).")
        case .tooLarge(let name):
            return String(localized: "supermux.mirror.files.error.tooLarge", defaultValue: "Previews of files on \(name) are limited to 8 MB.")
        case .searchNeedsRipgrep(let name):
            return String(localized: "supermux.mirror.files.error.ripgrep", defaultValue: "Search needs ripgrep (rg) on \(name).")
        case .host(let message):
            return message
        }
    }

    /// The preview alert's text for a mirror's failed open (touchpoint
    /// `mirror-file-preview-error`): upstream's alert words only its own
    /// errors, and its Cloud "limited to 1 MB" would be wrong here.
    static func previewAlertText(for error: any Error) -> String? {
        (error as? SupermuxDeviceFileError)?.errorDescription ?? (error as? SupermuxDeviceError)?.errorDescription
    }

    /// Maps a device-facade failure onto the panel's vocabulary; a link
    /// failure (``SupermuxDeviceError/notConnected(_:)``) keeps its own text.
    static func from(_ error: any Error, deviceName: String) -> any Error {
        guard case .hostRejected(let code, let message)? = error as? SupermuxDeviceError else { return error }
        switch code ?? "" {
        case "stale_root": return SupermuxDeviceFileError.folderChanged(deviceName: deviceName)
        case "not_found": return SupermuxDeviceFileError.missing(deviceName: deviceName)
        case "rg_missing": return SupermuxDeviceFileError.searchNeedsRipgrep(deviceName: deviceName)
        case "invalid_params" where message.contains("escapes"):
            return SupermuxDeviceFileError.outsideFolder(deviceName: deviceName)
        default: return SupermuxDeviceFileError.host(message: message)
        }
    }
}
