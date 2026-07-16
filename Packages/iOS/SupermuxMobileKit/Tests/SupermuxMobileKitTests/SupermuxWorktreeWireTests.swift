import CmuxMobileRPC
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// Wire-shape tests for the worktree seam: request values must serialize the
/// EXACT §2 method strings and params the Mac dispatch expects, and responses
/// must decode the exact result shapes `SupermuxMobileHost+Worktrees.swift`
/// emits (leniently, so old/partial hosts never break the phone).
@Suite struct SupermuxWorktreeWireTests {
    // MARK: Requests — §2 exact

    @Test func requestWireMethodsMatchTheMethodConstants() {
        #expect(
            SupermuxWorktreesListRequest(projectID: "p").wireMethod
                == SupermuxMobileMethod.worktreesList.rawValue
        )
        #expect(
            SupermuxWorktreeSuggestBranchRequest(workspaceName: nil).wireMethod
                == SupermuxMobileMethod.worktreeSuggestBranch.rawValue
        )
        #expect(
            SupermuxWorktreeCreateRequest(projectID: "p", workspaceName: nil, branchName: nil, open: true)
                .wireMethod == SupermuxMobileMethod.worktreeCreate.rawValue
        )
        #expect(
            SupermuxWorktreeOpenRequest(projectID: "p", worktreePath: "/w").wireMethod
                == SupermuxMobileMethod.worktreeOpen.rawValue
        )
        #expect(
            SupermuxWorktreeRemoveRequest(projectID: "p", worktreePath: "/w", force: false).wireMethod
                == SupermuxMobileMethod.worktreeRemove.rawValue
        )
    }

    @Test func requestParamsCarryOnlyThePresentFields() {
        #expect(
            SupermuxWorktreesListRequest(projectID: "p").wireParams as NSDictionary
                == ["project_id": "p"] as NSDictionary
        )
        #expect(
            SupermuxWorktreeSuggestBranchRequest(workspaceName: "Fix login").wireParams as NSDictionary
                == ["workspace_name": "Fix login"] as NSDictionary
        )
        #expect(
            SupermuxWorktreeSuggestBranchRequest(workspaceName: nil).wireParams as NSDictionary
                == [:] as NSDictionary
        )
        #expect(
            SupermuxWorktreeCreateRequest(
                projectID: "p", workspaceName: "Fix login", branchName: "fix-login", open: true
            ).wireParams as NSDictionary == [
                "project_id": "p",
                "workspace_name": "Fix login",
                "branch_name": "fix-login",
                "open": true,
            ] as NSDictionary
        )
        #expect(
            SupermuxWorktreeCreateRequest(projectID: "p", workspaceName: nil, branchName: nil, open: false)
                .wireParams as NSDictionary == ["project_id": "p", "open": false] as NSDictionary
        )
        #expect(
            SupermuxWorktreeRemoveRequest(projectID: "p", worktreePath: "/w", force: false)
                .wireParams as NSDictionary
                == ["project_id": "p", "worktree_path": "/w"] as NSDictionary
        )
        #expect(
            SupermuxWorktreeRemoveRequest(projectID: "p", worktreePath: "/w", force: true)
                .wireParams as NSDictionary
                == ["project_id": "p", "worktree_path": "/w", "force": true] as NSDictionary
        )
    }

    // MARK: Responses — Mac result shapes

    @Test func worktreesListResponseDecodesMacResultShape() throws {
        let json = Data("""
        {
          "worktrees": [
            {
              "path": "/Users/dev/alpha/.worktrees/fix-login",
              "branch": "fix-login",
              "is_open": false,
              "pull_request": {
                "number": 41,
                "state": "open",
                "url": "https://github.com/acme/app/pull/41"
              }
            }
          ]
        }
        """.utf8)
        let response = try JSONDecoder().decode(SupermuxWorktreesListResponse.self, from: json)
        #expect(response.worktrees.count == 1)
        #expect(response.worktrees.first?.branch == "fix-login")
        #expect(response.worktrees.first?.pullRequest?.number == 41)
        #expect(response.worktrees.first?.pullRequest?.state == "open")
    }

    @Test func worktreesListResponseToleratesMissingAndUnknownFields() throws {
        let json = Data(#"{"future_field": 1}"#.utf8)
        let response = try JSONDecoder().decode(SupermuxWorktreesListResponse.self, from: json)
        #expect(response.worktrees.isEmpty)
    }

    @Test func branchSuggestionResponseDecodesBothSources() throws {
        let ai = try JSONDecoder().decode(
            SupermuxBranchSuggestionResponse.self,
            from: Data(#"{"branch_name": "fix-login-flow", "source": "ai"}"#.utf8)
        )
        #expect(ai.branchName == "fix-login-flow")
        #expect(ai.source == "ai")

        let random = try JSONDecoder().decode(
            SupermuxBranchSuggestionResponse.self,
            from: Data(#"{"branch_name": "cheerful-umbrella", "source": "random"}"#.utf8)
        )
        #expect(random.branchName == "cheerful-umbrella")
        #expect(random.source == "random")
    }

    @Test func createResponseDecodesWithAndWithoutWorkspaceID() throws {
        let opened = try JSONDecoder().decode(
            SupermuxWorktreeCreateResponse.self,
            from: Data("""
            {
              "worktree": {"path": "/w", "branch": "b", "is_open": true},
              "workspace_id": "5D2C9A44-71B3-4F0E-8E0A-6C4D1F2B3A55"
            }
            """.utf8)
        )
        #expect(opened.worktree?.path == "/w")
        #expect(opened.workspaceId == "5D2C9A44-71B3-4F0E-8E0A-6C4D1F2B3A55")

        let unopened = try JSONDecoder().decode(
            SupermuxWorktreeCreateResponse.self,
            from: Data(#"{"worktree": {"path": "/w"}}"#.utf8)
        )
        #expect(unopened.worktree?.path == "/w")
        #expect(unopened.workspaceId == nil)
    }

    @Test func openAndRemoveResponsesDecodeMacResultShapes() throws {
        let open = try JSONDecoder().decode(
            SupermuxWorktreeOpenResponse.self,
            from: Data(#"{"workspace_id": "7F1E2D3C-4B5A-6978-8899-AABBCCDDEEFF"}"#.utf8)
        )
        #expect(open.workspaceId == "7F1E2D3C-4B5A-6978-8899-AABBCCDDEEFF")

        let removed = try JSONDecoder().decode(
            SupermuxWorktreeRemoveResponse.self,
            from: Data(#"{"removed": true, "worktree_path": "/w"}"#.utf8)
        )
        #expect(removed.removed == true)
        #expect(removed.worktreePath == "/w")
    }

    // MARK: Wire error-code extraction

    @Test func wireErrorCodeIsExtractedFromRPCErrorsAndNilOtherwise() {
        struct Boom: Error {}
        #expect(
            SupermuxWireErrorCode.code(
                from: MobileShellConnectionError.rpcError("dirty_worktree", "dirty")
            ) == "dirty_worktree"
        )
        #expect(
            SupermuxWireErrorCode.code(from: MobileShellConnectionError.rpcError(nil, "no code")) == nil
        )
        #expect(SupermuxWireErrorCode.code(from: Boom()) == nil)
        #expect(SupermuxWireErrorCode.dirtyWorktree == "dirty_worktree")
    }
}
