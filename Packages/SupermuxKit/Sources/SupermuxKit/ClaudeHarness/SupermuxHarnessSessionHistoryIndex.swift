/// Incrementally mergeable graph and leaf pointers for history replay.
struct SupermuxHarnessSessionHistoryIndex: Sendable {
    var linksByUUID: [String: SupermuxHarnessSessionRecordLink] = [:]
    var eventRangesByUUID: [String: SupermuxHarnessSessionRecordRange] = [:]
    var summaryLeaf: String?
    var lastPromptLeaf: String?
    var lastMainUUID: String?

    var byteCost: Int {
        let leafBytes = (summaryLeaf?.utf8.count ?? 0) +
            (lastPromptLeaf?.utf8.count ?? 0) +
            (lastMainUUID?.utf8.count ?? 0)
        let linkBytes = linksByUUID.reduce(0) { partial, entry in
            partial + entry.key.utf8.count + entry.value.byteCost + 32
        }
        let eventRangeBytes = eventRangesByUUID.reduce(0) { partial, entry in
            partial + entry.key.utf8.count + 48
        }
        return 96 + leafBytes + linkBytes + eventRangeBytes
    }

    mutating func merge(_ newer: Self) {
        linksByUUID.merge(newer.linksByUUID) { _, new in new }
        eventRangesByUUID.merge(newer.eventRangesByUUID) { _, new in new }
        if let value = newer.summaryLeaf { summaryLeaf = value }
        if let value = newer.lastPromptLeaf { lastPromptLeaf = value }
        if let value = newer.lastMainUUID { lastMainUUID = value }
    }

    mutating func apply(_ record: SupermuxHarnessSessionIndexedRecord) {
        if let uuid = record.uuid, let link = record.link {
            if record.eventRange != nil || linksByUUID[uuid] == nil {
                linksByUUID[uuid] = link
            }
            if let eventRange = record.eventRange {
                eventRangesByUUID[uuid] = eventRange
            }
        }
        if let value = record.summaryLeaf { summaryLeaf = value }
        if let value = record.lastPromptLeaf { lastPromptLeaf = value }
        if let value = record.lastMainUUID { lastMainUUID = value }
    }
}
