import Foundation

/// One peer whose direct addresses are cached: the remote app instance and
/// the iroh endpoint the addresses belong to. Device and endpoint ids compare
/// case-insensitively.
public struct SupermuxRoutePeerKey: Hashable, Sendable, Codable {
    /// The peer's device id, lower-cased.
    public let deviceID: String
    /// The peer's build tag.
    public let tag: String
    /// The peer's iroh endpoint id (hex), lower-cased.
    public let endpointID: String

    /// Creates a key.
    /// - Parameters:
    ///   - deviceID: The peer's device id.
    ///   - tag: The peer's build tag.
    ///   - endpointID: The peer's endpoint id.
    public init(deviceID: String, tag: String, endpointID: String) {
        self.deviceID = deviceID.lowercased()
        self.tag = tag
        self.endpointID = endpointID.lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case tag
        case endpointID = "endpoint_id"
    }
}

/// This device's cache of other devices' direct addresses, for dialing them
/// directly from the first packet.
///
/// Two sources: what a peer handed over (``recordFetched(_:for:)``, which
/// replaces everything that peer handed over before) and what an outgoing
/// session to it actually used (``learn(_:for:)``). Each address keeps the
/// time it was last confirmed; one not confirmed for ``maximumAge`` is
/// dropped. Kept in a local JSON file only; never sent anywhere.
public actor SupermuxRouteCandidateStore {
    /// One cached address.
    public struct Candidate: Codable, Equatable, Sendable {
        /// Where the address came from.
        public enum Source: String, Codable, Sendable {
            /// The peer handed it over.
            case fetched
            /// An outgoing session to the peer used it.
            case learned
        }

        /// The canonical `ip:port` / `[v6]:port`.
        public let address: String
        /// Where it came from.
        public let source: Source
        /// When it was last confirmed.
        public var lastOK: Date

        private enum CodingKeys: String, CodingKey {
            case address, source
            case lastOK = "last_ok"
        }
    }

    /// One peer's cached addresses.
    public struct Peer: Codable, Equatable, Sendable {
        /// The peer.
        public let key: SupermuxRoutePeerKey
        /// Its addresses: handed over first (in the peer's order), then learned.
        public var candidates: [Candidate]
    }

    private struct Document: Codable {
        var version = 1
        var peers: [Peer]
    }

    /// How long an address is kept without being confirmed again.
    public static let maximumAge: TimeInterval = 7 * 24 * 3600
    /// The most peers kept; the least recently confirmed go first.
    public static let maximumPeers = 64
    /// The most learned addresses kept per peer.
    public static let maximumLearned = 8
    /// How stale a learned address's confirmation may get before using it
    /// again rewrites the file.
    public static let learnedRefreshInterval: TimeInterval = 3600

    /// The cache file; nil keeps the cache in memory only.
    public nonisolated let fileURL: URL?
    private let now: @Sendable () -> Date
    private var peersByKey: [SupermuxRoutePeerKey: Peer] = [:]
    private var loaded = false

    /// Creates a store over `fileURL`, read on first use.
    /// - Parameters:
    ///   - fileURL: The cache file, or nil for memory only.
    ///   - now: The clock.
    public init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    /// Records what a peer handed over, replacing what it handed over
    /// before; learned addresses stay. Only servable addresses are kept
    /// (``SupermuxRouteCandidates/servable(_:)``); an empty list forgets
    /// what the peer handed over.
    @discardableResult
    public func recordFetched(_ addresses: [String], for key: SupermuxRoutePeerKey) -> Bool {
        defer { _ = 0 }
        return recordFetchedStub(addresses, for: key)
    }

    // Red stub (review T3, T12): an empty answer still wipes; forget does nothing.
    public func forget(_ key: SupermuxRoutePeerKey) {}

    private func recordFetchedStub(_ addresses: [String], for key: SupermuxRoutePeerKey) -> Bool {
        loadIfNeeded()
        let time = now()
        let fetched = SupermuxRouteCandidates.servable(addresses)
            .map { Candidate(address: $0, source: .fetched, lastOK: time) }
        let learned = (peersByKey[key]?.candidates ?? []).filter { candidate in
            candidate.source == .learned && !fetched.contains { $0.address == candidate.address }
        }
        update(key, candidates: fetched + learned)
        return true
    }

    /// Records that an outgoing session to the peer used `address`. Ignored
    /// when the address is not dialable; rewrites the file only when the
    /// address is new or its confirmation is older than ``learnedRefreshInterval``.
    public func learn(_ address: String, for key: SupermuxRoutePeerKey) {
        guard let parsed = SupermuxSocketAddress(address), parsed.isDialable else { return }
        loadIfNeeded()
        let time = now()
        var candidates = peersByKey[key]?.candidates ?? []
        if let index = candidates.firstIndex(where: { $0.address == parsed.description }) {
            guard time.timeIntervalSince(candidates[index].lastOK) >= Self.learnedRefreshInterval else { return }
            candidates[index].lastOK = time
        } else {
            candidates.append(Candidate(address: parsed.description, source: .learned, lastOK: time))
        }
        update(key, candidates: candidates)
    }

    /// The addresses to dial the peer at: handed over first, then learned
    /// (most recent first), at most ``SupermuxRouteCandidates/limit``.
    public func dialAddresses(for key: SupermuxRoutePeerKey) -> [String] {
        loadIfNeeded()
        let fresh = (peersByKey[key]?.candidates ?? []).filter(isFresh)
        let fetched = fresh.filter { $0.source == .fetched }
        let learned = fresh.filter { $0.source == .learned }.sorted { $0.lastOK > $1.lastOK }
        return (fetched + learned).prefix(SupermuxRouteCandidates.limit).map(\.address)
    }

    /// Every cached peer with its unexpired addresses, most recent first.
    public func peers() -> [Peer] {
        loadIfNeeded()
        return peersByKey.values
            .map { Peer(key: $0.key, candidates: $0.candidates.filter(isFresh)) }
            .filter { !$0.candidates.isEmpty }
            .sorted { Self.newest($0) > Self.newest($1) }
    }

    // MARK: - State

    private func isFresh(_ candidate: Candidate) -> Bool {
        now().timeIntervalSince(candidate.lastOK) < Self.maximumAge
    }

    private func update(_ key: SupermuxRoutePeerKey, candidates: [Candidate]) {
        let fresh = candidates.filter(isFresh)
        let learned = fresh.filter { $0.source == .learned }
            .sorted { $0.lastOK > $1.lastOK }
            .prefix(Self.maximumLearned)
        let kept = fresh.filter { $0.source == .fetched } + learned
        peersByKey[key] = kept.isEmpty ? nil : Peer(key: key, candidates: Array(kept))
        if peersByKey.count > Self.maximumPeers {
            let oldest = peersByKey.values.sorted { Self.newest($0) > Self.newest($1) }.dropFirst(Self.maximumPeers)
            for peer in oldest { peersByKey[peer.key] = nil }
        }
        save()
    }

    private static func newest(_ peer: Peer) -> Date {
        peer.candidates.map(\.lastOK).max() ?? .distantPast
    }

    // MARK: - File

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let document = try? decoder.decode(Document.self, from: data) else { return }
        for peer in document.peers { peersByKey[peer.key] = peer }
    }

    private func save() {
        guard let fileURL else { return }
        let document = Document(peers: peers())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(document) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
