import Foundation
import SupermuxMobileCore

/// The host side of `mobile.supermux.files.search`: ripgrep over one confined
/// folder with the Files panel's own arguments. The caller supplies only the
/// query, which always follows `--` as a fixed-string pattern; no shell runs,
/// no caller-chosen flag reaches rg, and `--no-config` keeps an rg config file
/// from adding any (a preprocessor would run a command). Output is bounded by
/// result count, bytes and time, so the reply always lands inside its deadline.
enum SupermuxHostFileSearch {
    /// The most matches one search returns (the local Find tool's cap).
    static let maxResults = 500
    /// The most rg output read before stopping.
    static let maxOutputBytes = 1_048_576
    /// How long rg may run.
    static let timeLimit: TimeInterval = 10

    /// Why a search could not run.
    enum Failure: Error {
        /// No rg on this Mac (wire code `rg_missing`).
        case ripgrepMissing
        /// rg failed before finding anything.
        case failed(String)
    }

    /// The globs the local Find tool excludes.
    private static let excludedGlobs = [
        "!.git/**", "!**/.git/**", "!node_modules/**", "!**/node_modules/**", "!dist/**", "!**/dist/**",
        "!build/**", "!**/build/**", "!DerivedData/**", "!**/DerivedData/**",
    ]

    /// rg's arguments for `query` under `root` (the query is never a flag).
    static func arguments(query: String, root: String) -> [String] {
        [
            "--no-config", "--json", "--line-number", "--column", "--smart-case", "--fixed-strings",
            "--max-columns", "300", "--max-columns-preview", "--color", "never", "--hidden",
        ] + excludedGlobs.flatMap { ["--glob", $0] } + ["--", query, root]
    }

    /// Runs one bounded search. Blocks the calling thread for at most
    /// ``timeLimit``; call it off the main actor.
    static func search(query: String, root: String) throws -> SupermuxFileSearchDTO {
        guard case .found(let executable) = RipgrepExecutableResolver.resolution() else {
            throw Failure.ripgrepMissing
        }
        let process = Process()
        process.executableURL = executable.url
        process.arguments = executable.prefixArguments + arguments(query: query, root: root)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeLimit, execute: watchdog)
        defer { watchdog.cancel() }

        var results: [SupermuxFileSearchMatchDTO] = []
        var limited = false
        var pending = Data()
        var total = 0
        let reader = stdout.fileHandleForReading
        reading: while let chunk = try? reader.read(upToCount: 65_536), !chunk.isEmpty {
            total += chunk.count
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard let match = match(line, root: root) else { continue }
                results.append(match)
                if results.count >= maxResults {
                    limited = true
                    break reading
                }
            }
            if total > maxOutputBytes {
                limited = true
                break
            }
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let timedOut = !limited && process.terminationReason == .uncaughtSignal
        if !timedOut, !limited, process.terminationStatus > 1, results.isEmpty {
            throw Failure.failed("rg exited with status \(process.terminationStatus)")
        }
        let status = limited || (timedOut && !results.isEmpty) ? "limited" : (results.isEmpty ? "no_matches" : "matches")
        return SupermuxFileSearchDTO(
            status: status,
            limit: status == "limited" ? results.count : nil,
            timedOut: timedOut ? true : nil,
            results: results
        )
    }

    /// One rg `match` line as a root-relative match (nothing outside the root).
    private static func match(_ line: Data, root: String) -> SupermuxFileSearchMatchDTO? {
        guard let result = FileSearchRipgrepParser.parseMatchLine(String(decoding: line, as: UTF8.self), rootPath: root),
              !result.relativePath.hasPrefix("/"), result.relativePath != "." else { return nil }
        return SupermuxFileSearchMatchDTO(
            path: result.relativePath,
            line: result.lineNumber,
            column: result.columnNumber,
            preview: result.preview
        )
    }
}
