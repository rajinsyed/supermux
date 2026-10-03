import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Typing into another Mac's terminal does not wait for that Mac's replies.
///
/// Upstream's ``DeviceTerminalInputRouter`` sends one `mobile.terminal.input`
/// at a time: keys typed while a request waits for its reply queue behind
/// it, so over a relay every burst pays a full round trip before it even
/// leaves this Mac. When the other Mac advertises
/// `supermux.terminal_input_pipeline.v1`, the router hands each batch here
/// instead, and it leaves at once:
///
/// - Every batch carries upstream's exactly-once delivery identity
///   (``MobileTerminalInputDelivery``: this mirror's stream id and a sequence
///   starting at 1), and batches are sent in sequence order on the link's one
///   ordered connection. The other Mac applies a terminal's input requests
///   in arrival order and its ledger (``MobileTerminalInputLedger``, which
///   every terminal input path already shares) writes each sequence once:
///   a resend it already applied is answered `duplicate`, one that arrives
///   ahead of a missing sequence is answered `gap` and sent again in order.
/// - A batch stays in ``MobileTerminalInputOutbox`` until its sequence is
///   acknowledged. A request that fails without an answer (the link dropped,
///   a missed deadline) is sent again with the same identity once the mirror
///   is attached again, so input in flight at a reconnect is neither lost
///   nor typed twice. Input still pending after the mirror could not send
///   for longer than ``replayWindow`` (detached, or the new connection's
///   capabilities never arrived) is dropped instead, as upstream drops input
///   typed while detached: keystrokes must not land long after they were
///   typed. So is input for a stream the other Mac no longer knows (it
///   restarted, perhaps with a new shell under the same terminal id).
/// - A request the other Mac refused before admitting it (an RPC error)
///   drops all pending input and starts a new stream, as upstream drops its
///   queue on a failed request.
///
/// The host needs nothing new: its per-connection ordered terminal-input
/// queue and ledger already exist. It answers an out-of-order arrival `gap`
/// rather than buffering it; on one ordered connection that happens only
/// around a resend, and the resend repairs it in order.
///
/// Main actor only; the router reaches it with one hop per batch.
@MainActor
final class SupermuxTerminalInputPipeline {
    typealias Send = @MainActor (SupermuxTerminalInputBatch, MobileTerminalInputDelivery) async throws -> MobileTerminalInputAcknowledgement?

    enum Failure: Error {
        /// The other Mac's terminal is gone; the batches were never written.
        case undeliverable(batches: Int)
        /// Pending input outlived ``replayWindow`` while the link was down.
        case expired(batches: Int)
        /// The other Mac no longer knows this stream (it restarted).
        case hostLostStream(batches: Int)
        /// The pending-input cap is full (typing far ahead of a stalled link).
        case queueFull
    }

    /// How long the link may be down before pending input is dropped
    /// rather than sent on reconnect.
    static let replayWindow: Duration = .seconds(10)
    /// The pause before sending again after a request failed without an
    /// answer while the mirror stayed attached, or the terminal was busy.
    static let retryDelay: Duration = .milliseconds(150)

    private var outbox: MobileTerminalInputOutbox<SupermuxTerminalInputBatch>
    private let send: Send
    private let isSupported: @MainActor () -> Bool
    private let onFailure: @Sendable (any Error) -> Void
    private var enabled = true
    private var invalidated = false
    /// Since when pending input could not be sent (detached, or the other
    /// Mac's capabilities unknown); nil while sending works.
    private var stalledSince: ContinuousClock.Instant?
    /// The current send attempt of each pending sequence. A reply or failure
    /// for an older attempt (a request from before a resend) changes nothing
    /// except confirming applied input.
    private var attempts: [UInt64: UInt64] = [:]
    private var lastAttempt: UInt64 = 0
    /// Sequences sent at least once, so a send again counts as a resend.
    private var sentBefore: Set<UInt64> = []
    private var retryTask: Task<Void, Never>?

