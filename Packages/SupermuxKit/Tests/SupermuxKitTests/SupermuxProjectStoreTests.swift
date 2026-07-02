import Foundation
import Testing
@testable import SupermuxKit

/// Disk-level tests for `SupermuxProjectStore`: missing files, round-trips,
/// shared-file updates, corrupt-file quarantine, and directory creation.
///
/// Every test works in its own unique temporary directory and removes it
/// when done, so tests are order-independent and leave no residue.
struct SupermuxProjectStoreTests {
    // MARK: - Helpers

    /// A fresh, unique temp-directory URL. The directory is NOT created;
    /// tests that need it on disk create it explicitly.
    private func freshTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    /// Whether two dates agree within `tolerance` seconds.
    ///
    /// The store encodes dates as ISO8601, which truncates subseconds, so
    /// exact equality cannot be expected after a round-trip.
    private func isClose(_ lhs: Date, _ rhs: Date, tolerance: TimeInterval = 1) -> Bool {
        abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) <= tolerance
    }

    /// A project with every field populated, for full round-trip checks.
    private func fullyPopulatedProject() -> SupermuxProject {
        SupermuxProject(
            id: UUID(),
            name: "Alpha",
            rootPath: "/tmp/alpha",
            colorHex: "#3b82f6",
            iconSymbol: "folder",
            customIconPath: "/tmp/alpha/brand/icon.png",
            defaultBranch: "main",
            worktreesDirName: ".trees",
            runCommands: ["npm run dev", "npm run worker"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.75),
            lastOpenedAt: Date(timeIntervalSince1970: 1_700_100_000.25)
        )
    }

    // MARK: - Tests

    @Test func loadReturnsEmptyWhenFileIsMissing() async throws {
        let tempDir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("projects.json")

        let store = SupermuxProjectStore(fileURL: fileURL)
        let loaded = await store.load()

        #expect(loaded == .empty)
        #expect(loaded.projects.isEmpty)
        #expect(loaded.version == SupermuxProjectsFile.currentVersion)
        #expect(loaded.isSectionCollapsed == false)
    }

    @Test func saveThenLoadRoundTripsAllProjectFields() async throws {
        let tempDir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("projects.json")

        let projectA = fullyPopulatedProject()
        let projectB = SupermuxProject(name: "Beta", rootPath: "/tmp/beta")
        let file = SupermuxProjectsFile(
            version: SupermuxProjectsFile.currentVersion,
            projects: [projectA, projectB],
            isSectionCollapsed: true
        )

        let writer = SupermuxProjectStore(fileURL: fileURL)
        try await writer.save(file)

        // A fresh store instance forces a real read from disk (no cache).
        let reader = SupermuxProjectStore(fileURL: fileURL)
        let loaded = await reader.load()

        #expect(loaded.version == SupermuxProjectsFile.currentVersion)
        #expect(loaded.isSectionCollapsed == true)
        try #require(loaded.projects.count == 2)

        let loadedA = loaded.projects[0]
        #expect(loadedA.id == projectA.id)
        #expect(loadedA.name == projectA.name)
        #expect(loadedA.rootPath == projectA.rootPath)
        #expect(loadedA.colorHex == projectA.colorHex)
        #expect(loadedA.iconSymbol == projectA.iconSymbol)
        #expect(loadedA.customIconPath == projectA.customIconPath)
        #expect(loadedA.defaultBranch == projectA.defaultBranch)
        #expect(loadedA.worktreesDirName == projectA.worktreesDirName)
        #expect(loadedA.runCommands == projectA.runCommands)
        #expect(isClose(loadedA.createdAt, projectA.createdAt))
        let loadedALastOpened = try #require(loadedA.lastOpenedAt)
        let expectedALastOpened = try #require(projectA.lastOpenedAt)
        #expect(isClose(loadedALastOpened, expectedALastOpened))

        let loadedB = loaded.projects[1]
        #expect(loadedB.id == projectB.id)
        #expect(loadedB.name == projectB.name)
        #expect(loadedB.rootPath == projectB.rootPath)
        #expect(loadedB.colorHex == nil)
        #expect(loadedB.iconSymbol == nil)
        #expect(loadedB.defaultBranch == nil)
        #expect(loadedB.worktreesDirName == ".worktrees")
        #expect(loadedB.runCommands.isEmpty)
        #expect(isClose(loadedB.createdAt, projectB.createdAt))
        #expect(loadedB.lastOpenedAt == nil)
    }

    @Test func updateMutationIsVisibleToASecondStoreInstance() async throws {
        let tempDir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("projects.json")

        let project = fullyPopulatedProject()
        let first = SupermuxProjectStore(fileURL: fileURL)
        try await first.update { file in
            file.projects.append(project)
            file.isSectionCollapsed = true
        }

        let second = SupermuxProjectStore(fileURL: fileURL)
        let loaded = await second.load()

        #expect(loaded.version == SupermuxProjectsFile.currentVersion)
        #expect(loaded.isSectionCollapsed == true)
        try #require(loaded.projects.count == 1)
        #expect(loaded.projects[0].id == project.id)
        #expect(loaded.projects[0].name == project.name)
        #expect(loaded.projects[0].rootPath == project.rootPath)
    }

    @Test func updateRereadsDiskSoConcurrentWritesAreNotClobberedByStaleCache() async throws {
        // The projects file is intentionally shared across stable/nightly/DEV
        // builds, so two `SupermuxProjectStore` instances can point at the same
        // file (simulating two processes). `update` must re-read from disk
        // before mutating; otherwise a store with a stale (empty) cache would
        // overwrite projects written by the other store.
        let tempDir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("projects.json")

        let storeA = SupermuxProjectStore(fileURL: fileURL)
        let storeB = SupermuxProjectStore(fileURL: fileURL)

        // (1) A populates its in-memory cache (empty file on disk -> .empty).
        let initial = await storeA.load()
        #expect(initial.projects.isEmpty)

        // (2) B writes projectX to disk. A's cache is now stale.
        let projectX = SupermuxProject(name: "Gamma", rootPath: "/tmp/gamma")
        try await storeB.update { file in
            file.projects = [projectX]
        }

        // (3) A mutates an orthogonal field. Before the fix this would write
        //     from A's stale (empty) cache and drop projectX.
        try await storeA.update { file in
            file.isSectionCollapsed = true
        }

        // (4) A fresh store reading from disk must see BOTH projectX and the
        //     collapsed flag.
        let storeC = SupermuxProjectStore(fileURL: fileURL)
        let loaded = await storeC.load()

        #expect(loaded.version == SupermuxProjectsFile.currentVersion)
        #expect(loaded.isSectionCollapsed == true)
        try #require(loaded.projects.count == 1)
        #expect(loaded.projects[0].id == projectX.id)
        #expect(loaded.projects[0].name == projectX.name)
        #expect(loaded.projects[0].rootPath == projectX.rootPath)
    }

    @Test func corruptFileLoadsEmptyAndIsQuarantinedToATimestampedBackup() async throws {
        let tempDir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("projects.json")

        let corruptBytes = Data("{ this is not valid json !!".utf8)
        try corruptBytes.write(to: fileURL)

        let store = SupermuxProjectStore(fileURL: fileURL)
        let loaded = await store.load()

        #expect(loaded == .empty)
        let failure = try #require(await store.lastLoadFailure)
        guard case .corrupted(.some(let backupURL)) = failure else {
            Issue.record("expected .corrupted with a backup, got \(failure)")
            return
        }
        #expect(backupURL.lastPathComponent.hasPrefix("projects.json.corrupt-"))
        #expect(try Data(contentsOf: backupURL) == corruptBytes)

        // A later corruption must land in a NEW backup, never overwrite the
        // earlier one — each quarantined document stays recoverable.
        let secondCorruptBytes = Data("also definitely not json".utf8)
        try secondCorruptBytes.write(to: fileURL)
        let secondStore = SupermuxProjectStore(fileURL: fileURL)
        _ = await secondStore.load()
        let secondFailure = try #require(await secondStore.lastLoadFailure)
        guard case .corrupted(.some(let secondBackupURL)) = secondFailure else {
            Issue.record("expected .corrupted with a backup, got \(secondFailure)")
            return
        }
        #expect(secondBackupURL != backupURL)
        #expect(try Data(contentsOf: backupURL) == corruptBytes)
        #expect(try Data(contentsOf: secondBackupURL) == secondCorruptBytes)
    }

    @Test func unreadableFileAbortsUpdateInsteadOfWipingIt() async throws {
        // Root reads through 0o000 permissions, so the failure cannot be staged.
        guard getuid() != 0 else { return }
        let tempDir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("projects.json")

        let project = fullyPopulatedProject()
        let writer = SupermuxProjectStore(fileURL: fileURL)
        try await writer.update { $0.projects.append(project) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }

        // A transient read failure must abort the mutation, not apply it to an
        // empty document and atomically destroy the user's registered projects.
        let store = SupermuxProjectStore(fileURL: fileURL)
        await #expect(throws: (any Error).self) {
            try await store.update { $0.isSectionCollapsed = true }
        }
        let failure = try #require(await store.lastLoadFailure)
        guard case .unreadable = failure else {
            Issue.record("expected .unreadable, got \(failure)")
            return
        }
        // load() falls back to .empty but must not pin it: once the file is
        // readable again the same store recovers the real document.
        #expect(await store.load() == .empty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let recovered = await store.load()
        #expect(recovered.projects.map(\.id) == [project.id])
        #expect(recovered.isSectionCollapsed == false)
    }

    @Test func updatePreservesANewerSchemaVersionInsteadOfDowngrading() async throws {
        let tempDir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("projects.json")
        // Simulates a document written by a newer build with a higher schema.
        let newerDocument = #"{"version": 99, "projects": [], "isSectionCollapsed": false}"#
        try Data(newerDocument.utf8).write(to: fileURL)

        let store = SupermuxProjectStore(fileURL: fileURL)
        let updated = try await store.update { $0.isSectionCollapsed = true }
        #expect(updated.version == 99)

        let reader = SupermuxProjectStore(fileURL: fileURL)
        let loaded = await reader.load()
        #expect(loaded.version == 99)
        #expect(loaded.isSectionCollapsed == true)
    }

    @Test func saveCreatesIntermediateDirectories() async throws {
        let tempDir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir
            .appendingPathComponent("nested")
            .appendingPathComponent("deeper")
            .appendingPathComponent("projects.json")
        #expect(!FileManager.default.fileExists(atPath: tempDir.path))

        let store = SupermuxProjectStore(fileURL: fileURL)
        try await store.save(.empty)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let reader = SupermuxProjectStore(fileURL: fileURL)
        let loaded = await reader.load()
        #expect(loaded == .empty)
    }
}
