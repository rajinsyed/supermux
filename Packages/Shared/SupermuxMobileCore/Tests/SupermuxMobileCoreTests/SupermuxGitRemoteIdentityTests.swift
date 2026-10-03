import Foundation
import Testing
@testable import SupermuxMobileCore

/// Ways cross-device project matching by git origin could go wrong:
/// 1. The same repo written as SSH on one Mac and HTTPS on the other must match.
/// 2. A trailing `.git`, a trailing slash, or letter case in the host must not split a match.
/// 3. Credentials or ports embedded in an HTTPS URL must not leak into the key or split a match.
/// 4. Different owners (forks) or different repos on the same host must NOT match.
/// 5. Owner/repo case is significant on some hosts, so it is preserved.
/// 6. Blank, whitespace or unparsable values yield no identity (never a wildcard).
/// 7. Local-path remotes (`/srv/repo.git`, `file://`) are identities too, kept verbatim.
@Suite struct SupermuxGitRemoteIdentityTests {
    @Test func sshAndHTTPSFormsOfTheSameRepoMatch() {
        let ssh = SupermuxGitRemoteIdentity.normalized("git@github.com:rajinsyed/supermux.git")
        let https = SupermuxGitRemoteIdentity.normalized("https://github.com/rajinsyed/supermux")
        let sshURL = SupermuxGitRemoteIdentity.normalized("ssh://git@github.com/rajinsyed/supermux.git")
        #expect(ssh == "github.com/rajinsyed/supermux")
        #expect(https == ssh)
        #expect(sshURL == ssh)
    }

    @Test func suffixesSlashesAndHostCaseDoNotSplitAMatch() {
        let base = SupermuxGitRemoteIdentity.normalized("https://github.com/owner/repo")
        #expect(SupermuxGitRemoteIdentity.normalized("https://GitHub.com/owner/repo.git/") == base)
        #expect(SupermuxGitRemoteIdentity.normalized("  https://github.com/owner/repo.git \n") == base)
    }

    @Test func credentialsAndPortsAreStripped() {
        let key = SupermuxGitRemoteIdentity.normalized("https://user:token@github.com:443/owner/repo.git")
        #expect(key == "github.com/owner/repo")
        #expect(key?.contains("token") == false)
    }

    @Test func forksAndOtherReposDoNotMatch() {
        let upstream = SupermuxGitRemoteIdentity.normalized("git@github.com:manaflow-ai/cmux.git")
        let fork = SupermuxGitRemoteIdentity.normalized("git@github.com:rajinsyed/cmux.git")
        let other = SupermuxGitRemoteIdentity.normalized("git@github.com:manaflow-ai/cmux-web.git")
        #expect(upstream != fork)
        #expect(upstream != other)
    }

    @Test func ownerAndRepoCaseIsPreserved() {
        #expect(SupermuxGitRemoteIdentity.normalized("git@github.com:Owner/Repo.git") == "github.com/Owner/Repo")
    }

    @Test func blankOrGarbageHasNoIdentity() {
        #expect(SupermuxGitRemoteIdentity.normalized(nil) == nil)
        #expect(SupermuxGitRemoteIdentity.normalized("") == nil)
        #expect(SupermuxGitRemoteIdentity.normalized("   ") == nil)
        #expect(SupermuxGitRemoteIdentity.normalized("https://") == nil)
        #expect(SupermuxGitRemoteIdentity.normalized("git@github.com:") == nil)
    }

    @Test func localPathRemotesKeepTheirPath() {
        #expect(SupermuxGitRemoteIdentity.normalized("/srv/git/repo.git") == "/srv/git/repo")
        #expect(SupermuxGitRemoteIdentity.normalized("file:///srv/git/repo.git") == "/srv/git/repo")
    }

    @Test func dtoCarriesTheRemoteURLAdditively() throws {
        let json = #"{"id":"a","name":"n","root_path":"/r","git_remote_url":"git@github.com:o/r.git"}"#
        let dto = try JSONDecoder().decode(SupermuxProjectDTO.self, from: Data(json.utf8))
        #expect(dto.gitRemoteURL == "git@github.com:o/r.git")
        #expect(dto.gitRemoteIdentity == "github.com/o/r")
        let legacy = try JSONDecoder().decode(SupermuxProjectDTO.self, from: Data(#"{"id":"a","name":"n","root_path":"/r"}"#.utf8))
        #expect(legacy.gitRemoteURL == nil)
        #expect(legacy.gitRemoteIdentity == nil)
    }
}
