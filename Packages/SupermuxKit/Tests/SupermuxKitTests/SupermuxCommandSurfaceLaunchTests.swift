import SupermuxKit
import Testing

@MainActor
struct SupermuxCommandSurfaceLaunchTests {
    private struct Surface: Equatable {
        let id: Int
    }

    @Test func createsBlankSurfaceThenSubmitsCommandAsOrderedInput() throws {
        var events: [String] = []
        let surface = try #require(SupermuxCommandSurfaceLaunch().launch(
            command: "./scripts/supermux-release.sh",
            createSurface: {
                events.append("create")
                return Surface(id: 1)
            },
            submitInput: { surface, input in
                events.append("submit:\(surface.id):\(input)")
                return true
            },
            discardSurface: { _ in events.append("discard") }
        ))

        #expect(surface == Surface(id: 1))
        #expect(events == [
            "create",
            "submit:1:./scripts/supermux-release.sh\n",
        ])
    }

    @Test func returnsNilWithoutSubmittingWhenSurfaceCreationFails() {
        var submitted = false
        var discarded = false

        let surface: Surface? = SupermuxCommandSurfaceLaunch().launch(
            command: "echo ready",
            createSurface: { nil },
            submitInput: { _, _ in
                submitted = true
                return true
            },
            discardSurface: { _ in discarded = true }
        )

        #expect(surface == nil)
        #expect(!submitted)
        #expect(!discarded)
    }

    @Test func discardsBlankSurfaceWhenInputIsRejected() {
        var discarded: Surface?

        let surface = SupermuxCommandSurfaceLaunch().launch(
            command: "echo ready",
            createSurface: { Surface(id: 2) },
            submitInput: { _, _ in false },
            discardSurface: { discarded = $0 }
        )

        #expect(surface == nil)
        #expect(discarded == Surface(id: 2))
    }
}
