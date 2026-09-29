import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

extension SupermuxDevices {
    /// A stream of per-device events for one consumer. Each call returns an
    /// independent stream; it ends when the consumer stops iterating.
    ///
    /// ```swift
    /// for await event in devices.events() {
    ///     if case .topic(let machine, .projectsUpdated, _) = event { reload(machine) }
    /// }
    /// ```
    func events() -> AsyncStream<SupermuxDeviceEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(128)) { continuation in
            let id = UUID()
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.eventContinuations[id] = nil }
            }
        }
    }

    // MARK: - Link intake (from the DeviceLink touchpoint, via SupermuxDeviceLinkEvents)

    /// The link connected and its post-connect fetch finished.
    func linkDidConnect(_ instance: SurfaceDeviceInstanceID) {
        fetchedInstances.insert(instance)
        resetCapabilities(instance)
        // Learn the capabilities now: a mirror's key resolver reads them
        // synchronously on every key press.
        Task { [weak self] in _ = await self?.hostCapabilities(on: .device(instance)) }
        emit(.linkConnected(.device(instance)))
        scheduleRefresh()
    }

    /// The live link went away.
    func linkDidDisconnect(_ instance: SurfaceDeviceInstanceID) {
        fetchedInstances.remove(instance)
        resetCapabilities(instance)
        emit(.linkLost(.device(instance)))
        scheduleRefresh()
    }

    /// A `supermux.*` envelope arrived on a link.
    func receive(topic rawTopic: String, payload: Data?, from instance: SurfaceDeviceInstanceID) {
        guard let topic = SupermuxMobileTopic(rawValue: rawTopic) else { return }
        emit(.topic(.device(instance), topic, payload: payload))
        scheduleRefresh()
    }

    private func emit(_ event: SupermuxDeviceEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func resetCapabilities(_ instance: SurfaceDeviceInstanceID) {
        capabilityTasks.removeValue(forKey: instance)?.cancel()
        capabilitiesByInstance[instance] = nil
    }
}
