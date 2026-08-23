import Foundation
import SupermuxKit

/// The process lifecycle surface the harness controller needs, injectable for orchestration tests.
@MainActor
protocol SupermuxHarnessProcessSessionProtocol: AnyObject {
    var isRunning: Bool { get }
    var activeRunID: String? { get }

    func start(plan: SupermuxHarnessLaunchPlan) throws -> SupermuxHarnessStartedProcess
    func send(_ frame: SupermuxHarnessEncodedFrame) async throws
    func send(_ frame: SupermuxHarnessEncodedFrame, forRunID runID: String) async throws
    func terminate() throws
    func terminateAndWait(timeout: TimeInterval) async throws -> Int32
    func close()
}

extension SupermuxHarnessProcessSession: SupermuxHarnessProcessSessionProtocol {}
