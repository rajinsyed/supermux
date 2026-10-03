import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// The viewer half of terminal streaming (`supermux.terminal_stream.v1`,
/// touchpoints #777–#783): what makes a device mirror follow another Mac's
/// terminal like a local one when that Mac's host streams.
///
/// - Per-terminal subscription: each link names the terminals it mirrors
///   (``SupermuxTerminalStreamWatch``); the host sends `terminal.bytes` only for
///   those, and never sheds them.
/// - Resume instead of replay: a seq gap, a reconnect or a re-anchor asks the
///   host for the bytes since the mirror's last byte position (exact while the
///   host's byte tail holds them and the stream stayed continuous); only then a
///   render-grid replay, which asks for deep scrollback (screen-anchored,
///   ``scrollbackRows`` rows) instead of upstream's ~240.
/// - A remote grid change only re-pins the mirror; the bytes that follow
///   repaint it, as on the owning Mac itself.
///
/// A host without the capability keeps upstream's path unchanged.
@MainActor
final class SupermuxTerminalStream {
    /// Events a mirror session may hold before its stream drops (upstream: 512).
    static let sessionEventBufferLimit = 4096
    /// Bytes a session buffers while a replay or resume is in flight
    /// (upstream: 512 chunks / 256 KB; past them it replays again).
    static let attachBufferChunkLimit = 16_384
    static let attachBufferByteLimit = 16 * 1024 * 1024
    /// History rows a render-grid replay carries (the phone's ceiling is 20000).
    static let scrollbackRows = 10_000
    /// Drops this Mac's scrollback before a full replay: a screen-anchored
    /// replay without history repaints in place and would keep stale rows.
    static let historyReset = Data([0x1B, 0x5B, 0x33, 0x4A])

    let watch: SupermuxTerminalStreamWatch
    let surfaceID: UUID
    private var registered = false
    /// The link connection this mirror streams on, when the host streams.
    private var streamingConnection: UInt64?
    /// The host's name for the byte stream the mirror's position belongs to.
    private var epoch: String?
    private(set) var fullReplays = 0
    private(set) var resumes = 0
    private(set) var gaps = 0

    init(link: DeviceLink, surfaceID: UUID) {
        watch = SupermuxTerminalStreamWatch.of(link)
        self.surfaceID = surfaceID
    }

    /// Whether the mirror streams on the link's current connection.
    var isActive: Bool { streamingConnection == watch.connection }

    /// Before each replay: watch this terminal on the current connection.
    /// False when the host does not stream (upstream's path then).
    func prepare() async -> Bool {
        if !registered {
            registered = true
            watch.add(surfaceID)
        }
        let connection = watch.connection
        let streams = await watch.ensure(including: surfaceID)
        streamingConnection = streams ? connection : nil
        return streams && isActive
    }

    func stop() {
        guard registered else { return }
        registered = false
        streamingConnection = nil
        watch.remove(surfaceID)
    }

    func noteGap() { gaps += 1 }

    /// The replay request's streaming params: deep scrollback, and the byte
    /// position to resume from when the mirror has one on this stream.
    func replayParams(expectedSequence: UInt64?, grid: (columns: Int, rows: Int)?) -> [String: Any] {
        guard isActive else { return [:] }
        var params: [String: Any] = [
            SupermuxTerminalStreamHost.streamParam: 1,
            "anchor": "screen",
            "max_scrollback_rows": Self.scrollbackRows,
        ]
        if let epoch, let expectedSequence, let grid {
            params[SupermuxTerminalStreamHost.resumeFromParam] = expectedSequence
            params[SupermuxTerminalStreamHost.resumeEpochParam] = epoch
            params[SupermuxTerminalStreamHost.resumeColumnsParam] = grid.columns
            params[SupermuxTerminalStreamHost.resumeRowsParam] = grid.rows
        }
        return params
    }

    func noteReply(_ reply: Reply) {
        epoch = reply.epoch
        if reply.resumed == nil { fullReplays += 1 } else { resumes += 1 }
    }

    /// A replay reply, as far as streaming reads it.
    struct Reply: Sendable {
        struct Resumed: Sendable {
            let bytes: Data
            let sequence: UInt64
            let columns: Int?
            let rows: Int?
        }

        var epoch: String?
        /// The bytes since the requested position, when the host resumed.
        var resumed: Resumed?
    }

    private nonisolated static let resumedMarker = Data("\"\(SupermuxTerminalStreamHost.resumedKey)\":true".utf8)
    private nonisolated static let epochMarker = Data("\"\(SupermuxTerminalStreamHost.epochKey)\":\"".utf8)

