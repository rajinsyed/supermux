import Foundation
import Testing

@testable import SupermuxKit

/// Ways a failed create on another Mac could be reported badly (written before
/// the code):
/// 1. An offline / unreachable Mac shows a raw code or a generic sentence that
///    does not name the Mac.
/// 2. A dirty worktree, missing AI setup or a removed project shows the raw
///    wire code.
/// 3. A precise host sentence (an invalid branch name from git) is replaced by
///    a vague one.
/// 4. An unknown code with no message yields an empty alert.
/// 5. An older Mac that lacks the method is not told to update.
struct SupermuxRemoteWorktreeFailureTests {
    private func message(_ code: String?, _ host: String? = nil) -> String {
        SupermuxRemoteWorktreeFailure.message(code: code, hostMessage: host, deviceName: "Studio")
    }

    @Test func offlineCodesNameTheMac() {
        for code in ["not_connected", "unknown_device", "timeout"] {
            let text = message(code, "raw")
            #expect(text.contains("Studio"), "\(code): \(text)")
            #expect(!text.contains(code))
        }
    }

    @Test func knownCodesAreTranslated() {
        for code in ["dirty_worktree", "ai_unavailable", "not_found"] {
            let text = message(code, code)
            #expect(!text.isEmpty)
            #expect(!text.contains(code), "\(code): \(text)")
        }
        #expect(message("not_found").contains("Studio"))
    }

    @Test func hostSentencesSurviveForGitFailures() {
        #expect(message("invalid_params", "“bad..name” is not a valid branch name.") == "“bad..name” is not a valid branch name.")
        #expect(message("unavailable", "git worktree add failed: fatal") == "git worktree add failed: fatal")
        #expect(message(nil, "Something specific") == "Something specific")
    }

    @Test func emptyOrUnknownFallsBackToASentenceNamingTheMac() {
        for (code, host) in [("unavailable", ""), ("weird_code", nil), (nil, "  ")] as [(String?, String?)] {
            let text = message(code, host)
            #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(text.contains("Studio"))
        }
    }

    @Test func olderMacIsToldToUpdate() {
        let text = message("method_not_found", "Unknown method")
        #expect(text.contains("Studio"))
        #expect(text != "Unknown method")
    }
}
