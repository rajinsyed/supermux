import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Sends a moved mirror's new order key to the Mac that owns the workspace
/// (`mobile.supermux.workspace.set_order`), and holds that key meanwhile so
/// the dropped mirror stays where the user dropped it.
///
/// One request is in flight per remote workspace; a newer key replaces a
/// queued one. The owner's reply key is held until the mirror's record
/// carries it (or 5 s pass). An error, a host without
/// `supermux.order_sync.v1` or no reply within 10 s drops the key, so the
/// mirror snaps back to its record key; a refusal or a lost reply also beeps,
/// the same signal as a refused mirror close. Every change calls
/// ``onChange`` so the reconciler places the mirror again.
@MainActor
final class SupermuxMirrorOrderOutbox {
    /// How long a request may wait for its reply.
    static let replyTimeout: Duration = .seconds(10)
    /// How long a replied key is held when the record never shows it.
    static let replyHold: Duration = .seconds(5)

    private struct Entry {
        var key: String
        var isPinned: Bool
        /// Bumps on every send, so a late reply or timer of an older send is ignored.
        var generation: Int
        var inFlight: Bool
        var replied: Bool
        /// A newer key arrived while a request was in flight.
        var queued: Bool
    }

    /// Called after every change of the held keys.
    var onChange: (@MainActor () -> Void)?
    /// `set_order` requests sent since launch.
    private(set) var sentCount = 0
    /// Sends that ended with a beep since launch (DEBUG `order_state`).
    private(set) var beepCount = 0

    private let devices: SupermuxDevices
    private let beep: @MainActor () -> Void
    private var entries: [SupermuxRemoteWorkspaceRef: Entry] = [:]
    private var nextGeneration = 0

    init(devices: SupermuxDevices, beep: @escaping @MainActor () -> Void = { NSSound.beep() }) {
        self.devices = devices
        self.beep = beep
    }

    /// The key held for a mirror of `ref`, if any.
    func pendingKey(for ref: SupermuxRemoteWorkspaceRef) -> String? {
        entries[ref]?.key
    }

    /// Every held key.
    var pendingKeys: [String] {
        entries.values.map(\.key)
    }

    /// Asks `ref`'s owner to take `key`, and holds it until the owner answers.
    /// - Parameters:
    ///   - key: The key the mirror got where it was dropped.
    ///   - isPinned: The mirror's pin, which the owner checks against its own.
    ///   - ref: The remote workspace.
    func send(_ key: String, isPinned: Bool, for ref: SupermuxRemoteWorkspaceRef) {
        if var entry = entries[ref], entry.inFlight {
            entry.key = key
            entry.isPinned = isPinned
            entry.queued = true
            entries[ref] = entry
            return
        }
        entries[ref] = Entry(key: key, isPinned: isPinned, generation: 0, inFlight: true, replied: false, queued: false)
        dispatch(ref)
    }

    /// Drops every replied key the record of its workspace now carries.
    /// - Parameter recordKey: The current record key of a remote workspace.
    func settle(recordKey: (SupermuxRemoteWorkspaceRef) -> String?) {
        for (ref, entry) in entries where entry.replied && recordKey(ref) == entry.key {
            entries[ref] = nil
        }
    }

    /// Drops every held key (the reconciler restarts from the records).
    func reset() {
        entries.removeAll()
    }

    // MARK: - Sending

    private func dispatch(_ ref: SupermuxRemoteWorkspaceRef) {
        guard var entry = entries[ref] else { return }
        nextGeneration += 1
        entry.generation = nextGeneration
        entry.inFlight = true
        entry.replied = false
        entry.queued = false
        entries[ref] = entry
        let generation = entry.generation
        let params: [String: Any] = [
            "workspace_id": ref.workspaceID,
            "order_key": entry.key,
            "is_pinned": entry.isPinned,
        ]
        Task { @MainActor [weak self, devices] in
            guard await devices.supports(.orderSyncV1, on: ref.machine) else {
                self?.finish(ref, generation: generation, beeping: false)
                return
            }
            guard let self, self.isCurrent(ref, generation) else { return }
            self.sentCount += 1
            do {
                let reply = try await devices.request(.workspaceSetOrder, params: params, on: ref.machine)
                self.replied(ref, generation: generation, key: reply["order_key"] as? String)
            } catch {
                self.finish(ref, generation: generation, beeping: true)
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.replyTimeout)
            guard let self, self.entries[ref]?.generation == generation, self.entries[ref]?.inFlight == true else { return }
            self.finish(ref, generation: generation, beeping: true)
        }
    }

    private func isCurrent(_ ref: SupermuxRemoteWorkspaceRef, _ generation: Int) -> Bool {
        entries[ref]?.generation == generation
    }

    private func replied(_ ref: SupermuxRemoteWorkspaceRef, generation: Int, key: String?) {
        guard var entry = entries[ref], entry.generation == generation else { return }
        if entry.queued {
            entries[ref] = entry
            dispatch(ref)
            return
        }
        if let key, SupermuxOrderKey().isValid(key) { entry.key = key }
        entry.inFlight = false
        entry.replied = true
        entries[ref] = entry
        onChange?()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.replyHold)
            guard let self, self.entries[ref]?.generation == generation, self.entries[ref]?.replied == true else { return }
            self.entries[ref] = nil
            self.onChange?()
        }
    }

    /// Ends a send that failed, timed out or was not supported: the mirror
    /// falls back to its record key.
    private func finish(_ ref: SupermuxRemoteWorkspaceRef, generation: Int, beeping: Bool) {
        guard isCurrent(ref, generation) else { return }
        entries[ref] = nil
        if beeping {
            beepCount += 1
            beep()
        }
        onChange?()
    }
}
