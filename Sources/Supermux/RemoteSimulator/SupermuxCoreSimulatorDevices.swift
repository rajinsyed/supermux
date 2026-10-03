import CmuxSimulator
import Darwin
import Foundation
import ObjectiveC.runtime
import os

/// This Mac's simulators, read in-process from CoreSimulator (the framework
/// `simctl` and upstream's simulator worker use) instead of launching
/// `xcrun simctl list`.
///
/// CoreSimulator keeps its device set current from CoreSimulatorService's
/// notifications (a create, boot, shutdown or delete shows at once), so every
/// read is fresh and launches no process. On a Mac where new processes stall
/// in dyld before `main` (every `simctl` took 20–22 s there, 2026-10-03), the
/// list still comes back in milliseconds.
///
/// Private API, reached through the Objective-C runtime as upstream's worker
/// does (`SimulatorDeviceResolver`, `SimulatorFrameworkLoader`). Every call
/// runs on one serial queue, never the main thread, and a caller waits at most
/// a few seconds for it.
final class SupermuxCoreSimulatorDevices: @unchecked Sendable {
    static let shared = SupermuxCoreSimulatorDevices()

    enum Failure: Error {
        /// CoreSimulator cannot be used here (no Xcode, or its API changed):
        /// ask `simctl` instead.
        case unavailable(String)
        /// CoreSimulator did not answer in time.
        case slow
    }

    private static let frameworkPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"

    private let queue = DispatchQueue(label: "supermux.coresimulator.devices", qos: .userInitiated)
    /// The service context and its default device set once loaded; touched only on `queue`.
    private var context: NSObject?
    private var deviceSet: NSObject?
    /// Why CoreSimulator can never load in this process; touched only on `queue`.
    private var permanentFailure: String?