    init(
        surfaceID: UUID,
        isSupported: @escaping @MainActor () -> Bool,
        send: @escaping Send,
        onFailure: @escaping @Sendable (any Error) -> Void
    ) {
        outbox = MobileTerminalInputOutbox(surfaceID: surfaceID)
        self.isSupported = isSupported
        self.send = send
        self.onFailure = onFailure
    }

    /// Whether the other Mac takes pipelined input. Checked per batch, so a
    /// pane made before the link connected pipelines once it does.
    static func hostSupportsPipeline(on machine: SurfaceMachineID) -> Bool {
        SupermuxComposition.devices.cachedHostCapabilities(on: machine)?
            .contains(SupermuxMobileCapability.terminalInputPipelineV1.rawValue) == true
    }

    /// The pipeline for one device mirror pane: `request` sends one
    /// `mobile.terminal.input` with `params` (the pane's ids and client id
    /// plus this batch and its identity) and returns the reply.
    static func forMirror(
        surfaceID: UUID,
        baseParams: [String: Any],
        isSupported: @escaping @MainActor () -> Bool,
        canSend: @escaping @MainActor () -> Bool,
        request: @escaping @MainActor ([String: Any]) async throws -> [String: Any],
        onFailure: @escaping @Sendable (any Error) -> Void
    ) -> SupermuxTerminalInputPipeline {
        SupermuxTerminalInputPipeline(
            surfaceID: surfaceID,
            isSupported: isSupported,
            send: { batch, delivery in
                guard canSend() else { throw DeviceLinkError.notConnected }
                var params = try SupermuxDeviceTerminalInput.inputParams(batch, base: baseParams, hostTakesBatches: true)
                params.merge(delivery.rpcParameters) { _, identity in identity }
                return MobileTerminalInputAcknowledgement.fromRPC(payload: try await request(params))
            },
            onFailure: onFailure
        )
    }

    /// Takes one batch and sends it at once. Returns false when the other
    /// Mac does not take pipelined input; the router then sends the batch
    /// itself, one request at a time.
    func offer(_ batch: SupermuxTerminalInputBatch) -> Bool {
        guard !invalidated else { return true }
        guard isSupported() else { return false }
        guard outbox.enqueue(batch, byteCount: batch.byteCount) != nil else {
            onFailure(Failure.queueFull)
            return true
        }
        pump()
        return true
    }

    /// Detached: nothing is sent; requests in flight keep their identity and
    /// are sent again when the mirror is attached again.
    func setEnabled(_ enabled: Bool) {
        guard !invalidated, enabled != self.enabled else { return }
        self.enabled = enabled
        #if DEBUG
        cmuxDebugLog("supermux.inputPipeline enabled=\(enabled) pending=\(outbox.entries.count)")
        #endif
        retryTask?.cancel()
        retryTask = nil
        guard enabled else {
            stalledSince = stalledSince ?? .now
            outbox.rewindAll()
            attempts.removeAll()
            return
        }
        if outbox.isEmpty {
            stalledSince = nil
        } else if stalledTooLong {
            dropAll(Failure.expired(batches: outbox.entries.count))
        }
        pump()
    }

    func invalidate() {
        invalidated = true
        enabled = false
        retryTask?.cancel()
        retryTask = nil
        _ = outbox.abandonAll()
        attempts.removeAll()
        sentBefore.removeAll()
    }

    // MARK: - Sending

    /// Whether pending input has waited longer than ``replayWindow`` for the
    /// mirror to be able to send it.
    private var stalledTooLong: Bool {
        stalledSince.map { ContinuousClock.now - $0 > Self.replayWindow } ?? false
    }

