public import Foundation

/// The pure decision core of the auto-mirror coordinator: given every device's
/// remote workspaces and every local mirror, which mirrors to open, which to
/// close, and which hidden refs to forget.
///
/// Rules:
/// - **Open** a remote workspace when auto-mirror is on, its device is
///   authoritative (connected and its records fetched since the connect), it
///   has at least one terminal, it is not hidden, no open for it is already in
///   flight or backing off (`busy`), and no local workspace shows it yet (a
///   bound mirror, or one whose panes project it — including restored
///   placeholders still waiting for the link). Opens come out in the remote's
///   sort order.
/// - **Close** a mirror only on *authoritative, confirmed* evidence: its
///   device is authoritative and the remote workspace is absent in two
///   observations at least ``confirmationInterval`` apart. Losing authority or
///   the workspace reappearing resets the suspicion. Mirrors of a device that
///   is not registered at all are never touched. This runs even with
///   auto-mirror off, so a dead mirror never lingers.
/// - **Orphan**: a bound mirror whose projections were dropped (no live or
///   pending projection) while its remote workspace still exists is closed the
///   same confirmed way, so the next pass reopens it fresh. Only with
///   auto-mirror on (otherwise nothing would reopen it).
/// - **Hidden** refs whose remote workspace is confirmed gone are unhidden, so
///   the hidden set never outgrows the live remote workspaces.
///
/// ```swift
/// var reconciler = SupermuxMirrorReconciler()
/// let plan = reconciler.plan(input)
/// // execute plan.closes, plan.opens; call again after plan.followUpAfter
/// ```
public struct SupermuxMirrorReconciler: Sendable {
    /// One workspace on a device, as its synced record reports it.
    public struct RemoteWorkspace: Equatable, Sendable {
        public let workspaceID: String
        public let terminalCount: Int
        public let sortIndex: Int

        public init(workspaceID: String, terminalCount: Int, sortIndex: Int) {
            self.workspaceID = workspaceID
            self.terminalCount = terminalCount
            self.sortIndex = sortIndex
        }
    }

    /// One registered device.
    public struct Device: Equatable, Sendable {
        public let machineID: String
        /// Connected, and its records were fetched since the connect: an
        /// absent record then really means the workspace is gone.
        public let isAuthoritative: Bool
        public let workspaces: [RemoteWorkspace]

        public init(machineID: String, isAuthoritative: Bool, workspaces: [RemoteWorkspace]) {
            self.machineID = machineID
            self.isAuthoritative = isAuthoritative
            self.workspaces = workspaces
        }
    }

    /// One local workspace mirroring a remote workspace.
    public struct Mirror: Equatable, Sendable {
        public let ref: SupermuxRemoteWorkspaceRef
        public let localWorkspaceID: UUID
        /// A persisted binding names it (not only live projections).
        public let isBound: Bool
        /// It has a live or pending-restore projection on the ref's device.
        public let isProjected: Bool

        public init(ref: SupermuxRemoteWorkspaceRef, localWorkspaceID: UUID, isBound: Bool, isProjected: Bool) {
            self.ref = ref
            self.localWorkspaceID = localWorkspaceID
            self.isBound = isBound
            self.isProjected = isProjected
        }
    }

    /// Everything one pass decides from.
    public struct Input: Sendable {
        public let autoMirror: Bool
        public let devices: [Device]
        public let mirrors: [Mirror]
        public let hidden: Set<SupermuxRemoteWorkspaceRef>
        /// Refs with an open in flight or backing off after a failure.
        public let busy: Set<SupermuxRemoteWorkspaceRef>
        public let now: Date

        public init(
            autoMirror: Bool,
            devices: [Device],
            mirrors: [Mirror],
            hidden: Set<SupermuxRemoteWorkspaceRef>,
            busy: Set<SupermuxRemoteWorkspaceRef>,
            now: Date
        ) {
            self.autoMirror = autoMirror
            self.devices = devices
            self.mirrors = mirrors
            self.hidden = hidden
            self.busy = busy
            self.now = now
        }
    }

    /// Why a mirror closes.
    public enum CloseReason: String, Sendable {
        /// Its remote workspace is gone.
        case remoteGone
        /// It lost its projections while the remote workspace still exists.
        case orphaned
    }

    /// One local mirror to close (locally only, never on its Mac).
    public struct Close: Equatable, Sendable {
        public let localWorkspaceID: UUID
        public let ref: SupermuxRemoteWorkspaceRef
        public let reason: CloseReason

        public init(localWorkspaceID: UUID, ref: SupermuxRemoteWorkspaceRef, reason: CloseReason) {
            self.localWorkspaceID = localWorkspaceID
            self.ref = ref
            self.reason = reason
        }
    }

    /// What one pass decided.
    public struct Plan: Equatable, Sendable {
        public var opens: [SupermuxRemoteWorkspaceRef] = []
        public var closes: [Close] = []
        /// Hidden refs whose remote workspace is gone.
        public var unhide: [SupermuxRemoteWorkspaceRef] = []
        /// Run another pass after this many seconds to confirm a pending suspicion.
        public var followUpAfter: TimeInterval?

