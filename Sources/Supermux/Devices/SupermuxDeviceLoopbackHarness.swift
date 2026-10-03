#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxSettings
import CmuxSurfaceCatalogModel
import Foundation

/// DEBUG-only E2E harness: a synthetic "Loopback Mac" device whose link talks
/// in-process to this app's own mobile host, so one tagged build is both the
/// viewer Mac and the host Mac. Every `mobile.*`, `mobile.supermux.*` and
/// `device.workspace.*` request the link makes executes on this same app, and
/// this app's workspaces appear as that device's remote workspaces.
///
/// The provider, link and catalog registration are the real upstream types
/// (`DeviceSurfaceProvider`, `DeviceLink`, `SurfaceCatalog.register`); only
/// the dialer (``SupermuxDeviceLoopbackTransportFactory``) and the host-side
/// admission (``SupermuxDeviceLoopbackHostAcceptor``) are loopback-specific.
/// The provider is registered directly instead of through the Devices
/// registry, which needs the account's Iroh directory to list a device.
///
/// Opt-in: launch a DEBUG build with `SUPERMUX_DEBUG_LOOPBACK_DEVICE=1`, or set
/// the `supermux.debug.loopbackDevice` default. Release builds compile none of
/// this. See `plans/supermux-remote-workspaces/LOOPBACK-HARNESS.md`.
@MainActor
final class SupermuxDeviceLoopbackHarness {
    static let environmentKey = "SUPERMUX_DEBUG_LOOPBACK_DEVICE"
    static let defaultsKey = "supermux.debug.loopbackDevice"

    private static var active: SupermuxDeviceLoopbackHarness?

    let identity: SupermuxDeviceLoopbackIdentity
    let provider: DeviceSurfaceProvider
    private let record: DeviceDirectoryRecord
    private let catalog: SurfaceCatalog

    /// Whether this launch opted in (environment first, then the default).
    nonisolated static func isRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty {
            return ["1", "true", "yes"].contains(raw)
        }
        return defaults.bool(forKey: defaultsKey)
    }

    /// Composition entry, called from `SupermuxMobileHostGlue.activateIfNeeded()`
    /// whenever upstream's mobile event plane (re)registers a window. Starts
    /// the harness once, after the auth composition exists.
    static func activateIfRequested() {
        guard active == nil, isRequested(), let auth = AppDelegate.shared?.auth?.coordinator else { return }
        enableDeviceLinkRequests()
        do {
            let harness = try SupermuxDeviceLoopbackHarness(catalog: .shared, auth: auth)
            active = harness
            harness.start()
            cmuxDebugLog("supermux.loopback started machine=\(harness.identity.machine.rawValue) devicesEnabled=\(DevicesFeature.isEnabled)")
        } catch {
            cmuxDebugLog("supermux.loopback failed to start: \(String(describing: error))")
        }
    }

    /// `DeviceLink` refuses every request unless `DevicesFeature.isEnabled`.
    /// Default the discovery opt-in and the Cloud beta toggle on for this
    /// process only (the registration domain, never persisted); an explicit
    /// user choice still wins.
    private static func enableDeviceLinkRequests() {
        UserDefaults.standard.register(defaults: [
            DevicesCatalogSection().discoveryEnabled.userDefaultsKey: true,
            BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey: true,
        ])
    }

    init(catalog: SurfaceCatalog, auth: AuthCoordinator, identity: SupermuxDeviceLoopbackIdentity = .init()) throws {
        let acceptor = try SupermuxDeviceLoopbackHostAcceptor(identity: identity)
        let record = try identity.directoryRecord(
            deviceName: String(localized: "supermux.devices.loopback.name", defaultValue: "Loopback Mac")
        )
        // Transport admission never asks for a Stack token; the source only
        // satisfies the runtime's shape and fails closed if anything does.
        let tokens = HiveAccountTokenSource(
            auth: auth,
            identity: AuthenticatedSessionIdentity(generation: 0, accountID: SupermuxDeviceLoopbackIdentity.bindingID),
            teamID: nil
        )
        // The dialer owns the acceptor: link → runtime → factory → acceptor.
        let runtime = DeviceLinkRuntime(
            tokens: tokens,
            routeSelector: DeviceRouteSelector(allowsIroh: true, allowsLegacyTailscale: false)
        ).supermuxReplacingTransportFactory(
            SupermuxDeviceLoopbackTransportFactory { [acceptor] transport in acceptor.accept(transport) }
        )
        let link = DeviceLink(record: record, runtime: runtime, authorization: LoopbackAuthorization())
        self.identity = identity
        self.record = record
        self.catalog = catalog
        provider = DeviceSurfaceProvider(record: record, link: link, catalog: catalog)
    }

    /// Registers the provider like the Devices registry does for a new row,
    /// then hands it the record, which makes the link dial. The harness then
    /// lives as long as the app; there is no stop path to keep in sync.
    func start() {
        catalog.register(provider)
        provider.update(record: record)
        SupermuxComposition.devices.registerLoopback(identity.instance)
    }
}

/// The loopback has no pairing: its one route is Iroh-kind, which the route
/// selector admits without consulting a Tailscale grant.
@MainActor
private final class LoopbackAuthorization: DeviceLinkAuthorizationSource {
    let pairedDevices: [DevicePairedDevice] = []
    let authorizationDidChangeNotification = Notification.Name("supermux.debug.loopbackDevice.authorizationDidChange")

    func authorization(for instance: SurfaceDeviceInstanceID, route: CmxAttachRoute) -> CmxLegacyTailscaleAuthorizationEvidence? {
        nil
    }
}
#endif
