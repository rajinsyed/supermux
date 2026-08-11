import Foundation
import SupermuxMobileCore
@testable import SupermuxKit
import Testing

/// Behavior coverage for the project identity every notification surface reads:
/// accent resolution, the provenance line, banner decoration policy, and
/// project grouping.
@Suite struct SupermuxNotificationProjectTests {

    // MARK: - Accent resolution

    @Test func explicitColorWinsOverDerivation() {
        let accent = SupermuxProjectAccentPalette(colorHex: "#3b82f6", projectID: "any")
        #expect(accent.isExplicit)
        #expect(accent.hex == "#3b82f6")
    }

    @Test func malformedColorFallsBackToDerivation() {
        // Shorthand, alpha, and garbage must derive rather than render a wrong
        // color or crash.
        for bad in ["#fff", "#3b82f6ff", "not-a-color", "", "#zzzzzz"] {
            let accent = SupermuxProjectAccentPalette(colorHex: bad, projectID: "project-a")
            #expect(!accent.isExplicit, "\(bad) should not be treated as explicit")
        }
    }

    @Test func derivedAccentIsStableForTheSameProject() {
        let first = SupermuxProjectAccentPalette(colorHex: nil, projectID: "project-a")
        let second = SupermuxProjectAccentPalette(colorHex: nil, projectID: "project-a")
        #expect(first == second)
    }

