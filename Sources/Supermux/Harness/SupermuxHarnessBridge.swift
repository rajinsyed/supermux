import Foundation

enum SupermuxHarnessBridgeContract {
    static let handlerName = "supermuxHarness"
    static let resourceDirectoryName = "supermux-harness"
    static let resourceIndexFileName = "index.html"
}

struct SupermuxHarnessBridgeRequest {
    let id: String
    let method: String
    let params: [String: Any]

    init(body: Any) throws {
        guard let dictionary = body as? [String: Any],
              let id = dictionary["id"] as? String,
              let method = dictionary["method"] as? String else {
            throw SupermuxHarnessBridgeError.invalidRequest
        }
        self.id = id
        self.method = method
        self.params = dictionary["params"] as? [String: Any] ?? [:]
    }

    func string(_ key: String) -> String? {
        let trimmed = (params[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw SupermuxHarnessBridgeError.missingParameter(key)
        }
        return value
    }

    func rawString(_ key: String) -> String? {
        params[key] as? String
    }

    func requiredRawString(_ key: String) throws -> String {
        guard let value = rawString(key) else {
            throw SupermuxHarnessBridgeError.missingParameter(key)
        }
        return value
    }

    func bool(_ key: String) -> Bool? {
        params[key] as? Bool
    }

    func integer(_ key: String) -> Int? {
        guard let number = params[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.intValue
    }

    func object(_ key: String) -> [String: Any]? {
        params[key] as? [String: Any]
    }

    func objects(_ key: String) -> [[String: Any]]? {
        params[key] as? [[String: Any]]
    }
}

enum SupermuxHarnessBridgeError: LocalizedError {
    case invalidRequest
    case invalidAttachment
    case missingParameter(String)
    case unsupportedMethod(String)
    case sessionAlreadyRunning
    case sessionNotRunning
    case workingDirectoryUnavailable
    case permissionRequestNotFound
    case invalidBinaryPath
    case sessionUnavailableForRewind
    case openPaneFailed
    case startFailed(String)

    var code: String {
        switch self {
        case .invalidRequest: return "invalidRequest"
        case .invalidAttachment: return "invalidAttachment"
        case .missingParameter: return "missingParameter"
        case .unsupportedMethod: return "unsupportedMethod"
        case .sessionAlreadyRunning: return "sessionAlreadyRunning"
        case .sessionNotRunning: return "sessionNotRunning"
        case .workingDirectoryUnavailable: return "workingDirectoryUnavailable"
        case .permissionRequestNotFound: return "permissionRequestNotFound"
        case .invalidBinaryPath: return "invalidBinaryPath"
        case .sessionUnavailableForRewind: return "sessionUnavailableForRewind"
        case .openPaneFailed: return "openPaneFailed"
        case .startFailed: return "startFailed"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return String(
                localized: "supermux.harness.bridge.error.invalidRequest",
                defaultValue: "Invalid bridge request."
            )
        case .invalidAttachment:
            return String(
                localized: "supermux.harness.bridge.error.invalidAttachment",
                defaultValue: "One or more image attachments are invalid."
            )
        case .missingParameter(let parameter):
            _ = parameter
            return String(
                localized: "supermux.harness.bridge.error.missingParameter",
                defaultValue: "The request is incomplete."
            )
        case .unsupportedMethod(let method):
            _ = method
            return String(
                localized: "supermux.harness.bridge.error.unsupportedMethod",
                defaultValue: "This action is not supported."
            )
        case .sessionAlreadyRunning:
            return String(
                localized: "supermux.harness.bridge.error.sessionAlreadyRunning",
                defaultValue: "Stop the current session or open a new Claude pane."
            )
        case .sessionNotRunning:
            return String(
                localized: "supermux.harness.bridge.error.sessionNotRunning",
                defaultValue: "No Claude session is running."
            )
        case .workingDirectoryUnavailable:
            return String(
                localized: "supermux.harness.bridge.error.workingDirectoryUnavailable",
                defaultValue: "No working directory is available for this pane."
            )
        case .permissionRequestNotFound:
            return String(
                localized: "supermux.harness.bridge.error.permissionRequestNotFound",
                defaultValue: "The permission request is no longer pending."
            )
        case .invalidBinaryPath:
            return String(
                localized: "supermux.harness.bridge.error.invalidBinaryPath",
                defaultValue: "Choose an existing executable file for the Claude binary."
            )
        case .sessionUnavailableForRewind:
            return String(
                localized: "supermux.harness.bridge.error.sessionUnavailableForRewind",
                defaultValue: "This message is not attached to a resumable Claude session."
            )
        case .openPaneFailed:
            return String(
                localized: "supermux.harness.bridge.error.openPaneFailed",
                defaultValue: "Could not open another Claude pane."
            )
        case .startFailed(let message):
            let format = String(
                localized: "supermux.harness.bridge.error.startFailed",
                defaultValue: "Could not start Claude: %@"
            )
            return String(format: format, message)
        }
    }
}
