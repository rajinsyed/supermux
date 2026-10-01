public import Foundation

/// Each project's file facts for the projects list another Mac or a phone asks
/// for (``SupermuxMobileProjectsPayloadBuilder/FileFacts``).
///
/// Today each project is probed inline on the caller.
public final class SupermuxProjectFileFacts: @unchecked Sendable {
    /// The host's shared instance.
    public static let shared = SupermuxProjectFileFacts()
    /// How long a list waits for its probes.
    public static let timeout: TimeInterval = 2

    private let probe: @Sendable (SupermuxProject) -> SupermuxMobileProjectsPayloadBuilder.FileFacts

    /// - Parameter probe: Probes one project (tests inject a fake).
    public init(
        probe: @escaping @Sendable (SupermuxProject) -> SupermuxMobileProjectsPayloadBuilder.FileFacts = {
            SupermuxMobileProjectsPayloadBuilder().fileFacts(for: $0)
        }
    ) {
        self.probe = probe
    }

    /// Each project's facts keyed by ``SupermuxMobileProjectsPayloadBuilder/fileFactsKey(for:)``.
    public func facts(
        for projects: [SupermuxProject],
        timeout: TimeInterval = SupermuxProjectFileFacts.timeout
    ) async -> [String: SupermuxMobileProjectsPayloadBuilder.FileFacts] {
        var facts: [String: SupermuxMobileProjectsPayloadBuilder.FileFacts] = [:]
        for project in projects {
            facts[SupermuxMobileProjectsPayloadBuilder.fileFactsKey(for: project)] = probe(project)
        }
        return facts
    }
}
