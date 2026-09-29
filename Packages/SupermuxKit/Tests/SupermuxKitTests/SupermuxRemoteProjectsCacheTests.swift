import Foundation
import SupermuxMobileCore
import Testing

@testable import SupermuxKit

/// Ways the offline cache of other Macs' projects could fail (written first):
/// 1. Saving one Mac's projects drops another Mac's cached entry.
/// 2. A corrupt or missing file breaks loading instead of reading as empty.
/// 3. The cache is written to (or replaces) the local projects document.
/// 4. Forgetting a Mac leaves its entry behind.
/// 5. A project-sync suppression is lost, or matches a different spelling of the root.
/// 6. Saves running at the same time (several Macs refreshed together, or two
///    builds sharing the file) drop each other's entries.
struct SupermuxRemoteProjectsCacheTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-remote-cache-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("supermux-remote-projects.json")
    }

    private func entry(_ name: String, projects: [String]) -> SupermuxRemoteProjectsCache.Entry {
        SupermuxRemoteProjectsCache.Entry(
            name: name,
            projects: projects.map { SupermuxProjectDTO(id: UUID().uuidString, name: $0, rootPath: "/r/\($0)") },
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // 1
    @Test func savingOneMacKeepsTheOthers() throws {
        let cache = SupermuxRemoteProjectsCache(fileURL: tempURL())
        try cache.save(entry("Studio", projects: ["app"]), forMachine: "device:a@default")
        try cache.save(entry("Laptop", projects: ["web"]), forMachine: "device:b@default")
        try cache.save(entry("Studio", projects: ["app", "api"]), forMachine: "device:a@default")
        let loaded = cache.load()
        #expect(loaded["device:a@default"]?.projects.map(\.name) == ["app", "api"])
        #expect(loaded["device:b@default"]?.name == "Laptop")
    }

    // 2
    @Test func missingOrCorruptFilesReadAsEmpty() throws {
        let url = tempURL()
        let cache = SupermuxRemoteProjectsCache(fileURL: url)
        #expect(cache.load().isEmpty)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        #expect(cache.load().isEmpty)
        try cache.save(entry("Studio", projects: ["app"]), forMachine: "device:a@default")
        #expect(cache.load().count == 1)
    }

    // 3
    @Test func theDefaultLocationIsNotTheProjectsDocument() {
        let url = SupermuxPaths.remoteProjectsCacheFileURL
        #expect(url.lastPathComponent == "supermux-remote-projects.json")
        #expect(url != SupermuxPaths.defaultProjectsFileURL)
    }

    // 4
    @Test func forgettingAMacRemovesOnlyItsEntry() throws {
        let cache = SupermuxRemoteProjectsCache(fileURL: tempURL())
        try cache.save(entry("Studio", projects: ["app"]), forMachine: "device:a@default")
        try cache.save(entry("Laptop", projects: ["web"]), forMachine: "device:b@default")
        try cache.forget(machine: "device:a@default")
        #expect(Array(cache.load().keys) == ["device:b@default"])
    }

    // 5
    @Test func suppressionsPersistAndMatchStandardizedRoots() throws {
        let suite = "supermux.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SupermuxProjectSyncSuppression(defaults: defaults)
        #expect(!store.isSuppressed(rootPath: "/r/app"))
        store.suppress(rootPath: "/r/app/")
        #expect(store.isSuppressed(rootPath: "/r/app"))
        #expect(SupermuxProjectSyncSuppression(defaults: defaults).isSuppressed(rootPath: "/r/./app"))
        store.clear(rootPath: "/r/app")
        #expect(!store.isSuppressed(rootPath: "/r/app"))
    }

    // 6
    @Test func concurrentSavesForDifferentMacsKeepEveryEntry() async throws {
        let url = tempURL()
        // Two instances over one file stand in for two builds sharing it.
        let builds = [SupermuxRemoteProjectsCache(fileURL: url), SupermuxRemoteProjectsCache(fileURL: url)]
        let machines = (0..<32).map { "device:\($0)@default" }
        let entries = machines.map { entry($0, projects: ["app"]) }
        await withTaskGroup(of: Void.self) { group in
            for (index, machine) in machines.enumerated() {
                let cache = builds[index % builds.count]
                let entry = entries[index]
                group.addTask { try? await cache.save(entry, forMachine: machine) }
            }
        }
        #expect(Set(builds[0].load().keys) == Set(machines))
    }
}
