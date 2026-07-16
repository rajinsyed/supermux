import CMUXMobileCore
import Foundation
import SupermuxMobileCore
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Logic-only coverage of the fail-closed `mobile.supermux.*` ticket-scoping
/// table (architecture §4; validation contract AUTH-01/02/03). Modeled on
/// `MobileHostAuthorizationTests`: pure value fixtures through the
/// `ticketAuthorizationError` seam (upstream 0.64.x dropped the debug wrapper; the internal static is directly callable) — no Ghostty surfaces, no
/// `Workspace`/`TabManager` construction, no real config.
@Suite(.serialized)
@MainActor
struct SupermuxMobileAuthorizationTests {
    // MARK: - AUTH-01: every shared method constant is classified

    @Test func everySupermuxMethodConstantHasANonDefaultClassification() {
        for method in SupermuxMobileMethod.all {
            #expect(
                SupermuxMobileAuthorization.scope(forMethod: method.rawValue) != nil,
                "unclassified mobile.supermux method: \(method.rawValue)"
            )
        }
    }

    @Test func unknownSupermuxMethodStringIsUnclassified() {
        #expect(SupermuxMobileAuthorization.scope(forMethod: "mobile.supermux.evil.method") == nil)
        #expect(SupermuxMobileAuthorization.scope(forMethod: "workspace.list") == nil)
    }

    @Test func classificationSplitsChangesAndFilesFromMacWideMethods() {
        for method in SupermuxMobileMethod.all {
            let expected: SupermuxMobileAuthorization.Scope =
                method.rawValue.hasPrefix("mobile.supermux.changes.")
                    || method.rawValue.hasPrefix("mobile.supermux.files.")
                ? .workspaceScopedPermitted
                : .macWide
            #expect(
                SupermuxMobileAuthorization.scope(for: method) == expected,
                "unexpected scope for \(method.rawValue)"
            )
        }
    }

    // MARK: - AUTH-02: accept/reject matrix through the host's debug seam

    @Test func macWideTicketAcceptsEverySupermuxMethod() throws {
        let ticket = try attachTicket(workspaceID: "")
        for method in SupermuxMobileMethod.all {
            let error = MobileHostService.ticketAuthorizationError(
                ticket: ticket,
                request: request(method: method.rawValue, params: ["workspace_id": "workspace"])
            )
            #expect(error == nil, "Mac-wide ticket must pass \(method.rawValue)")
        }
    }

    @Test func scopedTicketAcceptsChangesAndFilesForItsOwnWorkspace() throws {
        let ticket = try attachTicket(workspaceID: "workspace")
        for method in workspaceScopedMethods() {
            let error = MobileHostService.ticketAuthorizationError(
                ticket: ticket,
                request: request(method: method.rawValue, params: ["workspace_id": "workspace"])
            )
            #expect(error == nil, "workspace-scoped ticket must pass \(method.rawValue) for its own workspace")
        }
    }

    @Test func scopedTicketRejectsChangesAndFilesForOtherWorkspaces() throws {
        let ticket = try attachTicket(workspaceID: "workspace")
        for method in workspaceScopedMethods() {
            let error = MobileHostService.ticketAuthorizationError(
                ticket: ticket,
                request: request(method: method.rawValue, params: ["workspace_id": "other-workspace"])
            )
            #expect(error?.code == "forbidden", "workspace-scoped ticket must reject \(method.rawValue) for another workspace")
        }
    }

    @Test func scopedTicketRejectsChangesAndFilesWithoutAWorkspaceSelection() throws {
        let ticket = try attachTicket(workspaceID: "workspace")
        for method in workspaceScopedMethods() {
            let error = MobileHostService.ticketAuthorizationError(
                ticket: ticket,
                request: request(method: method.rawValue, params: [:])
            )
            #expect(error?.code == "forbidden", "workspace-scoped ticket must fail closed on unscoped \(method.rawValue)")
        }
    }

    @Test func scopedTicketRejectsEveryMacWideMethod() throws {
        let ticket = try attachTicket(workspaceID: "workspace")
        for method in macWideMethods() {
            // Even a matching workspace_id riding along must not widen a
            // scoped ticket to Mac-wide surfaces (projects, worktrees,
            // presets, run, actions, icon).
            let error = MobileHostService.ticketAuthorizationError(
                ticket: ticket,
                request: request(method: method.rawValue, params: ["workspace_id": "workspace"])
            )
            #expect(error?.code == "forbidden", "workspace-scoped ticket must reject \(method.rawValue)")
        }
    }

    @Test func scopedTicketRejectsFilesRequestsNamingAProjectRoot() throws {
        let ticket = try attachTicket(workspaceID: "workspace")
        let error = MobileHostService.ticketAuthorizationError(
            ticket: ticket,
            request: request(
                method: SupermuxMobileMethod.filesList.rawValue,
                params: [
                    "workspace_id": "workspace",
                    "project_id": UUID().uuidString,
                ]
            )
        )
        #expect(error?.code == "forbidden", "project-rooted files requests are Mac-wide")
    }

    @Test func macWideTicketAcceptsFilesRequestsNamingAProjectRoot() throws {
        let ticket = try attachTicket(workspaceID: "")
        let error = MobileHostService.ticketAuthorizationError(
            ticket: ticket,
            request: request(
                method: SupermuxMobileMethod.filesList.rawValue,
                params: ["project_id": UUID().uuidString]
            )
        )
        #expect(error == nil)
    }

    @Test func unknownSupermuxMethodFailsClosedForEveryTicket() throws {
        let macWide = try attachTicket(workspaceID: "")
        let scoped = try attachTicket(workspaceID: "workspace")
        for ticket in [macWide, scoped] {
            let error = MobileHostService.ticketAuthorizationError(
                ticket: ticket,
                request: request(method: "mobile.supermux.evil.method", params: [:])
            )
            #expect(error?.code == "forbidden", "unlisted mobile.supermux methods must fail closed")
        }
    }

    @Test func terminalScopedTicketBehavesLikeItsWorkspacePin() throws {
        let ticket = try attachTicket(workspaceID: "workspace", terminalID: "terminal")
        let accepted = MobileHostService.ticketAuthorizationError(
            ticket: ticket,
            request: request(
                method: SupermuxMobileMethod.changesStatus.rawValue,
                params: ["workspace_id": "workspace"]
            )
        )
        #expect(accepted == nil)
        let rejected = MobileHostService.ticketAuthorizationError(
            ticket: ticket,
            request: request(
                method: SupermuxMobileMethod.projectsList.rawValue,
                params: [:]
            )
        )
        #expect(rejected?.code == "forbidden")
    }

    // MARK: - AUTH-03: Stack auth stays mandatory for the whole namespace

    @Test func everySupermuxMethodRequiresAuthorization() async {
        for method in SupermuxMobileMethod.all {
            let result = await MobileHostService.shared.debugAuthorizationError(
                for: MobileHostRPCRequest(
                    id: "supermux-auth-\(method.rawValue)",
                    method: method.rawValue,
                    params: [:],
                    auth: nil
                )
            )
            guard case let .failure(error) = result else {
                Issue.record("\(method.rawValue) must require mobile authorization")
                continue
            }
            #expect(error.code == "unauthorized")
        }
    }

    @Test func mobileHostStatusRemainsTheOnlyExemption() async {
        let result = await MobileHostService.shared.debugAuthorizationError(
            for: MobileHostRPCRequest(
                id: "host-status",
                method: "mobile.host.status",
                params: [:],
                auth: nil
            )
        )
        #expect(result == nil)
    }

    // MARK: - Fixtures

    private func workspaceScopedMethods() -> [SupermuxMobileMethod] {
        SupermuxMobileMethod.all.filter {
            SupermuxMobileAuthorization.scope(for: $0) == .workspaceScopedPermitted
        }
    }

    private func macWideMethods() -> [SupermuxMobileMethod] {
        SupermuxMobileMethod.all.filter {
            SupermuxMobileAuthorization.scope(for: $0) == .macWide
        }
    }

    private func request(method: String, params: [String: Any]) -> MobileHostRPCRequest {
        MobileHostRPCRequest(
            id: "supermux-\(method)",
            method: method,
            params: params,
            auth: nil
        )
    }

    /// A ticket pinned to `workspaceID` (empty string = Mac-wide), mirroring
    /// `MobileHostAuthorizationTests.scopedAttachTicket`.
    private func attachTicket(workspaceID: String, terminalID: String? = nil) throws -> CmxAttachTicket {
        let route = try CmxAttachRoute(
            id: "debug",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58465)
        )
        return try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3600),
            authToken: "ticket-secret"
        )
    }
}
