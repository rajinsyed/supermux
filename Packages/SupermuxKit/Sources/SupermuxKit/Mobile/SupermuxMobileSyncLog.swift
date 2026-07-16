public import CmuxFoundation
import Foundation

/// The bounded, wire-ready log of one sync git invocation
/// (push/pull/stash/stash_pop) for the mobile `changes.*` RPCs.
public struct SupermuxMobileSyncLogCapture: Equatable, Sendable {
    /// The captured log lines, in stdout-then-stderr order.
    public let lines: [String]
    /// Whether any line or the line count was capped. The phone renders its
    /// own truncation hint — no marker text travels on the wire, so nothing
    /// here needs localization.
    public let truncated: Bool

    /// Creates a capture.
    /// - Parameters:
    ///   - lines: The captured log lines.
    ///   - truncated: Whether output was dropped by the caps.
    public init(lines: [String], truncated: Bool) {
        self.lines = lines
        self.truncated = truncated
    }
}

/// Converts a sync git invocation's raw output into the `log_lines` the
/// mobile `changes.push` / `changes.pull` / `changes.stash` /
/// `changes.stash_pop` results carry.
///
/// git writes transfer progress to stderr and merge/stash summaries to
/// stdout, so both streams are folded in (stdout first). Progress lines are
/// carriage-return separated, so splitting honors `\r` as well as `\n`;
/// blank lines are dropped. Caps (``maxLines`` / ``maxLineCharacters``) keep
/// a pathological transfer log from ballooning one RPC reply frame.
public enum SupermuxMobileSyncLog {
    /// Upper bound on the number of log lines one result carries.
    public static let maxLines = 100
    /// Upper bound on one line's character count.
    public static let maxLineCharacters = 500

    /// Captures a command result's output as bounded log lines.
    /// - Parameter result: The completed git invocation.
    public static func capture(_ result: CommandResult) -> SupermuxMobileSyncLogCapture {
        capture(stdout: result.stdout, stderr: result.stderr)
    }

    /// Captures raw stdout/stderr as bounded log lines.
    /// - Parameters:
    ///   - stdout: The invocation's standard output, if any.
    ///   - stderr: The invocation's standard error, if any.
    public static func capture(stdout: String?, stderr: String?) -> SupermuxMobileSyncLogCapture {
        var lines: [String] = []
        var truncated = false
        for stream in [stdout, stderr] {
            guard let stream else { continue }
            for raw in stream.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                guard lines.count < maxLines else {
                    truncated = true
                    return SupermuxMobileSyncLogCapture(lines: lines, truncated: truncated)
                }
                if line.count > maxLineCharacters {
                    truncated = true
                    lines.append(String(line.prefix(maxLineCharacters)))
                } else {
                    lines.append(line)
                }
            }
        }
        return SupermuxMobileSyncLogCapture(lines: lines, truncated: truncated)
    }
}