    /// Reads a replay reply off the main actor. A full replay (often MBs of
    /// grid) is only scanned for its epoch, never parsed a second time.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func decodeReply(_ data: Data) async -> Reply {
        guard data.range(of: resumedMarker) != nil else {
            return Reply(epoch: scannedEpoch(data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object[SupermuxTerminalStreamHost.resumedKey] as? Bool == true,
              let sequence = (object["seq"] as? NSNumber)?.uint64Value,
              let encoded = object["data_b64"] as? String,
              let bytes = Data(base64Encoded: encoded) else {
            return Reply(epoch: scannedEpoch(data))
        }
        return Reply(
            epoch: object[SupermuxTerminalStreamHost.epochKey] as? String,
            resumed: Reply.Resumed(
                bytes: bytes,
                sequence: sequence,
                columns: (object["columns"] as? NSNumber)?.intValue,
                rows: (object["rows"] as? NSNumber)?.intValue
            )
        )
    }

    /// The epoch's value (a UUID string, so never escaped) after its key.
    private nonisolated static func scannedEpoch(_ data: Data) -> String? {
        guard let key = data.range(of: epochMarker) else { return nil }
        let rest = data[key.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")),
              let value = String(data: rest[rest.startIndex..<end], encoding: .utf8),
              UUID(uuidString: value) != nil else { return nil }
        return value
    }
}

/// One link's watched terminals: the set its host sends `terminal.bytes` for,
/// kept in step with the mirror sessions that stream on it. Each connection
/// starts topic-wide on the host, so the set is sent again after every
/// (re)connect (``SupermuxDeviceLinkEvents``).
@MainActor
final class SupermuxTerminalStreamWatch {
    private static var byInstance: [SurfaceDeviceInstanceID: SupermuxTerminalStreamWatch] = [:]

    static func of(_ link: DeviceLink) -> SupermuxTerminalStreamWatch {
        if let existing = byInstance[link.instance], existing.link === link { return existing }
        let watch = SupermuxTerminalStreamWatch(link: link)
        byInstance[link.instance] = watch
        return watch
    }

    static func existing(_ instance: SurfaceDeviceInstanceID) -> SupermuxTerminalStreamWatch? {
        byInstance[instance]
    }

    private weak var link: DeviceLink?
    let instance: SurfaceDeviceInstanceID
    /// Bumps when the link loses its connection: what was watched is gone.
    private(set) var connection: UInt64 = 0
    private var counts: [UUID: Int] = [:]
    private var acked: (connection: UInt64, surfaces: Set<UUID>)?
    private var failedConnection: UInt64?
    private var syncTask: Task<Void, Never>?
    #if DEBUG
    /// Every `terminal.bytes` byte this link received, by remote terminal.
    private(set) var bytesReceived: [UUID: Int] = [:]
    #endif

    private init(link: DeviceLink) {
        self.link = link
        instance = link.instance
        #if DEBUG
        link.terminalEvents.supermuxOnBytes = { [weak self] surfaceID, count in
            self?.bytesReceived[surfaceID, default: 0] += count
        }
        #endif
    }

    var watching: Set<UUID>? { acked?.connection == connection ? acked?.surfaces : nil }

    func add(_ surfaceID: UUID) {
        counts[surfaceID, default: 0] += 1
    }

    func remove(_ surfaceID: UUID) {
        guard let count = counts[surfaceID] else { return }
        counts[surfaceID] = count > 1 ? count - 1 : nil
        if acked?.connection == connection { _ = sync() }
    }

    func linkLost() {
        connection &+= 1
        acked = nil
        failedConnection = nil
    }

    /// A fresh connection: name the watched terminals (none yet, possibly) so
    /// the host stops sending the others' bytes at once.
    func linkConnected() {
        Task { [weak self] in _ = await self?.ensure(including: nil) }
    }

    /// Whether the host streams on the current connection with `surfaceID`
    /// (when given) watched; sends the set first when it changed.
    func ensure(including surfaceID: UUID?) async -> Bool {
        let connection = self.connection
        guard let link, link.isConnected,
              await SupermuxComposition.devices.supports(.terminalStreamV1, on: .device(instance)),
              connection == self.connection else { return false }
        for _ in 0..<3 {
            if let acked, acked.connection == connection, acked.surfaces == Set(counts.keys) { break }
            failedConnection = nil
            await sync().value
            guard connection == self.connection, failedConnection != connection else { return false }
        }
        guard let acked, acked.connection == connection else { return false }
        return surfaceID.map(acked.surfaces.contains) ?? true
    }

    /// Single-flight: sends the watched set until the host has the latest one.
    private func sync() -> Task<Void, Never> {
        if let syncTask { return syncTask }
        let task = Task { [weak self] in
            while let self {
                let connection = self.connection
                let desired = Set(self.counts.keys)
                if let acked = self.acked, acked.connection == connection, acked.surfaces == desired { break }
                guard let link = self.link, link.isConnected else { break }
                do {
                    _ = try await link.request(
                        SupermuxMobileMethod.terminalWatch.rawValue,
                        params: ["surface_ids": desired.map(\.uuidString).sorted()]
                    )
                    guard connection == self.connection else { break }
                    self.acked = (connection, desired)
                } catch {
                    self.failedConnection = connection
                    break
                }
            }
            self?.syncTask = nil
        }
        syncTask = task
        return task
    }
}

#if DEBUG
extension SupermuxTerminalStreamWatch {
    /// `supermux.devices.terminal_stream.stats` for this link.
    func debugStats(sessions: [UUID: DeviceTerminalMirrorSession]) -> [String: Any] {
        let panes = sessions.sorted { $0.key.uuidString < $1.key.uuidString }.map { panelID, session -> [String: Any] in
            let stream = session.supermuxStream
            return [
                "panel_id": panelID.uuidString,
                "remote_surface_id": session.remoteSurfaceID.uuidString,
                "streaming": stream?.isActive ?? false,
                "full_replays": stream?.fullReplays ?? 0,
                "resumes": stream?.resumes ?? 0,
                "gaps": stream?.gaps ?? 0,
            ]
        }
        return [
            "supported": watching != nil,
            "watching": watching.map { $0.map(\.uuidString).sorted() } ?? NSNull(),
            "bytes_received_by_surface": Dictionary(uniqueKeysWithValues: bytesReceived.map { ($0.key.uuidString, $0.value) }),
            "panes": panes,
        ]
    }
}
#endif
