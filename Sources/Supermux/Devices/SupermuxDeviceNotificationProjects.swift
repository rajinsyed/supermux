import CMUXMobileCore
import Foundation
import SupermuxMobileCore

/// The project a notification from another Mac belongs to, as THAT Mac
/// resolved it (its feed row's `supermux_project`).
///
/// The viewer's copy is a `.deviceMac` record on a local mirror pane whose
/// directory is not the remote checkout, so re-resolving the project from
/// local paths gives the wrong project or none. The device delivery wrapper
/// remembers the remote project under the record's correlation key just
/// before the store builds the record, and
/// ``SupermuxNotificationProjectBridge/project(for:)`` reads it back at the
/// store's single construction site.
@MainActor
final class SupermuxDeviceNotificationProjects {
    /// Enough for every row a feed carries; oldest keys are evicted first.
    static let capacity = 512

    private var projects: [String: SupermuxNotificationProject] = [:]
    private var order: [String] = []

    /// Remembers (or forgets, when `project` is `nil`) a row's remote project.
    func remember(_ project: SupermuxNotificationProject?, forCorrelationKey key: String) {
        guard let project else {
            if projects.removeValue(forKey: key) != nil { order.removeAll { $0 == key } }
            return
        }
        if projects.updateValue(project, forKey: key) == nil {
            order.append(key)
            if order.count > Self.capacity {
                projects.removeValue(forKey: order.removeFirst())
            }
        }
    }

    /// The remembered remote project for a correlation key.
    func project(forCorrelationKey key: String) -> SupermuxNotificationProject? {
        projects[key]
    }

    /// Row id → project from a `notification.feed.list` reply. Pure, so the
    /// feed parser (not main-actor isolated) can call it.
    nonisolated static func projects(inFeedResponse response: [String: Any]) -> [String: SupermuxNotificationProject] {
        var result: [String: SupermuxNotificationProject] = [:]
        for case let item as [String: Any] in response["notifications"] as? [Any] ?? [] {
            guard let id = item["id"] as? String, !id.isEmpty,
                  let object = item["supermux_project"] as? [String: Any],
                  JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let project = try? JSONDecoder().decode(SupermuxNotificationProject.self, from: data),
                  !project.id.isEmpty else { continue }
            result[id] = project
        }
        return result
    }
}

extension SupermuxNotificationProjectBridge {
    /// The project for a notification about to be recorded: another Mac's own
    /// project for a record mirrored from it (never a local-path guess), else
    /// this Mac's resolution for the workspace.
    static func project(for request: TerminalNotificationPolicyRequest) -> SupermuxNotificationProject? {
        guard SupermuxPhoneForwardGate.isMirroredFromDevice(request.origin) else {
            return project(forWorkspace: request.tabId)
        }
        return request.correlationKey.flatMap {
            SupermuxComposition.deviceNotificationProjects.project(forCorrelationKey: $0)
        }
    }
}