    /// The reason the splitmix64 finalizer exists: raw djb2 collapses at this
    /// palette size, so a realistic set of ids must spread across many slots
    /// rather than piling onto one color.
    @Test func derivedAccentsSpreadAcrossThePalette() {
        let ids = (0 ..< 40).map { "3f2a1b9c-0000-4000-8000-00000000\(String(format: "%04d", $0))" }
        let distinct = Set(ids.map {
            SupermuxProjectAccentPalette(colorHex: nil, projectID: $0).hex
        })
        #expect(
            distinct.count >= 8,
            "Derived accents collapsed to \(distinct.count) colors; the id hash is degenerate."
        )
    }

    @Test func derivedPaletteExcludesSlate() {
        // Slate reads as "no color" and would defeat the point of deriving one.
        #expect(!SupermuxProjectAccentPalette.derivedHexes.contains("#64748b"))
        #expect(SupermuxProjectAccentPalette.hexes.contains("#64748b"))
    }

    /// The macOS and iOS palettes are declared separately (SupermuxKit is
    /// Mac-only). If they drift, a project's avatar changes color between the
    /// Mac and the phone.
    @Test func paletteMatchesTheDesktopProjectPalette() {
        #expect(SupermuxProjectAccentPalette.hexes == SupermuxProjectColor.palette.map(\.hex))
    }

    // MARK: - Provenance

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

    // MARK: - Banner decoration

    @Test func bannerFillsAnEmptySubtitleWithProvenance() {
        let decoration = SupermuxBannerDecoration.resolve(
            project: Self.project(name: "supermux"),
            existingSubtitle: "",
            tabName: "main"
        )
        #expect(decoration.subtitle == "supermux · main")
        #expect(decoration.threadIdentifier == "supermux.project.\(Self.projectID)")
        #expect(decoration.rendersAvatar)
    }

    @Test func bannerNeverOverwritesAnAgentSuppliedSubtitle() {
        // A subtitle the agent set is content, not chrome.
        let decoration = SupermuxBannerDecoration.resolve(
            project: Self.project(name: "supermux"),
            existingSubtitle: "3 tests failed",
            tabName: "main"
        )
        #expect(decoration.subtitle == nil)
        #expect(decoration.rendersAvatar)
    }

    @Test func bannerWithoutAProjectStillNamesTheTab() {
        let decoration = SupermuxBannerDecoration.resolve(
            project: nil,
            existingSubtitle: "",
            tabName: "scratch"
        )
        #expect(decoration.subtitle == "scratch")
        #expect(decoration.threadIdentifier == nil)
        #expect(!decoration.rendersAvatar)
    }

    @Test func bannerWithNothingToSayDecoratesNothing() {
        #expect(
            SupermuxBannerDecoration.resolve(
                project: nil, existingSubtitle: "", tabName: nil
            ) == .none
        )
    }

    // MARK: - Grouping

    @Test func groupingOrdersSectionsByTheirNewestNotification() {
        let alpha = Self.project(id: "aaaa", name: "alpha")
        let beta = Self.project(id: "bbbb", name: "beta")
        // Input is newest-first, as the store publishes it.
        let items = [
            Fixture(id: 1, project: beta, isRead: false),
            Fixture(id: 2, project: alpha, isRead: true),
            Fixture(id: 3, project: beta, isRead: false),
        ]
        let sections = SupermuxNotificationGrouping.sections(
            for: items, project: \.project, isUnread: { !$0.isRead }
        )
        #expect(sections.map(\.id) == ["bbbb", "aaaa"])
        #expect(sections[0].items.map(\.id) == [1, 3])
        #expect(sections[0].unreadCount == 2)
        #expect(sections[1].unreadCount == 0)
    }

    @Test func groupingCollectsProjectlessNotificationsIntoOneSection() {
        let alpha = Self.project(id: "aaaa", name: "alpha")
        let items = [
            Fixture(id: 1, project: nil, isRead: false),
            Fixture(id: 2, project: alpha, isRead: false),
            Fixture(id: 3, project: nil, isRead: true),
        ]
        let sections = SupermuxNotificationGrouping.sections(
            for: items, project: \.project, isUnread: { !$0.isRead }
        )
        let other = try? #require(sections.first { $0.project == nil })
        #expect(other?.items.map(\.id) == [1, 3])
        #expect(other?.unreadCount == 1)
        #expect(sections.count == 2)
    }

    @Test func groupingKeepsEveryNotification() {
        // A dropped notification is the worst possible grouping bug, so assert
        // conservation explicitly rather than inferring it from the shapes.
        let projects = [Self.project(id: "a", name: "a"), Self.project(id: "b", name: "b"), nil]
        let items = (0 ..< 30).map { Fixture(id: $0, project: projects[$0 % 3], isRead: $0.isMultiple(of: 2)) }
        let sections = SupermuxNotificationGrouping.sections(
            for: items, project: \.project, isUnread: { !$0.isRead }
        )
        #expect(sections.flatMap(\.items).map(\.id).sorted() == items.map(\.id).sorted())
    }

    // MARK: - Snapshot semantics

    @Test func avatarLetterFallsBackForABlankName() {
        #expect(Self.project(name: "   ").avatarLetter == "?")
        #expect(Self.project(name: "supermux").avatarLetter == "S")
    }

    @Test func hasIconImageRequiresANonEmptyETag() {
        var project = Self.project(name: "supermux")
        #expect(!project.hasIconImage)
        project.iconETag = ""
        #expect(!project.hasIconImage)
        project.iconETag = "abc"
        #expect(project.hasIconImage)
    }

    /// The wire shape is snake_case and must stay stable — the phone decodes it.
    @Test func projectEncodesWithSnakeCaseWireKeys() throws {
        let project = SupermuxNotificationProject(
            id: "id-1", name: "supermux", colorHex: "#3b82f6",
            iconSymbol: "hammer", iconETag: "etag-1"
        )
        let data = try JSONEncoder().encode(project)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["color_hex"] as? String == "#3b82f6")
        #expect(object["icon_symbol"] as? String == "hammer")
        #expect(object["icon_etag"] as? String == "etag-1")
        let round = try JSONDecoder().decode(SupermuxNotificationProject.self, from: data)
        #expect(round == project)
    }

    // MARK: - Fixtures

    private static let projectID = "11111111-2222-3333-4444-555555555555"

    private static func project(
        id: String = projectID,
        name: String
    ) -> SupermuxNotificationProject {
        SupermuxNotificationProject(id: id, name: name)
    }

    private struct Fixture: Identifiable, Sendable {
        let id: Int
        let project: SupermuxNotificationProject?
        let isRead: Bool
    }
}
