import Foundation
import Testing
@testable import SupermuxMobileCore

@Suite struct SupermuxFileEntryDTOCodingTests {
    private let coding = WireCodingTestSupport()

    private var fullEntry: SupermuxFileEntryDTO {
        SupermuxFileEntryDTO(
            name: "README.md",
            isDir: false,
            isSymlink: false,
            size: 2_048,
            modifiedAt: 1_900_000_000
        )
    }

    @Test func fileEntryRoundTrips() throws {
        #expect(try coding.roundTrip(fullEntry) == fullEntry)
    }

    @Test func fileEntryEncodesSnakeCaseKeys() throws {
        let keys = try coding.encodedKeys(of: fullEntry)
        #expect(keys == ["name", "is_dir", "is_symlink", "size", "modified_at"])
    }

    @Test func fileEntryDecodesWithOnlyEssentialFields() throws {
        let entry = try coding.decode(SupermuxFileEntryDTO.self, from: #"{"name": "src"}"#)
        #expect(entry.name == "src")
        #expect(entry.isDir == nil)
        #expect(entry.size == nil)
    }

    @Test func fileEntryUnknownFieldTolerance() throws {
        let json = """
        {"name": "src", "is_dir": true, "permissions": "rwxr-xr-x", "owner": {"uid": 501}}
        """
        let entry = try coding.decode(SupermuxFileEntryDTO.self, from: json)
        #expect(entry.name == "src")
        #expect(entry.isDir == true)
        #expect(entry.isSymlink == nil)
    }
}

@Suite struct SupermuxWorkspaceActivityDTOCodingTests {
    private let coding = WireCodingTestSupport()

    @Test func activityRawValuesMatchTheWireContract() {
        #expect(SupermuxWorkspaceActivityDTO.working.rawValue == "working")
        #expect(SupermuxWorkspaceActivityDTO.needsInput.rawValue == "needs_input")
        #expect(SupermuxWorkspaceActivityDTO.ready.rawValue == "ready")
        #expect(SupermuxWorkspaceActivityDTO.allCases.count == 3)
    }

    @Test func activityRoundTrips() throws {
        for activity in SupermuxWorkspaceActivityDTO.allCases {
            #expect(try coding.roundTrip([activity]) == [activity])
        }
    }

    @Test func workspaceActivityUnknownFieldTolerance() throws {
        // Activity travels as an optional field inside larger payloads; a
        // payload with unknown sibling keys must still decode.
        struct Envelope: Codable {
            var activity: SupermuxWorkspaceActivityDTO?
        }
        let json = #"{"activity": "needs_input", "brand_new_sibling": [1, 2, 3]}"#
        let envelope = try coding.decode(Envelope.self, from: json)
        #expect(envelope.activity == .needsInput)
    }
}
