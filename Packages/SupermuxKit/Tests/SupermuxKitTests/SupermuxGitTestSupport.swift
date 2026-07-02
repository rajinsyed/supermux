import Foundation

/// A git invocation made by ``GitFixture`` failed.
enum GitFixtureError: Error {
    case gitFailed(arguments: [String], message: String)
}

/// The single shared git fixture helper for this test target: throwaway
/// repositories, fixture file I/O, and a synchronous `git` runner. Each suite
/// passes its own temp-directory `prefix` so parallel runs stay
/// distinguishable.
enum GitFixture {
    /// Creates a unique temporary directory named `<prefix>-<UUID>` and returns
    /// its path, standardized the same way the services normalize paths.
    static func makeTempDirectory(prefix: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url.path as NSString).standardizingPath
    }

    /// Creates a temp git repository on `main` with one committed `README.md`
    /// and commit signing disabled locally.
    static func makeFixtureRepo(prefix: String) throws -> String {
        let root = try makeTempDirectory(prefix: prefix)
        try runGit(["init", "-b", "main"], in: root)
        try configureIdentity(in: root)
        try write("fixture\n", to: "README.md", in: root)
        try runGit(["add", "."], in: root)
        try commit("Initial commit", in: root)
        return root
    }

    /// Sets a local test identity and disables `commit.gpgsign` in `root`.
    static func configureIdentity(in root: String) throws {
        try runGit(["config", "--local", "user.email", "tests@supermux.invalid"], in: root)
        try runGit(["config", "--local", "user.name", "Supermux Tests"], in: root)
        try runGit(["config", "--local", "commit.gpgsign", "false"], in: root)
    }

    /// Commits staged changes with `message`, forcing signing off so commits
    /// work on machines with global `commit.gpgsign` enabled.
    @discardableResult
    static func commit(_ message: String, in root: String) throws -> String {
        try runGit(["-c", "commit.gpgsign=false", "commit", "-m", message], in: root)
    }

    /// Writes `content` to `relativePath` inside `root`.
    static func write(_ content: String, to relativePath: String, in root: String) throws {
        let path = (root as NSString).appendingPathComponent(relativePath)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Reads the contents of `relativePath` inside `root`.
    static func read(_ relativePath: String, in root: String) throws -> String {
        let path = (root as NSString).appendingPathComponent(relativePath)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Runs git synchronously via `Process` and returns its standard output;
    /// throws ``GitFixtureError`` on a non-zero exit.
    @discardableResult
    static func runGit(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitFixtureError.gitFailed(
                arguments: arguments,
                message: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    /// Best-effort removal of a fixture directory.
    static func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
