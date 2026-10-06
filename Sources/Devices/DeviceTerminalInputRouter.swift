import CmuxTerminal
import Foundation
// SUPERMUX:begin device-mirror-input-batch
import SupermuxKit
// SUPERMUX:end device-mirror-input-batch

/// Delivers keystrokes from a manual-mirror Ghostty surface to another Mac's
/// terminal in order, one `mobile.terminal.input` request at a time.
///
/// Ghostty's I/O thread hands input to `enqueue` off the main actor; the router
/// serializes it into a queue the main-actor drain reads. Bytes that arrive
/// while a request is in flight are coalesced into the next request, so fast
/// typing over a slow link costs one round trip per burst, not per key.
final class DeviceTerminalInputRouter: @unchecked Sendable {
    enum InputError: Error, LocalizedError {
        case queueFull
        case invalidEncoding

        var errorDescription: String? {
            switch self {
            case .queueFull:
                return String(localized: "devices.input.queueFull", defaultValue: "Some terminal input was not sent because the connection could not keep up. Wait and try again.")
            case .invalidEncoding:
                return String(localized: "devices.input.invalidEncoding", defaultValue: "Some terminal input was not sent because this Mac requires UTF-8 text.")
            }
        }
    }

    // @unchecked Sendable: mutable input and task state are only touched under
    // `queue`; callers cross the boundary with immutable Data values.
    private let queue = DispatchQueue(label: "dev.cmux.devices.terminal-input", qos: .userInitiated)
    // SUPERMUX:begin device-mirror-input-batch (ordered bytes and forwarded keys instead of bytes only)
    private var pending = SupermuxTerminalInputBatch()
    // SUPERMUX:end device-mirror-input-batch
    private var draining = false
    private var drainTask: Task<Void, Never>?
    private var invalidated = false
    private var enabled = true
    // SUPERMUX:begin device-mirror-input-batch (the batch enforces the 256 KiB limit; upstream's Data init sends only the bytes)
    private let send: @Sendable (SupermuxTerminalInputBatch) async throws -> Void
    private let onFailure: @Sendable (any Error) -> Void
    // SUPERMUX:end device-mirror-input-batch
    // SUPERMUX:begin terminal-input-pipeline
    /// Hands a batch to the pane's ``SupermuxTerminalInputPipeline``, which
    /// sends it without waiting for earlier replies; false when the other
    /// Mac does not take pipelined input, and the batch goes the
    /// one-at-a-time way below.
    private let pipelined: (@Sendable (SupermuxTerminalInputBatch) async -> Bool)?
    // SUPERMUX:end terminal-input-pipeline
    // SUPERMUX:begin device-mirror-reattach-input
    /// Set while the mirror re-attaches, or its link is briefly down: keys
    /// stay in `pending`, in order, and go out once it is attached again.
    private var supermuxHolding = false
    /// Keys held while the link was down, set apart once it is back: the
    /// mirror sends them only when its re-attach proves the terminal is the
    /// one they were typed for (``supermuxSettleHeldInput(deliver:keepPending:)``).
    private var supermuxHeldWhileDown = SupermuxTerminalInputBatch()
    /// When the oldest key held now was taken: once it has waited
    /// ``SupermuxTerminalInputPipeline/replayWindow`` every held key is
    /// dropped (keystrokes must not land long after they were typed, and
    /// none may land without the ones before it).
    private var supermuxHeldSince: ContinuousClock.Instant?
    /// Told when held keys were dropped for their age (the mirror's pipeline
    /// drops what it still holds from before them).
    private let supermuxHeldInputExpired: (@Sendable () -> Void)?
    // SUPERMUX:end device-mirror-reattach-input
    // SUPERMUX:begin device-mirror-input-batch

    convenience init(
        send: @escaping @Sendable (Data) async throws -> Void,
        onFailure: @escaping @Sendable (any Error) -> Void
    ) {
        self.init(sendBatch: { batch in try await send(SupermuxDeviceTerminalInput.bytes(of: batch)) }, onFailure: onFailure)
    }

