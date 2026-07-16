import Foundation
import Testing
@testable import SupermuxMobileCore

@Suite struct SupermuxMobileTopicTests {
    @Test func topicsMatchTheWireContract() {
        #expect(SupermuxMobileTopic.projectsUpdated.rawValue == "supermux.projects.updated")
        #expect(SupermuxMobileTopic.worktreesUpdated.rawValue == "supermux.worktrees.updated")
        #expect(SupermuxMobileTopic.changesUpdated.rawValue == "supermux.changes.updated")
        #expect(SupermuxMobileTopic.runUpdated.rawValue == "supermux.run.updated")
    }

    @Test func allExposesEveryTopicExactlyOnce() {
        #expect(SupermuxMobileTopic.all == SupermuxMobileTopic.allCases)
        #expect(SupermuxMobileTopic.all.count == 4)
        #expect(Set(SupermuxMobileTopic.all).count == 4)
    }
}

@Suite struct SupermuxMobileCapabilityTests {
    @Test func capabilitiesMatchTheWireContract() {
        #expect(SupermuxMobileCapability.projectsV1.rawValue == "supermux.projects.v1")
        #expect(SupermuxMobileCapability.activityV1.rawValue == "supermux.activity.v1")
        #expect(SupermuxMobileCapability.worktreesV1.rawValue == "supermux.worktrees.v1")
        #expect(SupermuxMobileCapability.presetsV1.rawValue == "supermux.presets.v1")
        #expect(SupermuxMobileCapability.changesV1.rawValue == "supermux.changes.v1")
        #expect(SupermuxMobileCapability.runV1.rawValue == "supermux.run.v1")
        #expect(SupermuxMobileCapability.actionsV1.rawValue == "supermux.actions.v1")
        #expect(SupermuxMobileCapability.filesV1.rawValue == "supermux.files.v1")
    }

    @Test func allExposesEveryCapabilityExactlyOnce() {
        #expect(SupermuxMobileCapability.all == SupermuxMobileCapability.allCases)
        #expect(SupermuxMobileCapability.all.count == 8)
        #expect(Set(SupermuxMobileCapability.all).count == 8)
    }
}