    private func pump() {
        guard enabled, !invalidated, outbox.hasUnsent else { return }
        guard isSupported() else {
            // A new connection's capabilities may not be known yet: wait for
            // them, but not past the replay window (an older Mac never says yes).
            stalledSince = stalledSince ?? .now
            if stalledTooLong {
                dropAll(Failure.expired(batches: outbox.entries.count))
            } else {
                scheduleRetry()
            }
            return
        }
        stalledSince = nil
        while let entry = outbox.nextUnsent() {
            let sequence = entry.delivery.sequence
            outbox.markSent(sequence)
            lastAttempt += 1
            let attempt = lastAttempt
            attempts[sequence] = attempt
            let resend = !sentBefore.insert(sequence).inserted
            // Tasks start in creation order on the main actor, so requests
            // reach the link in sequence order.
            Task { await self.deliver(entry.item, entry.delivery, attempt: attempt, resend: resend) }
        }
    }

    private func deliver(
        _ batch: SupermuxTerminalInputBatch,
        _ delivery: MobileTerminalInputDelivery,
        attempt: UInt64,
        resend: Bool
    ) async {
        #if DEBUG
        SupermuxTerminalInputDebug.requestStarted(pipelined: true, resend: resend)
        defer { SupermuxTerminalInputDebug.requestFinished() }
        #endif
        do {
            let acknowledgement = try await send(batch, delivery)
            // A reply without an identity means the request was written.
            handle(acknowledgement ?? MobileTerminalInputAcknowledgement(
                status: .applied,
                streamID: delivery.streamID,
                sequence: delivery.sequence
            ), attempt: attempt)
        } catch {
            guard !invalidated, attempts[delivery.sequence] == attempt else { return }
            #if DEBUG
            cmuxDebugLog("supermux.inputPipeline seq=\(delivery.sequence) failed: \(error)")
            #endif
            if Self.isRefusal(error) {
                // Refused before admission: it can never apply, and every
                // later sequence would wait behind it.
                dropAll(error)
                return
            }
            // No answer: it may or may not have been written. Send it again
            // with the same identity; the other Mac drops it if it was.
            outbox.rewind(from: delivery.sequence)
            scheduleRetry()
        }
    }

    private func handle(_ acknowledgement: MobileTerminalInputAcknowledgement, attempt: UInt64) {
        guard !invalidated else { return }
        let confirms = acknowledgement.status == .applied || acknowledgement.status == .duplicate
        // Only applied/duplicate are true whenever they arrive; any other
        // verdict on a request sent again since is stale.
        guard confirms || attempts[acknowledgement.sequence] == attempt else { return }
        let stream = outbox.streamID
        let result = outbox.apply(acknowledgement)
        for entry in result.delivered + result.undeliverable {
            attempts[entry.delivery.sequence] = nil
            sentBefore.remove(entry.delivery.sequence)
        }
        if outbox.streamID != stream {
            // The other Mac lost the stream: it restarted, and may have
            // restored this terminal under the same id with a new shell. The
            // pending input was typed for the old one, so it is dropped, as
            // upstream drops input across a lost link.
            dropAll(Failure.hostLostStream(batches: outbox.entries.count))
            return
        }
        if !result.undeliverable.isEmpty {
            onFailure(Failure.undeliverable(batches: result.undeliverable.count))
        }
        switch result.outcome {
        case .ignored, .progressed, .undeliverable:
            break
        case .resend:
            pump()
        case .retryLater:
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard enabled, retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.pump()
        }
    }

    /// The other Mac answered the request with an RPC error (a named code),
    /// so it never ran. A transport failure, a missed deadline or a local
    /// error leaves the outcome unknown.
    private static func isRefusal(_ error: any Error) -> Bool {
        guard case DeviceLinkError.hostRejected(let code?, _) = error else { return false }
        return code != SupermuxDeviceLinkEvents.missedDeadlineCode
    }

    private func dropAll(_ error: any Error) {
        #if DEBUG
        cmuxDebugLog("supermux.inputPipeline dropped \(outbox.entries.count) batch(es): \(error)")
        #endif
        stalledSince = nil
        _ = outbox.abandonAll()
        outbox.rebaseOntoNewStream()
        attempts.removeAll()
        sentBefore.removeAll()
        onFailure(error)
    }
}
