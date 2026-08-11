import Foundation
import Testing

@testable import SupermuxMobileCore

/// The app ↔ notification-extension icon contract.
///
/// The extension re-declares its own reader (an app extension links its own copy
/// of every dependency, and the mobile package graph is too heavy for a process
/// with an execution budget), so the two sides agree only by convention. These
/// tests pin that convention: if the group identifier, the directory, or the
/// filename shape changes here without the extension changing to match, the push
/// banner silently falls back to a generated avatar with no error anywhere.
@Suite("Shared project icon store")
struct SupermuxSharedProjectIconStoreTests {
    /// A store rooted at a temp directory, standing in for the app group
    /// container so the contract is testable without the entitlement.
    private final class StubFileManager: FileManager {
        let root: URL

        init(root: URL) {
            self.root = root
            super.init()
        }

        override func containerURL(
            forSecurityApplicationGroupIdentifier groupIdentifier: String
        ) -> URL? {
            groupIdentifier == SupermuxSharedProjectIconStore.appGroupIdentifier ? root : nil
        }
    }

    /// A build signed without the app-group entitlement, as iOS reports it.
    private final class UnentitledFileManager: FileManager {
        override func containerURL(
            forSecurityApplicationGroupIdentifier groupIdentifier: String
        ) -> URL? {
            nil
        }
    }

    private static let projectID = "D86E0FC3-84E0-44FB-80EB-8169D1CC5060"

    private func withTemporaryContainer(
        _ body: (StubFileManager) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "supermux-icon-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(StubFileManager(root: root))
    }

    // MARK: - The cross-process contract

    @Test func groupIdentifierAndPathShapeAreTheDocumentedContract() {
        // Hardcoded on BOTH sides. Changing either without changing
        // ios/SupermuxNotificationService/NotificationService.swift breaks the
        // push avatar silently.
        #expect(SupermuxSharedProjectIconStore.appGroupIdentifier == "group.com.supermux.ios")
        #expect(
            SupermuxSharedProjectIconStore.relativePath(forProjectID: Self.projectID)
                == "project-icons/\(Self.projectID).png"
        )
    }

    @Test func pathSanitizationCannotEscapeTheDirectory() {
        // A UUID is already path-safe; a malformed id must still not traverse.
        #expect(
            SupermuxSharedProjectIconStore.relativePath(forProjectID: "../../etc/passwd")
                == "project-icons/etcpasswd.png"
        )
        #expect(SupermuxSharedProjectIconStore.relativePath(forProjectID: "///") == nil)
        #expect(SupermuxSharedProjectIconStore.relativePath(forProjectID: "") == nil)
    }

    // MARK: - Round trip

    @Test func storedIconIsReadableBack() throws {
        try withTemporaryContainer { files in
            let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            #expect(
                SupermuxSharedProjectIconStore.store(
                    bytes, forProjectID: Self.projectID, fileManager: files
                )
            )
            #expect(
                SupermuxSharedProjectIconStore.iconData(
                    forProjectID: Self.projectID, fileManager: files
                ) == bytes
            )
        }
    }

    @Test func storingReplacesPreviousBytes() throws {
        try withTemporaryContainer { files in
            SupermuxSharedProjectIconStore.store(
                Data([0x01]), forProjectID: Self.projectID, fileManager: files
            )
            SupermuxSharedProjectIconStore.store(
                Data([0x02, 0x03]), forProjectID: Self.projectID, fileManager: files
            )
            #expect(
                SupermuxSharedProjectIconStore.iconData(
                    forProjectID: Self.projectID, fileManager: files
                ) == Data([0x02, 0x03])
            )
        }
    }

    @Test func emptyBytesAreRejected() throws {
        try withTemporaryContainer { files in
            // An empty write would replace a good icon with a file that decodes
            // to nothing — worse than declining the write.
            #expect(
                !SupermuxSharedProjectIconStore.store(
                    Data(), forProjectID: Self.projectID, fileManager: files
                )
            )
        }
    }

    @Test func missingIconReadsAsNil() throws {
        try withTemporaryContainer { files in
            #expect(
                SupermuxSharedProjectIconStore.iconData(
                    forProjectID: Self.projectID, fileManager: files
                ) == nil
            )
        }
    }

    // MARK: - Graceful degradation

    @Test func absentAppGroupDegradesInsteadOfFailing() {
        // The personal-team dogfood lane signs without the app group. Every
        // operation must no-op, so the banner falls back to the generated
        // avatar exactly as it did before this store existed.
        //
        // Modeled with a stub rather than a bare FileManager: on iOS an
        // unentitled containerURL returns nil, but on macOS — where these tests
        // run — it returns a path regardless, so a real FileManager would
        // silently assert the opposite of the behavior under test.
        let noContainer = UnentitledFileManager()
        #expect(SupermuxSharedProjectIconStore.containerURL(fileManager: noContainer) == nil)
        #expect(
            SupermuxSharedProjectIconStore.iconURL(
                forProjectID: Self.projectID, fileManager: noContainer
            ) == nil
        )
        #expect(
            !SupermuxSharedProjectIconStore.store(
                Data([0x01]), forProjectID: Self.projectID, fileManager: noContainer
            )
        )
        #expect(
            SupermuxSharedProjectIconStore.iconData(
                forProjectID: Self.projectID, fileManager: noContainer
            ) == nil
        )
    }

    // MARK: - Eviction

    @Test func removingAnIconDeletesIt() throws {
        try withTemporaryContainer { files in
            SupermuxSharedProjectIconStore.store(
                Data([0x01]), forProjectID: Self.projectID, fileManager: files
            )
            SupermuxSharedProjectIconStore.removeIcon(
                forProjectID: Self.projectID, fileManager: files
            )
            #expect(
                SupermuxSharedProjectIconStore.iconData(
                    forProjectID: Self.projectID, fileManager: files
                ) == nil
            )
        }
    }

    @Test func pruneDropsDeadProjectsAndKeepsLiveOnes() throws {
        try withTemporaryContainer { files in
            let live = Self.projectID
            let dead = "11111111-2222-3333-4444-555555555555"
            SupermuxSharedProjectIconStore.store(Data([0x01]), forProjectID: live, fileManager: files)
            SupermuxSharedProjectIconStore.store(Data([0x02]), forProjectID: dead, fileManager: files)

            SupermuxSharedProjectIconStore.pruneIcons(keeping: [live], fileManager: files)

            // A live project's icon must survive: the banner cannot re-fetch it.
            #expect(
                SupermuxSharedProjectIconStore.iconData(forProjectID: live, fileManager: files)
                    == Data([0x01])
            )
            #expect(
                SupermuxSharedProjectIconStore.iconData(forProjectID: dead, fileManager: files) == nil
            )
        }
    }

    @Test func pruneWithNoLiveProjectsClearsEverything() throws {
        try withTemporaryContainer { files in
            SupermuxSharedProjectIconStore.store(
                Data([0x01]), forProjectID: Self.projectID, fileManager: files
            )
            SupermuxSharedProjectIconStore.pruneIcons(keeping: [], fileManager: files)
            #expect(
                SupermuxSharedProjectIconStore.iconData(
                    forProjectID: Self.projectID, fileManager: files
                ) == nil
            )
        }
    }
}