    /// The installed simulators.
    /// - Throws: ``Failure/unavailable(_:)`` when CoreSimulator cannot be
    ///   used, ``Failure/slow`` when it did not answer within `timeout`.
    func devices(timeout: TimeInterval = 8) async throws -> [SimulatorDevice] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SimulatorDevice], Error>) in
            let once = SupermuxResumeOnce(continuation)
            queue.async {
                once.resume(with: Result { try self.readDevices() })
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                once.resume(with: .failure(Failure.slow))
            }
        }
    }

    /// The live state of `udid`, or nil when CoreSimulator cannot say.
    func state(of udid: String) async -> SimulatorDeviceState? {
        guard let devices = try? await devices() else { return nil }
        return devices.first { $0.id.caseInsensitiveCompare(udid) == .orderedSame }?.state
    }

    // MARK: - On the queue

    private func readDevices() throws -> [SimulatorDevice] {
        let set = try loadedDeviceSet()
        guard let records = Self.value(set, "devices") as? [NSObject] else {
            throw Failure.unavailable("CoreSimulator's device set has no device list")
        }
        return records.compactMap(Self.device(from:))
    }

    private func loadedDeviceSet() throws -> NSObject {
        if let context, let deviceSet {
            // CoreSimulator reconnects after its service restarts; until then
            // the set may be stale, so this read asks `simctl`.
            guard (Self.value(context, "valid") as? NSNumber)?.boolValue != false else {
                self.context = nil
                self.deviceSet = nil
                throw Failure.unavailable("CoreSimulator's service connection is not valid")
            }
            return deviceSet
        }
        if let permanentFailure { throw Failure.unavailable(permanentFailure) }
        guard FileManager.default.fileExists(atPath: Self.frameworkPath),
              dlopen(Self.frameworkPath, RTLD_NOW | RTLD_GLOBAL) != nil,
              let contextClass = NSClassFromString("SimServiceContext") else {
            permanentFailure = "CoreSimulator could not be loaded"
            throw Failure.unavailable(permanentFailure ?? "")
        }
        let developerDirectory = Self.developerDirectory()
        guard let loadedContext = Self.classCall(
            contextClass,
            "sharedServiceContextForDeveloperDir:error:",
            developerDirectory as NSString
        ), let set = Self.call(loadedContext, "defaultDeviceSetWithError:") else {
            // The service may be restarting: try again on the next read.
            throw Failure.unavailable("CoreSimulator has no device set for \(developerDirectory)")
        }
        #if DEBUG
        cmuxDebugLog("supermux.simulators CoreSimulator device set loaded in-process (\(developerDirectory))")
        #endif
        context = loadedContext
        deviceSet = set
        return set
    }

    // MARK: - Mapping

    /// One CoreSimulator `SimDevice` as upstream's `simctl list` parser
    /// (`SimulatorControlService.discoverDevices`) would describe it.
    private static func device(from record: NSObject) -> SimulatorDevice? {
        guard let udid = (value(record, "UDID") as? NSUUID)?.uuidString,
              let name = value(record, "name") as? String else { return nil }
        let runtime = value(record, "runtime") as? NSObject
        let deviceType = value(record, "deviceType") as? NSObject
        let runtimeIdentifier = value(record, "runtimeIdentifier") as? String
            ?? runtime.flatMap { value($0, "identifier") as? String } ?? ""
        let deviceTypeIdentifier = value(record, "deviceTypeIdentifier") as? String
            ?? deviceType.flatMap { value($0, "identifier") as? String } ?? ""
        let productFamily = deviceType.flatMap { value($0, "productFamily") as? String }
        return SimulatorDevice(
            id: udid,
            name: name,
            runtimeIdentifier: runtimeIdentifier,
            runtimeName: runtime.flatMap { value($0, "name") as? String } ?? runtimeName(from: runtimeIdentifier),
            deviceTypeIdentifier: deviceTypeIdentifier,
            family: family(productFamily ?? deviceTypeIdentifier),
            state: SimulatorDeviceState(simctlState: value(record, "stateString") as? String ?? ""),
            isAvailable: (value(record, "available") as? NSNumber)?.boolValue ?? (runtime != nil),
            lastBootedAt: value(record, "lastBootedAt") as? Date
        )
    }

    private static func family(_ value: String) -> SimulatorDeviceFamily {
        let value = value.lowercased()
        if value.contains("iphone") { return .iPhone }
        if value.contains("ipad") { return .iPad }
        if value.contains("watch") { return .watch }
        if value.contains("vision") { return .vision }
        if value.contains("tv") { return .television }
        return .unknown
    }

    /// "iOS 27.0" from `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
    private static func runtimeName(from identifier: String) -> String {
        let suffix = identifier.components(separatedBy: ".SimRuntime.").last ?? identifier
        let pieces = suffix.split(separator: "-")
        guard pieces.count >= 2 else { return suffix }
        return "\(pieces[0]) \(pieces.dropFirst().joined(separator: "."))"
    }

    // MARK: - Objective-C runtime

    /// A property, or nil when the object has no such getter (never an
    /// Objective-C exception from KVC).
    private static func value(_ object: NSObject, _ key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    private static func call(_ target: NSObject, _ selectorName: String) -> NSObject? {
        let selector = NSSelectorFromString(selectorName)
        guard target.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: target), selector) else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        var error: NSError?
        return unsafeBitCast(implementation, to: Function.self)(target, selector, &error) as? NSObject
    }

    private static func classCall(_ target: AnyClass, _ selectorName: String, _ argument: AnyObject) -> NSObject? {
        let selector = NSSelectorFromString(selectorName)
        guard class_getClassMethod(target, selector) != nil,
              let metaClass = object_getClass(target),
              let implementation = class_getMethodImplementation(metaClass, selector) else { return nil }
        typealias Function = @convention(c) (AnyClass, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        var error: NSError?
        return unsafeBitCast(implementation, to: Function.self)(target, selector, argument, &error) as? NSObject
    }

    /// The active Xcode: `DEVELOPER_DIR`, else `xcode-select`'s choice read from
    /// its link (no process launch), else the default Xcode.
    private static func developerDirectory() -> String {
        if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !configured.isEmpty {
            return configured
        }
        if let selected = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"),
           !selected.isEmpty {
            return selected
        }
        return "/Applications/Xcode.app/Contents/Developer"
    }
}
