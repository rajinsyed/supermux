import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// UI-02: every supermux entry point is hidden unless the host advertises
/// the matching capability; present capability = visible.
@Suite struct SupermuxMobileCapabilitiesTests {
    @Test func emptyHostCapabilitiesHideEverySupermuxEntryPoint() {
        let capabilities = SupermuxMobileCapabilities(hostCapabilities: [])
        #expect(!capabilities.supportsProjects)
        #expect(!capabilities.supportsActivity)
        #expect(!capabilities.supportsWorktrees)
        #expect(!capabilities.supportsPresets)
        #expect(!capabilities.supportsChanges)
        #expect(!capabilities.supportsRun)
        #expect(!capabilities.supportsActions)
        #expect(!capabilities.supportsFiles)
        for capability in SupermuxMobileCapability.all {
            #expect(!capabilities.contains(capability))
        }
    }

    @Test func upstreamHostCapabilitiesWithoutProjectsV1ReportHidden() {
        // An upstream cmux Mac advertises plenty of non-supermux capabilities;
        // none of them may light up a supermux entry point.
        let capabilities = SupermuxMobileCapabilities(hostCapabilities: [
            "workspace.groups.v1",
            "terminal.render_grid.v1",
            "workspace.actions.v1",
        ])
        #expect(!capabilities.supportsProjects)
        for capability in SupermuxMobileCapability.all {
            #expect(!capabilities.contains(capability))
        }
    }

    @Test func projectsV1AloneShowsOnlyTheProjectsEntryPoint() {
        let capabilities = SupermuxMobileCapabilities(
            hostCapabilities: [SupermuxMobileCapability.projectsV1.rawValue]
        )
        #expect(capabilities.supportsProjects)
        #expect(!capabilities.supportsActivity)
        #expect(!capabilities.supportsWorktrees)
        #expect(!capabilities.supportsPresets)
        #expect(!capabilities.supportsChanges)
        #expect(!capabilities.supportsRun)
        #expect(!capabilities.supportsActions)
        #expect(!capabilities.supportsFiles)
    }

    @Test func everyAccessorMatchesItsWireString() {
        // One accessor per supermux.*.v1: turning on exactly one raw wire
        // string must flip exactly its accessor.
        let accessors: [(SupermuxMobileCapability, (SupermuxMobileCapabilities) -> Bool)] = [
            (.projectsV1, \.supportsProjects),
            (.activityV1, \.supportsActivity),
            (.worktreesV1, \.supportsWorktrees),
            (.presetsV1, \.supportsPresets),
            (.changesV1, \.supportsChanges),
            (.runV1, \.supportsRun),
            (.actionsV1, \.supportsActions),
            (.filesV1, \.supportsFiles),
        ]
        #expect(accessors.count == SupermuxMobileCapability.all.count)
        for (capability, accessor) in accessors {
            let on = SupermuxMobileCapabilities(hostCapabilities: [capability.rawValue])
            #expect(accessor(on), "\(capability.rawValue) should flip its accessor")
            #expect(on.contains(capability))
            for (other, otherAccessor) in accessors where other != capability {
                #expect(!otherAccessor(on), "\(capability.rawValue) must not flip \(other.rawValue)")
            }
        }
    }

    @Test func unknownAndDuplicateStringsAreTolerated() {
        let capabilities = SupermuxMobileCapabilities(hostCapabilities: [
            "supermux.projects.v1",
            "supermux.projects.v1",
            "supermux.time-travel.v9",
            "",
        ])
        #expect(capabilities.supportsProjects)
        #expect(!capabilities.supportsFiles)
    }
}
