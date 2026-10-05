import Foundation
import Testing
@testable import SupermuxMobileCore

/// Ways the direct-address exchange (`route.candidates`) and its local cache
/// could go wrong, written before them:
/// 1. A host hands over an address another Mac cannot dial: loopback,
///    unspecified, link-local (its zone named the host's own interface),
///    multicast, a public IPv4 (a NAT mapping a cold dial cannot use) or a
///    CGNAT address that is not a Tailscale peer.
/// 2. A malformed or hostile list (not `ip:port`, port 0, a non-canonical
///    spelling, duplicates, hundreds of entries) reaching iroh's
///    `EndpointAddr`, where a bad string fails the whole dial, or bloating
///    the cache.
/// 3. LAN not tried before Tailscale, or more than 16 addresses.
/// 4. A stale LAN address after a DHCP change, a fixed port that fell back to
///    an ephemeral one, or a rotated IPv6 temporary address kept beside the
///    new one: a fetch must replace what the peer handed over before.
/// 5. (Review T3) An empty answer (a host before its first network report,
///    1–3 s after it bound) wiping the addresses the peer handed over before;
///    a host that turned direct off (relay-only) leaving them dialable.
/// 6. A re-enrolled peer (new endpoint id) or a peer looked up under another
///    device or tag getting the old addresses; a revoked peer's addresses
///    kept forever instead of aging out after 7 days.
/// 7. Learned addresses (an outgoing session's selected direct path): lost
///    on the next fetch, kept forever unused, accepted when not dialable or
///    not servable (review T10b: a public IPv4 NAT mapping a cold dial cannot
///    use), or rewriting the file on every 2 s sample.
/// 8. Persistence: lost on restart, or a corrupt file crashing the app
///    instead of reading as an empty cache.
/// 9. Device and endpoint ids compared case-sensitively.
/// 10. An unbounded number of peers.
@Suite struct SupermuxRouteCandidateStoreTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
    }

    private let key = SupermuxRoutePeerKey(deviceID: "8F6D9357-AAAA", tag: "default", endpointID: "ABCDEF0123")
    private static let day: TimeInterval = 24 * 3600

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-route-candidates-\(UUID().uuidString)")
            .appendingPathComponent("candidates.json")
    }

    private func store(_ file: URL? = nil, clock: Clock = Clock()) -> SupermuxRouteCandidateStore {
        SupermuxRouteCandidateStore(fileURL: file, now: { clock.now })
    }

    // MARK: What a host serves

    @Test func servesOnlyLANTailscaleAndGlobalIPv6() {
        let served = SupermuxRouteCandidates.servable([
            "127.0.0.1:58465", "0.0.0.0:58465", "[::1]:58465", "[::]:58465",
            "[fe80::1%14]:58465", "169.254.3.4:58465", "224.0.0.251:5353", "[ff02::fb]:5353",
            "203.0.113.7:58465", "100.100.100.100:53",
            "192.168.1.196:58465", "100.69.64.102:58465", "[fd7a:115c:a1e0::9]:58465",
            "[2001:db8:1::5]:58465", "[fd12:3456::1]:58465",
        ])
        #expect(served == [
            "192.168.1.196:58465", "[fd12:3456::1]:58465",
            "100.69.64.102:58465", "[fd7a:115c:a1e0::9]:58465",
            "[2001:db8:1::5]:58465",
        ])
    }

    @Test func malformedDuplicateAndExcessEntriesAreDropped() {
        var many = (1...40).map { "10.0.0.\($0):58465" }
        many.insert(contentsOf: ["garbage", "10.0.0.1", "10.0.0.1:0", "010.0.0.1:58465", "10.0.0.1:58465", "[::ffff:10.0.0.1]:58465"], at: 0)
        let served = SupermuxRouteCandidates.servable(many)
        #expect(served.count == SupermuxRouteCandidates.limit)
        #expect(served.first == "10.0.0.1:58465")
        #expect(Set(served).count == served.count)
        #expect(served.allSatisfy { SupermuxSocketAddress($0)?.description == $0 })
    }

    @Test func dtoCodesSnakeCase() throws {
        let dto = SupermuxRouteCandidatesDTO(endpointID: "abc", addresses: ["192.168.1.2:58465"])
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any])
        #expect(object["endpoint_id"] as? String == "abc")
        #expect(object["addresses"] as? [String] == ["192.168.1.2:58465"])
        #expect(try JSONDecoder().decode(SupermuxRouteCandidatesDTO.self, from: JSONEncoder().encode(dto)) == dto)
    }

    // MARK: Fetches

    @Test func aFetchReplacesWhatThePeerHandedOverBefore() async {
        let store = store()
        await store.recordFetched(["192.168.1.20:58465", "[2001:db8::aaaa]:58465", "100.69.64.102:58465"], for: key)
        await store.recordFetched(["192.168.1.21:61234", "[2001:db8::bbbb]:61234", "100.69.64.102:61234"], for: key)
        #expect(await store.dialAddresses(for: key) == [
            "192.168.1.21:61234", "100.69.64.102:61234", "[2001:db8::bbbb]:61234",
        ])
    }

    @Test func anEmptyFetchKeepsWhatThePeerHandedOver() async {
        let store = store()
        #expect(await store.recordFetched(["192.168.1.20:58465"], for: key))
        let stored = await store.recordFetched([], for: key)
        #expect(!stored, "an empty answer is not authoritative")
        #expect(await store.dialAddresses(for: key) == ["192.168.1.20:58465"])
        #expect(await !store.recordFetched(["127.0.0.1:58465"], for: key), "nothing servable is empty too")
        #expect(await store.dialAddresses(for: key) == ["192.168.1.20:58465"])
    }

    @Test func aPeerThatTurnedDirectOffIsForgotten() async {
        let store = store()
        await store.recordFetched(["192.168.1.20:58465"], for: key)
        await store.learn("100.69.64.102:58465", for: key)
        await store.forget(key)
        #expect(await store.dialAddresses(for: key).isEmpty)
        #expect(await store.peers().isEmpty)
    }

    @Test func aFetchKeepsOnlyDialableAddresses() async {
        let store = store()
        await store.recordFetched(["127.0.0.1:58465", "203.0.113.7:58465", "bad", "10.1.2.3:58465"], for: key)
        #expect(await store.dialAddresses(for: key) == ["10.1.2.3:58465"])
    }

    @Test func otherKeysNeverSeeThePeersAddresses() async {
        let store = store()
        await store.recordFetched(["192.168.1.20:58465"], for: key)
        let reenrolled = SupermuxRoutePeerKey(deviceID: key.deviceID, tag: key.tag, endpointID: "fffff")
        let otherTag = SupermuxRoutePeerKey(deviceID: key.deviceID, tag: "nightly", endpointID: key.endpointID)
        #expect(await store.dialAddresses(for: reenrolled).isEmpty)
        #expect(await store.dialAddresses(for: otherTag).isEmpty)
        let sameButCased = SupermuxRoutePeerKey(deviceID: "8f6d9357-aaaa", tag: "default", endpointID: "abcdef0123")
        #expect(await store.dialAddresses(for: sameButCased) == ["192.168.1.20:58465"])
    }

    @Test func addressesAgeOutAfterSevenDays() async {
        let clock = Clock()
        let store = store(clock: clock)
        await store.recordFetched(["192.168.1.20:58465"], for: key)
        clock.advance(7 * Self.day - 60)
        #expect(await store.dialAddresses(for: key) == ["192.168.1.20:58465"])
        clock.advance(120)
        #expect(await store.dialAddresses(for: key).isEmpty)
    }

    // MARK: Learned addresses

    @Test func learnedAddressesSurviveAFetchAndFollowFetchedOnes() async {
        let store = store()
        await store.learn("100.69.64.102:58465", for: key)
        await store.recordFetched(["192.168.1.20:58465"], for: key)
        #expect(await store.dialAddresses(for: key) == ["192.168.1.20:58465", "100.69.64.102:58465"])
        await store.learn("192.168.1.20:58465", for: key)
        #expect(await store.dialAddresses(for: key) == ["192.168.1.20:58465", "100.69.64.102:58465"])
    }

    @Test func undialableAndUnservableAddressesAreNotLearned() async {
        let store = store()
        for address in ["127.0.0.1:58465", "[fe80::1%en0]:58465", "0.0.0.0:1", "nonsense", "https://apne1.relay.cmux.dev/",
                        "203.0.113.7:58465", "100.64.0.1:58465"] {
            await store.learn(address, for: key)
        }
        #expect(await store.peers().isEmpty)
    }

    @Test func aLearnedAddressInUseStaysAndAnUnusedOneAgesOut() async {
        let clock = Clock()
        let store = store(clock: clock)
        await store.learn("100.69.64.102:58465", for: key)
        await store.learn("192.168.1.30:58465", for: key)
        for _ in 0..<8 {
            clock.advance(Self.day)
            await store.learn("100.69.64.102:58465", for: key)
        }
        #expect(await store.dialAddresses(for: key) == ["100.69.64.102:58465"])
    }

    @Test func learningEveryFewSecondsDoesNotRewriteTheFile() async throws {
        let file = temporaryFile()
        let clock = Clock()
        let store = store(file, clock: clock)
        await store.learn("100.69.64.102:58465", for: key)
        let first = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let firstData = try Data(contentsOf: file)
        for _ in 0..<30 {
            clock.advance(2)
            await store.learn("100.69.64.102:58465", for: key)
        }
        #expect(try Data(contentsOf: file) == firstData)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == first)
    }

    // MARK: Persistence and bounds

    @Test func theCacheSurvivesARestart() async {
        let file = temporaryFile()
        let clock = Clock()
        await store(file, clock: clock).recordFetched(["192.168.1.20:58465", "100.69.64.102:58465"], for: key)
        let reopened = store(file, clock: clock)
        #expect(await reopened.dialAddresses(for: key) == ["192.168.1.20:58465", "100.69.64.102:58465"])
    }

    @Test func aCorruptFileIsAnEmptyCache() async throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file)
        let store = store(file)
        #expect(await store.dialAddresses(for: key).isEmpty)
        await store.recordFetched(["192.168.1.20:58465"], for: key)
        #expect(await self.store(file).dialAddresses(for: key) == ["192.168.1.20:58465"])
    }

    @Test func peersAreBounded() async {
        let clock = Clock()
        let store = store(clock: clock)
        for index in 0..<(SupermuxRouteCandidateStore.maximumPeers + 5) {
            clock.advance(1)
            let peer = SupermuxRoutePeerKey(deviceID: "device-\(index)", tag: "default", endpointID: "e\(index)")
            await store.recordFetched(["192.168.1.\(index % 250 + 1):58465"], for: peer)
        }
        let peers = await store.peers()
        #expect(peers.count == SupermuxRouteCandidateStore.maximumPeers)
        #expect(!peers.contains { $0.key.deviceID == "device-0" })
    }
}