        /// An empty plan (nothing to open, close or unhide).
        public init() {}
    }

    private enum SuspicionKind: Hashable, Sendable {
        case gone(UUID)
        case orphan(UUID)
        case hiddenGone
    }

    private struct SuspicionKey: Hashable, Sendable {
        let ref: SupermuxRemoteWorkspaceRef
        let kind: SuspicionKind
    }

    /// How far apart two observations must be before one confirms the other.
    public var confirmationInterval: TimeInterval
    private var suspicions: [SuspicionKey: Date] = [:]

    public init(confirmationInterval: TimeInterval = 1.0) {
        self.confirmationInterval = confirmationInterval
    }

    /// Decides one pass and remembers the suspicions it still waits on.
    public mutating func plan(_ input: Input) -> Plan {
        var plan = Plan()
        var seen: [SuspicionKey: Date] = [:]
        let devicesByID = Dictionary(input.devices.map { ($0.machineID, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByRef = Self.remoteWorkspacesByRef(input.devices)
        let mirroredRefs = Set(input.mirrors.map(\.ref))

        for mirror in input.mirrors {
            guard let device = devicesByID[mirror.ref.machineID], device.isAuthoritative else { continue }
            if let remote = remoteByRef[mirror.ref] {
                let isOrphan = input.autoMirror && mirror.isBound && !mirror.isProjected
                    && remote.terminalCount > 0 && !input.busy.contains(mirror.ref)
                guard isOrphan else { continue }
                let key = SuspicionKey(ref: mirror.ref, kind: .orphan(mirror.localWorkspaceID))
                if observe(key, now: input.now, into: &seen) {
                    plan.closes.append(Close(localWorkspaceID: mirror.localWorkspaceID, ref: mirror.ref, reason: .orphaned))
                }
            } else {
                let key = SuspicionKey(ref: mirror.ref, kind: .gone(mirror.localWorkspaceID))
                if observe(key, now: input.now, into: &seen) {
                    plan.closes.append(Close(localWorkspaceID: mirror.localWorkspaceID, ref: mirror.ref, reason: .remoteGone))
                }
            }
        }

        for ref in input.hidden.sorted(by: { $0.description < $1.description }) {
            guard devicesByID[ref.machineID]?.isAuthoritative == true, remoteByRef[ref] == nil else { continue }
            if observe(SuspicionKey(ref: ref, kind: .hiddenGone), now: input.now, into: &seen) {
                plan.unhide.append(ref)
            }
        }

        if input.autoMirror {
            for device in input.devices where device.isAuthoritative {
                plan.opens.append(contentsOf: Self.opens(on: device, input: input, mirrored: mirroredRefs))
            }
        }

        suspicions = seen
        plan.followUpAfter = followUp(now: input.now)
        return plan
    }

    /// Records one observation of `key`; true when it confirms an earlier one
    /// at least ``confirmationInterval`` ago (the key is then dropped).
    private func observe(_ key: SuspicionKey, now: Date, into seen: inout [SuspicionKey: Date]) -> Bool {
        let firstSeen = suspicions[key] ?? now
        if now.timeIntervalSince(firstSeen) >= confirmationInterval { return true }
        seen[key] = firstSeen
        return false
    }

    private func followUp(now: Date) -> TimeInterval? {
        guard let earliest = suspicions.values.min() else { return nil }
        let remaining = confirmationInterval - now.timeIntervalSince(earliest)
        return max(remaining, 0) + 0.05
    }

    /// One device's workspaces that need a mirror, in the remote's sort order.
    private static func opens(
        on device: Device,
        input: Input,
        mirrored: Set<SupermuxRemoteWorkspaceRef>
    ) -> [SupermuxRemoteWorkspaceRef] {
        var candidates: [(ref: SupermuxRemoteWorkspaceRef, sortIndex: Int)] = []
        for workspace in device.workspaces where workspace.terminalCount > 0 {
            let ref = SupermuxRemoteWorkspaceRef(machineID: device.machineID, workspaceID: workspace.workspaceID)
            let skipped = mirrored.contains(ref) || input.hidden.contains(ref) || input.busy.contains(ref)
            if !skipped { candidates.append((ref, workspace.sortIndex)) }
        }
        candidates.sort { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.ref.workspaceID < rhs.ref.workspaceID
        }
        return candidates.map { $0.ref }
    }

    private static func remoteWorkspacesByRef(_ devices: [Device]) -> [SupermuxRemoteWorkspaceRef: RemoteWorkspace] {
        var result: [SupermuxRemoteWorkspaceRef: RemoteWorkspace] = [:]
        for device in devices {
            for workspace in device.workspaces {
                result[SupermuxRemoteWorkspaceRef(machineID: device.machineID, workspaceID: workspace.workspaceID)] = workspace
            }
        }
        return result
    }
}
