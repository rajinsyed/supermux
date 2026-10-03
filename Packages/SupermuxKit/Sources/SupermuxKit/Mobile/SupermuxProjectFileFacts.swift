public import Foundation

/// Each project's file facts for the projects list another Mac or a phone asks
/// for (``SupermuxMobileProjectsPayloadBuilder/FileFacts``), probed so that no
/// project can hold the list up.
///
/// A project in ~/Documents while macOS's privacy prompt for that folder is
/// unanswered (nobody answers it on a headless Mac) blocks its icon stat in
/// the kernel. Run inline, that held `projects.list` past the viewer's 20 s
/// deadline, so the device link reconnected every ~20 s and each retry
/// stranded one more cooperative-pool thread until the app wedged. Here each
/// project is probed through ``SupermuxBoundedLookups`` (its own thread, one
/// probe per project at a time, an answer at the bound), and a project whose
/// probe is still running keeps the facts it last had, so its icon does not
/// flicker away on the phone.
public final class SupermuxProjectFileFacts: @unchecked Sendable {
    /// The host's shared instance.
    public static let shared = SupermuxProjectFileFacts()
    /// How long a list waits for its probes.
    public static let timeout: TimeInterval = 2

    private let probe: @Sendable (SupermuxProject) -> SupermuxMobileProjectsPayloadBuilder.FileFacts
    private let lookups = SupermuxBoundedLookups<SupermuxMobileProjectsPayloadBuilder.FileFacts>()
    private let lock = NSLock()
    private var known: [String: SupermuxMobileProjectsPayloadBuilder.FileFacts] = [:]

    /// - Parameter probe: Probes one project (tests inject a fake).
    public init(
        probe: @escaping @Sendable (SupermuxProject) -> SupermuxMobileProjectsPayloadBuilder.FileFacts = {
            SupermuxMobileProjectsPayloadBuilder().fileFacts(for: $0)
        }
    ) {
        self.probe = probe
    }

    /// Each project's facts keyed by ``SupermuxMobileProjectsPayloadBuilder/fileFactsKey(for:)``:
    /// probed within `timeout`, else the last facts it had; a project never
    /// probed in time is absent.
    public func facts(
        for projects: [SupermuxProject],
        timeout: TimeInterval = SupermuxProjectFileFacts.timeout
    ) async -> [String: SupermuxMobileProjectsPayloadBuilder.FileFacts] {
        let probe = self.probe
        var requests: [String: @Sendable () -> SupermuxMobileProjectsPayloadBuilder.FileFacts] = [:]
        for project in projects {
            requests[SupermuxMobileProjectsPayloadBuilder.fileFactsKey(for: project)] = { probe(project) }
        }
        let fresh = await lookups.values(requests, timeout: timeout)
        return remember(fresh, keys: Set(requests.keys))
    }

    /// Records the fresh facts; answers the last facts known for `keys`.
    private func remember(
        _ fresh: [String: SupermuxMobileProjectsPayloadBuilder.FileFacts],
        keys: Set<String>
    ) -> [String: SupermuxMobileProjectsPayloadBuilder.FileFacts] {
        lock.lock()
        defer { lock.unlock() }
        known.merge(fresh) { _, new in new }
        return known.filter { keys.contains($0.key) }
    }
}
