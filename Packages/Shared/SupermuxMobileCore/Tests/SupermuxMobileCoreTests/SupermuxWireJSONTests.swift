import Foundation
import Testing
@testable import SupermuxMobileCore

@Suite struct SupermuxWireJSONTests {
    private let wire = SupermuxWireJSON()

    @Test func encodesDTOToSnakeCaseDictionary() throws {
        let preset = SupermuxTerminalPresetDTO(
            id: "preset-1",
            name: "claude",
            command: "claude",
            iconSymbol: "sparkle",
            colorHex: "#f97316"
        )
        let dictionary = try wire.dictionary(from: preset)
        #expect(dictionary["id"] as? String == "preset-1")
        #expect(dictionary["icon_symbol"] as? String == "sparkle")
        #expect(dictionary["color_hex"] as? String == "#f97316")
        #expect(dictionary.count == 5)
    }

    @Test func decodesDTOFromDictionary() throws {
        let dictionary: [String: Any] = [
            "path": "/tmp/wt",
            "branch": "main",
            "is_open": true,
            "pull_request": ["number": 5, "state": "open"],
        ]
        let worktree = try wire.decode(SupermuxWorktreeDTO.self, from: dictionary)
        #expect(worktree.path == "/tmp/wt")
        #expect(worktree.isOpen == true)
        #expect(worktree.pullRequest?.number == 5)
    }

    @Test func roundTripsThroughDictionary() throws {
        let status = SupermuxChangesStatusDTO(
            workspaceId: "workspace:1",
            isRepository: true,
            branch: "main",
            upstreamBranch: "origin/main",
            ahead: 1,
            behind: 0,
            staged: [SupermuxChangedFileDTO(path: "a.swift", oldPath: nil, kind: "modified")],
            unstaged: [],
            untracked: nil,
            stashCount: 0
        )
        let dictionary = try wire.dictionary(from: status)
        let copy = try wire.decode(SupermuxChangesStatusDTO.self, from: dictionary)
        #expect(copy == status)
    }

    @Test func wireJSONUnknownFieldTolerance() throws {
        var dictionary: [String: Any] = ["name": "src", "is_dir": true]
        dictionary["future_key"] = ["nested": true]
        let entry = try wire.decode(SupermuxFileEntryDTO.self, from: dictionary)
        #expect(entry.name == "src")
        #expect(entry.isDir == true)
    }

    @Test func decodingFailsCleanlyOnMissingEssentialField() {
        #expect(throws: (any Error).self) {
            _ = try wire.decode(SupermuxFileEntryDTO.self, from: ["is_dir": true])
        }
    }

    @Test func nonEncodableValueThrowsNotADictionaryError() {
        // A bare scalar encodes to a JSON fragment, not an object.
        #expect(throws: SupermuxWireJSONError.notADictionary) {
            _ = try wire.dictionary(from: "just a string")
        }
    }
}