    init(
        sendBatch: @escaping @Sendable (SupermuxTerminalInputBatch) async throws -> Void,
        onFailure: @escaping @Sendable (any Error) -> Void,
        // SUPERMUX:begin terminal-input-pipeline
        pipelined: (@Sendable (SupermuxTerminalInputBatch) async -> Bool)? = nil,
        // SUPERMUX:end terminal-input-pipeline
        // SUPERMUX:begin device-mirror-reattach-input
        supermuxHeldInputExpired: (@Sendable () -> Void)? = nil
        // SUPERMUX:end device-mirror-reattach-input
    ) {
        self.send = sendBatch
        self.onFailure = onFailure
        // SUPERMUX:begin terminal-input-pipeline
        self.pipelined = pipelined
        // SUPERMUX:end terminal-input-pipeline
        // SUPERMUX:begin device-mirror-reattach-input
        self.supermuxHeldInputExpired = supermuxHeldInputExpired
        // SUPERMUX:end device-mirror-reattach-input
    }
    // SUPERMUX:end device-mirror-input-batch

    /// Safe from Ghostty's I/O thread. Named keys never reach the host: with no
    /// key-name resolver installed, Ghostty encodes every key to bytes itself.
    // SUPERMUX:begin device-mirror-input-batch (forwarded keys join the bytes in order; the mirror's own terminal replies are dropped)
    // Supermux installs a resolver (SupermuxDeviceTerminalInput) for a Mac
    // that takes forwarded keys, so its named keys travel in the batch.
    func enqueue(_ input: TerminalManualInput) {
        guard let item = SupermuxDeviceTerminalInput.batchItem(for: input) else { return }
        queue.async { [self] in
            guard !invalidated, enabled else {
                #if DEBUG
                if !invalidated { SupermuxTerminalInputDebug.inputDroppedWhileDetached() }
                #endif
                return
            }
            guard pending.append(item) else {
                onFailure(InputError.queueFull)
                return
            }
    // SUPERMUX:end device-mirror-input-batch
            // SUPERMUX:begin device-mirror-reattach-input (held keys wait for the attach, at most the replay window; upstream: `guard !draining else { return }`)
            if supermuxHolding { supermuxStartHoldClock() }
            guard !draining, !supermuxHolding else { return }
            // SUPERMUX:end device-mirror-reattach-input
            draining = true
            drainTask = Task { await self.drain() }
        }
    }

    /// Drops unsent keystrokes at disconnect; they must never replay after reconnecting.
    func setEnabled(_ enabled: Bool) {
        queue.async { [self] in
            self.enabled = enabled
            if !enabled {
                pending.removeAll()
                drainTask?.cancel()
            }
        }
    }

    func invalidate() {
        queue.async { [self] in
            invalidated = true
            pending.removeAll()
            drainTask?.cancel()
            drainTask = nil
        }
    }
    // SUPERMUX:begin device-mirror-reattach-input

    /// Whether keys are taken at all (`accepting`; not taken, they are
    /// dropped, as upstream's `setEnabled(false)` drops them) and, taken,
    /// whether they wait (`holding`) instead of going out. Releasing a hold
    /// sends what it kept, in order.
    func supermuxSetInput(accepting: Bool, holding: Bool) {
        queue.async { [self] in
            enabled = accepting
            supermuxHolding = accepting && holding
            guard accepting else {
                supermuxDropHeldLocked()
                drainTask?.cancel()
                return
            }
            // Keys set aside while the link was down wait under the mirror's own hold.
            guard !supermuxHolding else {
                if !pending.isEmpty { supermuxStartHoldClock() }
                return
            }
            supermuxHeldSince = nil
            guard !invalidated, !pending.isEmpty, !draining else { return }
            draining = true
            drainTask = Task { await self.drain() }
        }
    }

    /// The link is back: the keys held so far were typed while it was down.
    /// They wait under the mirror's hold from the drop; keys typed from now
    /// on start the clock again.
    func supermuxSetAsideHeldInput() {
        queue.async { [self] in
            for item in pending.items where !supermuxHeldWhileDown.append(item) {
                onFailure(InputError.queueFull)
                break
            }
            pending.removeAll()
            supermuxHeldSince = nil
        }
    }

