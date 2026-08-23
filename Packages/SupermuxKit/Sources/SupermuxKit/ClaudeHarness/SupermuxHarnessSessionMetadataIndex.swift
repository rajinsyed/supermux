/// Listing metadata contributed by valid persisted records.
struct SupermuxHarnessSessionMetadataIndex: Sendable {
    var customTitle: String?
    var aiTitle: String?
    var summary: String?
    var firstPrompt: String?
    var gitBranch: String?
    var messageCount = 0
    var foundRecordedDirectory = false
    var recordedCanonicalPaths: Set<String> = []

    var title: String? {
        customTitle ?? aiTitle ?? summary ?? firstPrompt
    }

    var byteCost: Int {
        96 + [customTitle, aiTitle, summary, firstPrompt, gitBranch]
            .compactMap { $0?.utf8.count }
            .reduce(0, +) + recordedCanonicalPaths.reduce(0) { $0 + $1.utf8.count + 24 }
    }

    mutating func merge(_ newer: Self) {
        if let value = newer.customTitle { customTitle = value }
        if let value = newer.aiTitle { aiTitle = value }
        if let value = newer.summary { summary = value }
        if firstPrompt == nil { firstPrompt = newer.firstPrompt }
        if let value = newer.gitBranch { gitBranch = value }
        messageCount += newer.messageCount
        foundRecordedDirectory = foundRecordedDirectory || newer.foundRecordedDirectory
        recordedCanonicalPaths.formUnion(newer.recordedCanonicalPaths)
    }

    mutating func apply(_ record: SupermuxHarnessSessionIndexedRecord) {
        merge(record.metadata)
    }
}
