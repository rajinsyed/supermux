// SUPERMUX:begin runtime-ssh-tmux-stopped-progress-regression
#if RUNTIME_SSH_TMUX_HARNESS
import Darwin
import Foundation
import Testing

struct RuntimeSshTmuxProgressTests {
    @Test func delayedReplyCannotPrintAfterFinalResult() async throws {
        let fixture = try RuntimeSshTmuxProgressSocket()
        defer { fixture.cleanup() }
        let outputURL = URL(fileURLWithPath: fixture.path + ".stdout")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let saved = dup(STDOUT_FILENO)
        fflush(nil)
        #expect(dup2(output.fileDescriptor, STDOUT_FILENO) >= 0)
        defer {
            fflush(nil)
            _ = dup2(saved, STDOUT_FILENO)
            Darwin.close(saved)
            try? output.close()
        }
        fixture.start()
        let reporter = RemoteTmuxAttachProgressReporter(socketPath: fixture.path, params: ["destination": "fixture"])
        reporter.start()
        await fixture.requestReceived.wait()
        // The reply stays blocked until stop and the final result are complete.
        reporter.stop()
        print("OK final result")
        fflush(nil)
        fixture.releaseReply.signal()
        await fixture.completed.wait()
        let (method, failure) = fixture.result()
        #expect(method == "remote.tmux.attach_progress")
        #expect(failure == nil)
        let text = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(text == "OK final result\n")
    }
}
#endif
// SUPERMUX:end runtime-ssh-tmux-stopped-progress-regression
