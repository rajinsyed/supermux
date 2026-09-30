import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// The fork's hook into upstream `DeviceLink` (touchpoint
/// `device-link-supermux-events`, SUPERMUX-TOUCHPOINTS.md #517): the extra
/// topics every link subscribes to, and the three signals the link forwards.
/// Everything lands on ``SupermuxDevices`` (``SupermuxComposition/devices``).
@MainActor
enum SupermuxDeviceLinkEvents {
    /// The `supermux.*` topics each device link subscribes to, on top of
    /// upstream's `DeviceLink.eventTopics`. The host accepts any topic set.
    nonisolated static let topics: Set<String> = Set(SupermuxMobileTopic.allCases.map(\.rawValue))

    /// A `supermux.*` envelope arrived on the link for `instance`.
    static func receive(instance: SurfaceDeviceInstanceID, topic: String, payload: Data?) {
        SupermuxComposition.devices.receive(topic: topic, payload: payload, from: instance)
    }

    /// The link (re)connected and its post-connect `mobile.sync.fetch` ran.
    static func linkConnected(instance: SurfaceDeviceInstanceID) {
        SupermuxComposition.devices.linkDidConnect(instance)
    }

    /// The link was live and is now gone.
    static func linkLost(instance: SurfaceDeviceInstanceID) {
        SupermuxComposition.devices.linkDidDisconnect(instance)
    }
}
