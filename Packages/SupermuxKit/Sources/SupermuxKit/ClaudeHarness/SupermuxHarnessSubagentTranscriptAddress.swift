public import Foundation

/// A validated logical address for one Claude subagent transcript.
public enum SupermuxHarnessSubagentTranscriptAddress: Hashable, Sendable {
    /// A local agent stored directly under a session's `subagents` directory.
    case localAgent(
        workingDirectoryURL: URL,
        sessionID: String,
        taskID: String
    )
    /// An agent stored under one dynamic workflow run.
    case workflowAgent(
        workingDirectoryURL: URL,
        sessionID: String,
        workflowRunID: String,
        agentID: String
    )

    var workingDirectoryURL: URL {
        switch self {
        case .localAgent(let workingDirectoryURL, _, _),
             .workflowAgent(let workingDirectoryURL, _, _, _):
            return workingDirectoryURL
        }
    }

    var sessionID: String {
        switch self {
        case .localAgent(_, let sessionID, _),
             .workflowAgent(_, let sessionID, _, _):
            return sessionID
        }
    }

    var identifiers: [String] {
        switch self {
        case .localAgent(_, let sessionID, let taskID):
            return [sessionID, taskID]
        case .workflowAgent(_, let sessionID, let workflowRunID, let agentID):
            return [sessionID, workflowRunID, agentID]
        }
    }
}
