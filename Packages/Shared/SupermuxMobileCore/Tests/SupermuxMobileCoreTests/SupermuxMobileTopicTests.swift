import Foundation
import Testing
@testable import SupermuxMobileCore

@Suite struct SupermuxMobileTopicTests {
    @Test func topicsMatchTheWireContract() {
        #expect(SupermuxMobileTopic.projectsUpdated.rawValue == "supermux.projects.updated")
        #expect(SupermuxMobileTopic.worktreesUpdated.rawValue == "supermux.worktrees.updated")
        #expect(SupermuxMobileTopic.changesUpdated.rawValue == "supermux.changes.updated")
        #expect(SupermuxMobileTopic.runUpdated.rawValue == "supermux.run.updated")
        #expect(SupermuxMobileTopic.filesUpdated.rawValue == "supermux.files.updated")
        #expect(SupermuxMobileTopic.portsUpdated.rawValue == "supermux.ports.updated")
    }

    @Test func allExposesEveryTopicExactlyOnce() {
        #expect(SupermuxMobileTopic.all == SupermuxMobileTopic.allCases)
        #expect(SupermuxMobileTopic.all.count == 6)
        #expect(Set(SupermuxMobileTopic.all).count == 6)
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
        #expect(SupermuxMobileCapability.selectionSyncV1.rawValue == "supermux.selection_sync.v1")
        #expect(SupermuxMobileCapability.selectionSyncV2.rawValue == "supermux.selection_sync.v2")
        #expect(SupermuxMobileCapability.panesV1.rawValue == "supermux.panes.v1")
        #expect(SupermuxMobileCapability.phonePushV1.rawValue == "supermux.phone_push.v1")
        #expect(SupermuxMobileCapability.usageV1.rawValue == "supermux.usage.v1")
        #expect(SupermuxMobileCapability.agentLaunchV1.rawValue == "supermux.agent_launch.v1")
        #expect(SupermuxMobileCapability.phonePushShareV1.rawValue == "supermux.phone_push_share.v1")
        #expect(SupermuxMobileCapability.projectSetupV1.rawValue == "supermux.project_setup.v1")
        #expect(SupermuxMobileCapability.terminalInputV1.rawValue == "supermux.terminal_input.v1")
        #expect(SupermuxMobileCapability.terminalPlacementV1.rawValue == "supermux.terminal_placement.v1")
        #expect(SupermuxMobileCapability.filesReadV1.rawValue == "supermux.files_read.v1")
        #expect(SupermuxMobileCapability.portForwardV1.rawValue == "supermux.port_forward.v1")
        #expect(SupermuxMobileCapability.remoteSimulatorV1.rawValue == "supermux.remote_simulator.v1")
        #expect(SupermuxMobileCapability.terminalAttachmentsV1.rawValue == "supermux.terminal_attachments.v1")
        #expect(SupermuxMobileCapability.terminalActionsV1.rawValue == "supermux.terminal_actions.v1")
    }

    @Test func allExposesEveryCapabilityExactlyOnce() {
        #expect(SupermuxMobileCapability.all == SupermuxMobileCapability.allCases)
        #expect(SupermuxMobileCapability.all.count == 23)
        #expect(Set(SupermuxMobileCapability.all).count == 23)
    }
}
