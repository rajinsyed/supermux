import Foundation
import SupermuxClaudeHarness

/// User-facing text for harness failures and diagnostics.
///
/// Split out of ``SupermuxHarnessViewModel`` so the mapping is one screenful of
/// pure, localizable string decisions instead of the tail of a 570-line model.
/// Everything here is `nonisolated` and side-effect free.
extension SupermuxHarnessViewModel {

    static func describe(launcherError error: any Error) -> String {
        guard let resolution = error as? ClaudeLauncherResolver.ResolutionError else {
            return "\(error)"
        }
        switch resolution {
        case .notFound(let name):
            return String(
                format: String(
                    localized: "supermux.harness.error.launcherNotFound",
                    defaultValue: "Could not find “%@” on your PATH."
                ),
                name
            )
        case .notExecutable(let path):
            return String(
                format: String(
                    localized: "supermux.harness.error.launcherNotExecutable",
                    defaultValue: "“%@” is not an executable file."
                ),
                path
            )
        case .cmuxWrapperRejected(let path):
            return String(
                format: String(
                    localized: "supermux.harness.error.launcherWrapperRejected",
                    defaultValue: "“%@” is the cmux claude wrapper. Pick the real Claude Code binary."
                ),
                path
            )
        }
    }

    static func notice(for diagnostic: ClaudeHarnessDiagnostic) -> SupermuxHarnessNotice? {
        switch diagnostic {
        case .launcherNotice(let text):
            return SupermuxHarnessNotice(
                severity: .info,
                title: String(
                    localized: "supermux.harness.notice.launcherOutput",
                    defaultValue: "Launcher message"
                ),
                detail: text
            )
        case .malformedLine(let text):
            return SupermuxHarnessNotice(
                severity: .warning,
                title: String(
                    localized: "supermux.harness.notice.malformedLine",
                    defaultValue: "Claude sent a line this app could not read."
                ),
                detail: text
            )
        case .oversizedLine(let byteCount):
            return SupermuxHarnessNotice(
                severity: .warning,
                title: String(
                    format: String(
                        localized: "supermux.harness.notice.oversizedLine",
                        defaultValue: "Skipped an oversized message (%lld bytes)."
                    ),
                    Int64(byteCount)
                )
            )
        case .resumeSessionMismatch(let expected, let observed):
            return SupermuxHarnessNotice(
                severity: .error,
                title: String(
                    localized: "supermux.harness.notice.resumeMismatch",
                    defaultValue: "This session could not be resumed."
                ),
                detail: String(
                    format: String(
                        localized: "supermux.harness.notice.resumeMismatch.detail",
                        defaultValue: "Expected session %1$@, but the process reported %2$@."
                    ),
                    expected,
                    observed
                )
            )
        case .unknownLine, .inboundControlRequestIgnored, .unmatchedControlResponse,
             .toolInputUndecodable, .toolInputMismatch, .initializeFallback:
            // Protocol curiosities with no user-actionable content; they stay
            // in the session's diagnostic stream without cluttering the
            // transcript.
            return nil
        }
    }

    static func notice(exit: ClaudeProcessExit, stderrTail: String?) -> SupermuxHarnessNotice {
        if exit.wasClean {
            return SupermuxHarnessNotice(
                severity: .info,
                title: String(
                    localized: "supermux.harness.notice.sessionEnded",
                    defaultValue: "Session ended."
                )
            )
        }
        return SupermuxHarnessNotice(
            severity: .error,
            title: String(
                format: String(
                    localized: "supermux.harness.notice.sessionFailed",
                    defaultValue: "Claude Code exited with status %lld."
                ),
                Int64(exit.status ?? -1)
            ),
            detail: stderrTail
        )
    }
}