    /// The mirror's hold from the drop ran out while it re-attaches: the
    /// keys set aside while the link was down go; the ones typed since it
    /// came back stay, under their own clock.
    func supermuxDropSetAsideInput() {
        queue.async { [self] in
            #if DEBUG
            for _ in supermuxHeldWhileDown.items { SupermuxTerminalInputDebug.inputDroppedWhileDetached() }
            #endif
            supermuxHeldWhileDown.removeAll()
        }
    }

    /// The re-attach after a lost link is answered: the keys set aside while
    /// the link was down go before the ones typed since (`deliver`), or are
    /// dropped; the ones typed since stay only when `keepPending`.
    func supermuxSettleHeldInput(deliver: Bool, keepPending: Bool) {
        queue.async { [self] in
            defer {
                supermuxHeldWhileDown.removeAll()
                if pending.isEmpty { supermuxHeldSince = nil }
            }
            if !keepPending {
                #if DEBUG
                for _ in pending.items { SupermuxTerminalInputDebug.inputDroppedWhileDetached() }
                #endif
                pending.removeAll()
            }
            guard deliver else {
                #if DEBUG
                for _ in supermuxHeldWhileDown.items { SupermuxTerminalInputDebug.inputDroppedWhileDetached() }
                #endif
                return
            }
            guard !supermuxHeldWhileDown.isEmpty else { return }
            var merged = supermuxHeldWhileDown
            for item in pending.items where !merged.append(item) {
                onFailure(InputError.queueFull)
                break
            }
            pending = merged
        }
    }

    /// Drops every key held or queued now, set apart or not: the hold ran
    /// out, or what was typed before them was dropped.
    func supermuxDropHeldInput() {
        queue.async { [self] in supermuxDropHeldLocked() }
    }

    private func supermuxDropHeldLocked() {
        #if DEBUG
        for _ in 0..<(pending.items.count + supermuxHeldWhileDown.items.count) {
            SupermuxTerminalInputDebug.inputDroppedWhileDetached()
        }
        #endif
        pending.removeAll()
        supermuxHeldWhileDown.removeAll()
        supermuxHeldSince = nil
    }

    /// Starts the hold's clock at the first key it takes; when the clock
    /// reads the replay window and the hold still keeps it, every held key
    /// goes (later keys start a new clock).
    private func supermuxStartHoldClock() {
        guard supermuxHeldSince == nil else { return }
        let since = ContinuousClock.now
        supermuxHeldSince = since
        let window = SupermuxTerminalInputPipeline.replayWindow / .milliseconds(1)
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(window))) { [weak self] in
            guard let self, supermuxHolding, supermuxHeldSince == since else { return }
            supermuxDropHeldLocked()
            supermuxHeldInputExpired?()
        }
    }
    // SUPERMUX:end device-mirror-reattach-input

    // SUPERMUX:begin device-mirror-input-batch
    private func takePending() -> SupermuxTerminalInputBatch? {
        queue.sync {
            // SUPERMUX:begin device-mirror-reattach-input (upstream: `guard !invalidated, enabled, !pending.isEmpty else {`)
            guard !invalidated, enabled, !supermuxHolding, !pending.isEmpty else {
            // SUPERMUX:end device-mirror-reattach-input
                draining = false
                drainTask = nil
                return nil
            }
            let batch = pending
            pending.removeAll()
            return batch
        }
    }
    // SUPERMUX:end device-mirror-input-batch

    private func drain() async {
        while let batch = takePending() {
            // SUPERMUX:begin terminal-input-pipeline (keys typed during the main-actor hop join the next batch)
            if let pipelined, await pipelined(batch) { continue }
            // SUPERMUX:end terminal-input-pipeline
            do {
                try Task.checkCancellation()
                // SUPERMUX:begin terminal-input-pipeline (DEBUG in-flight counters for the pipeline E2E)
                #if DEBUG
                SupermuxTerminalInputDebug.requestStarted()
                defer { SupermuxTerminalInputDebug.requestFinished() }
                #endif
                // SUPERMUX:end terminal-input-pipeline
                try await send(batch)
            } catch {
                if !Task.isCancelled { onFailure(error) }
                queue.sync {
                    pending.removeAll()
                    draining = false
                    drainTask = nil
                }
                return
            }
        }
    }
}
