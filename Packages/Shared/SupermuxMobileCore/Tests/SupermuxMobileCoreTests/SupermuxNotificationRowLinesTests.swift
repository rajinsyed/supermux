import Foundation
import Testing
@testable import SupermuxMobileCore

/// Behavior coverage for the notification row's shared line logic — the rules
/// the macOS panel, the macOS titlebar popover, and the iOS feed all render
/// through.
///
/// These live in the cross-platform core alongside the code they cover. While
/// this logic was macOS-only the phone could not call it, composed its own
/// lines, and drifted: it showed "Claude Code" as every headline long after
/// both Mac surfaces had moved to the workspace name.
@Suite struct SupermuxNotificationRowLinesTests {

    @Test func provenanceJoinsProjectAndTab() {
        #expect(
            SupermuxNotificationProvenance.line(projectName: "supermux", tabName: "main")
                == "supermux · main"
        )
    }

    @Test func provenanceDropsATabThatRestatesTheProject() {
        // The common case — a workspace named after its repo. "supermux ·
        // supermux" is noise.
        #expect(
            SupermuxNotificationProvenance.line(projectName: "supermux", tabName: "Supermux")
                == "supermux"
        )
    }

    @Test func provenanceSkipsBlankSegments() {
        #expect(SupermuxNotificationProvenance.line(projectName: nil, tabName: "  ") == nil)
        #expect(SupermuxNotificationProvenance.line(projectName: "  ", tabName: "main") == "main")
    }

    @Test func provenanceDropsASurfaceMatchingAnEarlierSegment() {
        // Redundancy is checked against every accepted segment, not just the
        // previous one.
        #expect(
            SupermuxNotificationProvenance.line(
                projectName: "supermux",
                tabName: "feature-x",
                surfaceName: "supermux"
            ) == "supermux · feature-x"
        )
    }

    @Test func acceptedSegmentsSurviveSeparatorsInsideASegment() {
        // A row seeds de-duplication with its headline, then drops it. Doing
        // that by splitting the JOINED string would corrupt any segment that
        // itself contains " · " — workspace titles routinely do.
        #expect(
            SupermuxNotificationProvenance.accepted(["a · b", "supermux", "Claude Code"])
                == ["a · b", "supermux", "Claude Code"]
        )
    }

    // MARK: - Row presentation (shared by the panel and the titlebar popover)

    @Test func rowHeadlineIsTheWorkspaceWhenKnown() {
        // The workspace answers "where do I go"; one agent's title repeats down
        // every row and does not.
        #expect(
            SupermuxNotificationRowPresentation.headline(title: "Claude Code", tabName: "main")
                == "main"
        )
    }

    @Test func rowHeadlineFallsBackToTheTitle() {
        #expect(
            SupermuxNotificationRowPresentation.headline(title: "Claude Code", tabName: nil)
                == "Claude Code"
        )
        #expect(
            SupermuxNotificationRowPresentation.headline(title: "Claude Code", tabName: "   ")
                == "Claude Code"
        )
    }

    @Test func rowProvenanceCarriesTheProjectAndTitle() {
        #expect(
            SupermuxNotificationRowPresentation.provenance(
                projectName: "supermux",
                title: "Claude Code",
                headline: "main"
            ) == "supermux · Claude Code"
        )
    }

    @Test func rowProvenanceDropsWhatTheHeadlineAlreadySays() {
        // A workspace named after its project: the row must not read
        // "supermux / supermux · Claude Code".
        #expect(
            SupermuxNotificationRowPresentation.provenance(
                projectName: "supermux",
                title: "Claude Code",
                headline: "Supermux"
            ) == "Claude Code"
        )
        // Nothing left to say once both segments restate the headline.
        #expect(
            SupermuxNotificationRowPresentation.provenance(
                projectName: nil,
                title: "Claude Code",
                headline: "Claude Code"
            ) == nil
        )
    }

    @Test func rowProvenanceKeepsASeparatorBearingHeadlineIntact() {
        // Regression: dropping the seeded headline by splitting the joined
        // string would truncate any workspace title containing " · ", leaking
        // half of it back onto the provenance line.
        #expect(
            SupermuxNotificationRowPresentation.provenance(
                projectName: "supermux",
                title: "Claude Code",
                headline: "web · api"
            ) == "supermux · Claude Code"
        )
    }

    @Test func rowPreviewPrefersTheBodyAndFallsBackToTheSubtitle() {
        #expect(
            SupermuxNotificationRowPresentation.preview(
                body: "Build succeeded",
                subtitle: "codex",
                redundant: ["main"]
            ) == "Build succeeded"
        )
        // The subtitle was carried end-to-end but rendered nowhere before the
        // redesign; it is the fallback when the body adds nothing.
        #expect(
            SupermuxNotificationRowPresentation.preview(
                body: "  ",
                subtitle: "Completed in syedrajin",
                redundant: ["main"]
            ) == "Completed in syedrajin"
        )
    }

    @Test func rowPreviewDropsTextAlreadyOnScreen() {
        #expect(
            SupermuxNotificationRowPresentation.preview(
                body: "main",
                subtitle: "supermux",
                redundant: ["main", "supermux"]
            ) == nil
        )
    }
}
