/// Entry- and byte-bounded least-recently-used storage.
struct SupermuxHarnessLRUCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var byteCost: Int
        var accessOrder: UInt64
    }

    private let maximumEntries: Int
    private let maximumBytes: Int
    private var entries: [Key: Entry] = [:]
    private var nextAccessOrder: UInt64 = 0
    private(set) var byteCount = 0

    init(maximumEntries: Int, maximumBytes: Int) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumBytes = max(0, maximumBytes)
    }

    var count: Int { entries.count }

    mutating func value(forKey key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        nextAccessOrder &+= 1
        entry.accessOrder = nextAccessOrder
        entries[key] = entry
        return entry.value
    }

    mutating func setValue(
        _ value: Value,
        forKey key: Key,
        byteCost: Int
    ) -> [Key] {
        if let old = entries.removeValue(forKey: key) {
            self.byteCount -= old.byteCost
        }
        nextAccessOrder &+= 1
        let boundedCost = max(0, byteCost)
        entries[key] = Entry(
            value: value,
            byteCost: boundedCost,
            accessOrder: nextAccessOrder
        )
        self.byteCount += boundedCost
        return evictIfNeeded()
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        byteCount -= entry.byteCost
        return entry.value
    }

    private mutating func evictIfNeeded() -> [Key] {
        var evicted: [Key] = []
        while entries.count > maximumEntries || byteCount > maximumBytes {
            guard let victim = entries.min(by: {
                $0.value.accessOrder < $1.value.accessOrder
            })?.key,
            let entry = entries.removeValue(forKey: victim) else {
                break
            }
            byteCount -= entry.byteCost
            evicted.append(victim)
        }
        return evicted
    }
}
