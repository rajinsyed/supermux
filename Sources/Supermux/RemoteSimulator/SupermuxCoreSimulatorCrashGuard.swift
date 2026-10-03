import AppKit
import Foundation
import os

/// Keeps a crash inside CoreSimulator from ending the app again and again.
///
/// Upstream loads private Simulator frameworks only in its re-executed worker
/// child, so a crash there never takes the app down. The device list is read
/// from CoreSimulator in this process (``SupermuxCoreSimulatorDevices``), so a
/// crash inside it would end the app, terminals included. Its load (`dlopen`,
/// the service context, the device set) is the version-sensitive part, so it
/// is bracketed by a marker file, and a marker left behind means a run ended
/// inside a load.
///
/// That load is also where a cold CoreSimulatorService makes the app wait, so
/// a run can end there without any crash. A normal quit or a logout removes
/// the marker (`NSApplication.willTerminateNotification`); a force quit, a
/// kill or a power loss cannot. So one interrupted load proves nothing: only
/// two in a row for the same CoreSimulator build turn it off in-process (the
/// panels ask `simctl`, as upstream does) until another Xcode brings a new
/// build, and a load that succeeds clears the count. Deleting
/// `supermux-coresimulator-interrupted` in the app's Application Support
/// folder allows it again.
struct SupermuxCoreSimulatorCrashGuard: Sendable {
    /// Interrupted loads in a row that turn a CoreSimulator build off in-process.
    static let interruptionsToDisable = 2

    private let loadingMarker: URL
    /// `<build>\n<interrupted loads in a row>`.
    private let interruptionRecord: URL
    /// The installed CoreSimulator's build (its `CFBundleVersion`).
    private let build: String

    init(frameworkPath: String, fileManager: FileManager = .default) {
        let frameworkDirectory = URL(fileURLWithPath: frameworkPath).deletingLastPathComponent()
        build = Bundle(url: frameworkDirectory)?.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "supermux", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        loadingMarker = directory.appendingPathComponent("supermux-coresimulator-loading")
        interruptionRecord = directory.appendingPathComponent("supermux-coresimulator-interrupted")
        // The first guard's one-strike record, which a quit during a slow load could write.
        try? fileManager.removeItem(at: directory.appendingPathComponent("supermux-coresimulator-crashed"))
    }

    /// Whether this CoreSimulator build may be loaded: fewer than
    /// ``interruptionsToDisable`` interrupted loads in a row. A marker left by
    /// the last run counts as one first.
    func allowsLoading() -> Bool {
        var record = interruptions()
        if let interrupted = try? String(contentsOf: loadingMarker, encoding: .utf8), !interrupted.isEmpty {
            let count = record?.build == interrupted ? (record?.count ?? 0) + 1 : 1
            record = (interrupted, count)
            try? "\(interrupted)\n\(count)".write(to: interruptionRecord, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: loadingMarker)
        }
        guard let record, record.build == build else { return true }
        return record.count < Self.interruptionsToDisable
    }

    func willLoad() {
        try? build.write(to: loadingMarker, atomically: true, encoding: .utf8)
        Self.removeOnTermination(loadingMarker)
    }

    /// The load returned. One that succeeded clears the interruption count.
    func didLoad(succeeded: Bool) {
        try? FileManager.default.removeItem(at: loadingMarker)
        if succeeded {
            try? FileManager.default.removeItem(at: interruptionRecord)
        }
    }

    private func interruptions() -> (build: String, count: Int)? {
        guard let text = try? String(contentsOf: interruptionRecord, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 2, let count = Int(lines[1]) else { return nil }
        return (String(lines[0]), count)
    }

    private static let terminationCleanupInstalled = OSAllocatedUnfairLock(initialState: false)

    /// A quit or logout while the load is open is no crash: remove the marker
    /// as the app terminates (the load itself never returns then).
    private static func removeOnTermination(_ marker: URL) {
        let install = terminationCleanupInstalled.withLock { installed -> Bool in
            defer { installed = true }
            return !installed
        }
        guard install else { return }
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            try? FileManager.default.removeItem(at: marker)
        }
    }
}
