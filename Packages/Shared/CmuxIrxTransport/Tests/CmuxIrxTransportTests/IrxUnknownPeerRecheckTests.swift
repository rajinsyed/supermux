// SUPERMUX:begin irx-admission-unknown-peer-recheck (regression coverage — see SUPERMUX-TOUCHPOINTS.md)
import Foundation
import IrohLib
import Testing
@testable import CmuxIrxTransport

/// Field log (2026-10-04): a newly installed phone was denied `invalid-grant`
/// for six minutes because the Mac judged it against a directory fetched
/// before the phone registered, and nothing refreshed it until the next
/// scheduled pass.
@Suite("unknown peer recheck", .serialized, .timeLimit(.minutes(1)))
struct IrxUnknownPeerRecheckTests {
    @Test("a phone missing from the Mac's directory is admitted once a refresh lists it")
    func newlyListedPhoneIsAdmitted() async throws {
        let directory = ListedEndpoints()
        let outcome = try await admit(directory: directory) { directory.list($0) }
        #expect(outcome == nil)
    }

    @Test("a refresh that does not list the phone still denies it")
    func unlistedPhoneIsStillDenied() async throws {
        let outcome = try await admit(directory: ListedEndpoints()) { _ in }
        #expect(outcome == .invalidGrant)
    }

    @Test("concurrent unknown phones share one refresh, and the next waits out the cooldown")
    func refreshesAreSharedAndRateLimited() async throws {
        let refreshes = RefreshCounter()
        let now = ManualInstant()
        let gate = IrxDirectoryRecheckGate(cooldown: .seconds(30), now: { now.value }) {
            await refreshes.run()
        }

        async let first: Void = gate.recheck()
        async let second: Void = gate.recheck()
        _ = await (first, second)
        #expect(await refreshes.count == 1)

        await gate.recheck()
        #expect(await refreshes.count == 1)

        now.advance(by: .seconds(31))
        await gate.recheck()
        #expect(await refreshes.count == 2)
    }

    /// Runs one live admission over loopback and returns the denial code,
    /// or nil when the client was admitted. `refresh` stands in for the Mac's
    /// directory refresh and receives the client's endpoint.
    private func admit(
        directory: ListedEndpoints,
        refresh: @escaping @Sendable (String) -> Void
    ) async throws -> IrxCloseCode? {
        let journal = IrxLiveTestSupport.journal()
        let server = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let client = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let clientHex = client.id().toBytes().map { String(format: "%02x", $0) }.joined()
        let serverTask = Task {
            guard let incoming = await server.acceptNext() else { return }
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let irx = IrxConnection(connection: connection, role: .acceptor, journal: journal)
            _ = await IrxAdmission().performServer(
                connection: irx,
                judgment: { _, remote in try directory.judge(remote) },
                journal: journal,
                recheckUnknownPeer: { refresh(clientHex) }
            )
        }

        let connection = try await client.connect(
            addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol().alpnData)
        let irx = IrxConnection(connection: connection, role: .dialer, journal: journal)
        var denial: IrxCloseCode?
        do {
            _ = try await IrxAdmission().performClient(connection: irx, journal: journal)
        } catch let denied as IrxAdmissionDenied {
            denial = denied.code
        }
        try await serverTask.value
        try? await server.close()
        try? await client.close()
        return denial
    }
}

/// The Mac's directory: the endpoints it admits.
private final class ListedEndpoints: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: Set<String> = []

    func list(_ endpoint: String) {
        lock.withLock { _ = endpoints.insert(endpoint.lowercased()) }
    }

    func judge(_ endpoint: String) throws -> IrxAdmittedPeerInfo {
        guard lock.withLock({ endpoints.contains(endpoint.lowercased()) }) else {
            throw IrxAdmissionDenied(code: .invalidGrant)
        }
        return IrxAdmittedPeerInfo(
            bindingID: "b-test", deviceID: "d-test", tag: "t-test",
            endpointIDHex: endpoint, identityGeneration: 1)
    }
}

private actor RefreshCounter {
    private(set) var count = 0

    func run() async {
        count += 1
        try? await Task.sleep(for: .milliseconds(50))
    }
}

private final class ManualInstant: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var value: ContinuousClock.Instant { lock.withLock { instant } }

    func advance(by duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}
// SUPERMUX:end irx-admission-unknown-peer-recheck
