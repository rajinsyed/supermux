import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

extension SupermuxDevices {
    /// One JSON-RPC call to the device's mobile host (any method, including
    /// `mobile.supermux.*`; same-account Mac peers get no per-method narrowing).
    ///
    /// - Parameters:
    ///   - method: The wire method, e.g. `mobile.supermux.projects.list`.
    ///   - params: The JSON params object.
    ///   - machine: The device machine.
    ///   - timeout: An explicit reply deadline, for the DEBUG socket driver
    ///     only. `nil` (every caller) uses the method's audited deadline,
    ///     ``SupermuxDeviceReplyDeadline``: a missed deadline makes the whole
    ///     link reconnect, so long host work gets a deadline that outlasts it
    ///     and everything else keeps the link's default.
    /// - Returns: The host's result object.
    /// - Throws: ``SupermuxDeviceError``.
    func request(
        _ method: String,
        params: [String: Any] = [:],
        on machine: SurfaceMachineID,
        timeout: Duration? = nil
    ) async throws -> [String: Any] {
        guard let provider = provider(for: machine) else {
            throw SupermuxDeviceError.unknownDevice(machine.rawValue)
        }
        let name = device(for: machine)?.displayName ?? provider.record.displayName
        guard provider.link.isConnected else { throw SupermuxDeviceError.notConnected(name) }
        do {
            return try await provider.link.request(
                method,
                params: params,
                timeoutNanoseconds: (timeout ?? SupermuxDeviceReplyDeadline.forMethod(method)).map(Self.nanoseconds)
            )
        } catch {
            throw SupermuxDeviceError.from(error, deviceName: name)
        }
    }

    /// A typed call to a `mobile.supermux.*` method.
    func request(
        _ method: SupermuxMobileMethod,
        params: [String: Any] = [:],
        on machine: SurfaceMachineID,
        timeout: Duration? = nil
    ) async throws -> [String: Any] {
        try await request(method.rawValue, params: params, on: machine, timeout: timeout)
    }

    /// A call whose result (or the value at `resultKey`) decodes as a
    /// `SupermuxMobileCore` DTO: plain `JSONDecoder`, no key or date strategy —
    /// the DTOs carry snake_case in their own `CodingKeys` (the
    /// ``SupermuxWireJSON`` convention).
    ///
    /// ```swift
    /// let projects = try await devices.request(
    ///     SupermuxMobileMethod.projectsList.rawValue, on: machine,
    ///     resultKey: "projects", as: [SupermuxProjectDTO].self)
    /// ```
    func request<Response: Decodable>(
        _ method: String,
        params: [String: Any] = [:],
        on machine: SurfaceMachineID,
        timeout: Duration? = nil,
        resultKey: String? = nil,
        as type: Response.Type
    ) async throws -> Response {
        let object = try await request(method, params: params, on: machine, timeout: timeout)
        let value: Any = resultKey.map { object[$0] ?? NSNull() } ?? object
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SupermuxDeviceError.malformedResponse(method)
        }
    }

    // MARK: - Host capabilities

    /// The waits before asking a busy host for its capabilities again (about
    /// 8 s in all), see ``fetchHostCapabilities(on:)``.
    private static let busyHostRetryDelays: [Duration] = [
        .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4),
    ]

    /// The capabilities the device's host advertises (`mobile.host.status`),
    /// fetched once per link connection. `nil` when unknown (not connected,
    /// or the host did not answer).
    func hostCapabilities(on machine: SurfaceMachineID) async -> Set<String>? {
        guard let instance = machine.deviceInstance else { return nil }
        if let cached = capabilitiesByInstance[instance] { return cached }
        if let task = capabilityTasks[instance] { return await task.value }
        let task = Task { @MainActor [weak self] () -> Set<String>? in
            await self?.fetchHostCapabilities(on: machine)
        }
        capabilityTasks[instance] = task
        let capabilities = await task.value
        if capabilityTasks[instance] == task {
            capabilityTasks[instance] = nil
            if let capabilities { capabilitiesByInstance[instance] = capabilities }
        }
        return capabilities
    }

    /// Asks the host for its capabilities. A host that answers `server_busy`
    /// never ran the request (its per-connection request quota was full, as
    /// it is right after a reconnect while every mirrored terminal
    /// re-attaches), so it is asked again after a short wait; otherwise the
    /// connection would go without capabilities until the next reconnect, and
    /// a mirror would type through upstream's text path. Any other failure is
    /// the answer for this connection. A link edge cancels the wait.
    private func fetchHostCapabilities(on machine: SurfaceMachineID) async -> Set<String>? {
        var delays = Self.busyHostRetryDelays[...]
        while true {
            do {
                let status = try await request("mobile.host.status", on: machine)
                return (status["capabilities"] as? [String]).map { Set($0) }
            } catch let error as SupermuxDeviceError where error.code == "server_busy" {
                guard let delay = delays.popFirst() else { return nil }
                #if DEBUG
                cmuxDebugLog("supermux.devices capabilities: host busy, asking again in \(delay)")
                #endif
                guard (try? await Task.sleep(for: delay)) != nil else { return nil }
            } catch {
                return nil
            }
        }
    }

    /// The capabilities already known for this link connection, without a round trip.
    func cachedHostCapabilities(on machine: SurfaceMachineID) -> Set<String>? {
        machine.deviceInstance.flatMap { capabilitiesByInstance[$0] }
    }

    /// Whether the device's host advertises a fork capability.
    func supports(_ capability: SupermuxMobileCapability, on machine: SurfaceMachineID) async -> Bool {
        await hostCapabilities(on: machine)?.contains(capability.rawValue) == true
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        let total = Double(seconds) * 1e9 + Double(attoseconds) / 1e9
        return UInt64(max(0, total))
    }
}
