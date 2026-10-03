import Foundation

/// Keeps a crash inside CoreSimulator to one per CoreSimulator build.
///
/// Upstream loads private Simulator frameworks only in its re-executed worker
/// child, so a crash there never takes the app down. The device list is read
/// from CoreSimulator in this process (``SupermuxCoreSimulatorDevices``), so a
/// crash inside it would end the app, terminals included. Its load (`dlopen`,
/// the service context, the device set) is the version-sensitive part, so it
/// is bracketed by a marker file: one left behind means the last run died while
/// loading, and that CoreSimulator build is not loaded in-process again (the
/// panels ask `simctl`, as upstream does) until another Xcode brings a new one.
/// Deleting `supermux-coresimulator-crashed` in the app's Application Support
/// folder allows it again.
struct SupermuxCoreSimulatorCrashGuard: Sendable {
    private let loadingMarker: URL
    private let crashRecord: URL
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
        crashRecord = directory.appendingPathComponent("supermux-coresimulator-crashed")
    }

    /// Whether this CoreSimulator build may be loaded: no crash recorded for it.
    /// A marker left by the last run becomes that record first.
    func allowsLoading() -> Bool {
        if let crashedBuild = try? String(contentsOf: loadingMarker, encoding: .utf8) {
            try? crashedBuild.write(to: crashRecord, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: loadingMarker)
        }
        return (try? String(contentsOf: crashRecord, encoding: .utf8)) != build
    }

    func willLoad() {
        try? build.write(to: loadingMarker, atomically: true, encoding: .utf8)
    }

    func didLoad() {
        try? FileManager.default.removeItem(at: loadingMarker)
    }
}
