import AppKit
import CmuxFoundation
import Darwin
import Foundation

/// Ends the git processes this app started that are still running when it
/// quits.
///
/// Every git command the app runs has a deadline: `CommandRunner` ends it
/// (SIGTERM, then SIGKILL) even when nobody waits for its answer any more.
/// Those timers live in this process, though, so a git command still running
/// when the app quit outlived it, and one stuck in a project folder (behind an
/// unanswered macOS privacy prompt, or reading a named pipe nobody writes) ran
/// on under launchd for hours. On quit, every child of this process named
/// `git` gets SIGTERM with its process group (`Process` starts each child in a
/// group of its own, which git's helpers share), a moment to remove its lock
/// files, then SIGKILL.
///
/// ```swift
/// SupermuxGitChildProcesses.endOnQuit()   // once, at app start
/// ```
public enum SupermuxGitChildProcesses {
    /// How long git gets between SIGTERM and SIGKILL (`CommandRunner`'s own grace).
    static let grace: TimeInterval = 0.2

    /// Ends every git child when the app is about to terminate. Call once.
    @MainActor
    public static func endOnQuit() {
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            endAll()
        }
    }

    /// Sends every git child still running SIGTERM, then SIGKILL to those left
    /// after ``grace``. Returns at once when there is none.
    public static func endAll() {
        let running = gitChildren()
        guard !running.isEmpty else { return }
        send(SIGTERM, to: running)
        Thread.sleep(forTimeInterval: grace)
        send(SIGKILL, to: gitChildren())
    }

    /// This process's children named `git`: launched by name, by path, through
    /// `/usr/bin/env` or the `/usr/bin/git` shim, each ends up executing git itself.
    private static func gitChildren() -> [proc_bsdinfo] {
        let parent = UInt32(getpid())
        return DarwinProcessEnumerator().capture().processes.filter { info in
            info.pbi_ppid == parent && commandName(info) == "git"
        }
    }

    /// Signals each child, its whole process group when it leads one.
    private static func send(_ signal: Int32, to children: [proc_bsdinfo]) {
        for child in children {
            let pid = pid_t(bitPattern: child.pbi_pid)
            if child.pbi_pgid == child.pbi_pid {
                _ = killpg(pid, signal)
            } else {
                _ = kill(pid, signal)
            }
        }
    }

    private static func commandName(_ info: proc_bsdinfo) -> String {
        withUnsafeBytes(of: info.pbi_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
