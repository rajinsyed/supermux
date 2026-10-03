import Foundation
import Testing
@testable import SupermuxMobileCore

/// Ways the `mobile.supermux.project.probe` result could break between Macs:
/// 1. Keys drift from snake_case, so an older/newer Mac reads every flag as false.
/// 2. A missing optional (`git_remote_url`, `is_suppressed`) fails the decode.
/// 3. Unknown future fields fail the decode.
@Suite struct SupermuxProjectProbeDTOCodingTests {
    private let coding = WireCodingTestSupport()

    private var full: SupermuxProjectProbeDTO {
        SupermuxProjectProbeDTO(
            rootPath: "/Users/me/dev/app",
            exists: true,
            isDirectory: true,
            isGitRepo: true,
            gitRemoteURL: "git@github.com:acme/app.git",
            isSuppressed: false
        )
    }

    @Test func probeRoundTripsWithSnakeCaseKeys() throws {
        #expect(try coding.roundTrip(full) == full)
        #expect(try coding.encodedKeys(of: full) == [
            "root_path", "exists", "is_directory", "is_git_repo", "git_remote_url", "is_suppressed",
        ])
    }

    @Test func probeDecodesTheMinimalShapeAndIgnoresUnknownFields() throws {
        let probe = try coding.decode(
            SupermuxProjectProbeDTO.self,
            from: #"{"root_path": "/x", "exists": false, "is_directory": false, "is_git_repo": false, "later": 1}"#
        )
        #expect(probe.rootPath == "/x")
        #expect(!probe.exists)
        #expect(probe.gitRemoteURL == nil)
        #expect(probe.isSuppressed != true, "absent means not suppressed")
        #expect(probe.gitRemoteIdentity == nil)
    }

    @Test func probeIdentityIsTheNormalizedOrigin() {
        #expect(full.gitRemoteIdentity == "github.com/acme/app")
    }
}
