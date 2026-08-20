import Darwin
import Foundation
import Testing

@testable import SupermuxKit

struct SupermuxHarnessSessionRepositorySandbox {
    let rootURL: URL
    let projectsRootURL: URL
    let workingDirectoryURL: URL
    let repository: SupermuxHarnessSessionRepository
    let configuration: SupermuxHarnessSessionRepositoryConfiguration

    init(
        name: String,
        configuration: SupermuxHarnessSessionRepositoryConfiguration = .production,
        scanObserver: (@Sendable (URL) async -> Void)? = nil
    ) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "supermux-harness-repository-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        let projectsRootURL = rootURL.appendingPathComponent("projects", isDirectory: true)
        let workingDirectoryURL = rootURL.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectsRootURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: workingDirectoryURL,
            withIntermediateDirectories: true
        )
        self.rootURL = rootURL
        self.projectsRootURL = projectsRootURL
        self.workingDirectoryURL = workingDirectoryURL
        self.configuration = configuration
        repository = SupermuxHarnessSessionRepository(
            projectsRootURL: projectsRootURL,
            fileManager: .default,
            configuration: configuration,
            scanObserver: scanObserver
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func discovery() -> SupermuxHarnessSessionDiscovery {
        SupermuxHarnessSessionDiscovery(
            projectsRootURL: projectsRootURL,
            fileManager: .default
        )
    }

    func firstProjectDirectory() throws -> URL {
        let directory = try #require(
            discovery().projectDirectoryURLs(for: workingDirectoryURL).first
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @discardableResult
    func writeSession(
        id: String,
        records: [[String: Any]],
        terminated: Bool = true,
        modificationDate: Date? = nil,
        directory: URL? = nil
    ) throws -> URL {
        let directory = try directory ?? firstProjectDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent(id).appendingPathExtension("jsonl")
        try Self.jsonlData(records: records, terminated: terminated).write(to: fileURL)
        if let modificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: fileURL.path
            )
        }
        return fileURL
    }

    func append(_ data: Data, to fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func rewriteInPlace(
        _ data: Data,
        at fileURL: URL,
        modificationDate: Date? = nil
    ) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        if let modificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: fileURL.path
            )
        }
    }

    func replace(_ data: Data, at fileURL: URL) throws {
        let replacement = fileURL.deletingLastPathComponent()
            .appendingPathComponent("replacement-\(UUID().uuidString).jsonl")
        try data.write(to: replacement)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: replacement, to: fileURL)
    }

    func inode(of fileURL: URL) throws -> UInt64 {
        var status = stat()
        guard Darwin.lstat(fileURL.path, &status) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return UInt64(status.st_ino)
    }

    static func jsonLine(
        _ record: [String: Any],
        terminated: Bool = true
    ) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        )
        if terminated {
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    static func jsonlData(
        records: [[String: Any]],
        terminated: Bool = true
    ) throws -> Data {
        var data = Data()
        for (index, record) in records.enumerated() {
            data.append(try jsonLine(
                record,
                terminated: index < records.count - 1 || terminated
            ))
        }
        return data
    }

    static func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }
}

actor SupermuxHarnessSessionRepositoryScanGate {
    private var arrivals = 0
    private var maximumWaitingScans = 0
    private var waitingScans = 0
    private var arrivalWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func arriveAndWait() async {
        arrivals += 1
        waitingScans += 1
        maximumWaitingScans = max(maximumWaitingScans, waitingScans)
        let ready = arrivalWaiters.filter { arrivals >= $0.count }
        arrivalWaiters.removeAll { arrivals >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        waitingScans -= 1
    }

    func waitForArrivals(_ count: Int) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append((count, continuation))
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func arrivalCount() -> Int { arrivals }

    func maximumConcurrentWaitingScans() -> Int { maximumWaitingScans }
}
