import Foundation

/// Human-friendly labels for Claude Code tool names (remodex-style).
///
/// Pure data table — localization happens at the UI layer, not here. Covers
/// every tool observed in captured `system.init.tools` lists plus classic
/// tools that appear in other configurations; unknown tools (including
/// `mcp__server__tool`) fall back to a derived readable name.
///
/// lint:allow namespace-type — constant label table (data, not behavior);
/// nothing to instantiate or inject. (lint:allow)
public enum ClaudeToolHumanizer {
    /// Present- and past-tense labels for one tool.
    public struct Labels: Sendable, Equatable {
        /// While the tool runs, e.g. "Reading file".
        public let running: String
        /// After the tool completes, e.g. "Read file".
        public let done: String

        public init(running: String, done: String) {
            self.running = running
            self.done = done
        }
    }

    /// The known-tool table.
    public static let table: [String: Labels] = [
        "Read": Labels(running: "Reading file", done: "Read file"),
        "Write": Labels(running: "Writing file", done: "Wrote file"),
        "Edit": Labels(running: "Editing file", done: "Edited file"),
        "MultiEdit": Labels(running: "Editing file", done: "Edited file"),
        "NotebookEdit": Labels(running: "Editing notebook", done: "Edited notebook"),
        "NotebookRead": Labels(running: "Reading notebook", done: "Read notebook"),
        "Bash": Labels(running: "Running command", done: "Ran command"),
        "BashOutput": Labels(running: "Reading command output", done: "Read command output"),
        "KillShell": Labels(running: "Stopping command", done: "Stopped command"),
        "Grep": Labels(running: "Searching code", done: "Searched code"),
        "Glob": Labels(running: "Finding files", done: "Found files"),
        "LSP": Labels(running: "Inspecting code", done: "Inspected code"),
        "WebSearch": Labels(running: "Searching the web", done: "Searched the web"),
        "WebFetch": Labels(running: "Fetching page", done: "Fetched page"),
        "Task": Labels(running: "Running agent", done: "Ran agent"),
        "TaskCreate": Labels(running: "Creating task", done: "Created task"),
        "TaskGet": Labels(running: "Reading task", done: "Read task"),
        "TaskList": Labels(running: "Listing tasks", done: "Listed tasks"),
        "TaskOutput": Labels(running: "Reading task output", done: "Read task output"),
        "TaskStop": Labels(running: "Stopping task", done: "Stopped task"),
        "TaskUpdate": Labels(running: "Updating task", done: "Updated task"),
        "TodoWrite": Labels(running: "Updating to-dos", done: "Updated to-dos"),
        "AskUserQuestion": Labels(running: "Asking a question", done: "Asked a question"),
        "EnterPlanMode": Labels(running: "Starting plan", done: "Started plan"),
        "ExitPlanMode": Labels(running: "Finishing plan", done: "Finished plan"),
        "EnterWorktree": Labels(running: "Entering worktree", done: "Entered worktree"),
        "ExitWorktree": Labels(running: "Leaving worktree", done: "Left worktree"),
        "ListAgents": Labels(running: "Listing agents", done: "Listed agents"),
        "SendMessage": Labels(running: "Sending message", done: "Sent message"),
        "Skill": Labels(running: "Using skill", done: "Used skill"),
        "ToolSearch": Labels(running: "Finding tools", done: "Found tools"),
        "Monitor": Labels(running: "Monitoring", done: "Monitored"),
        "Workflow": Labels(running: "Running workflow", done: "Ran workflow"),
        "ReportFindings": Labels(running: "Reporting findings", done: "Reported findings"),
        "PushNotification": Labels(running: "Sending notification", done: "Sent notification"),
        "ScheduleWakeup": Labels(running: "Scheduling wakeup", done: "Scheduled wakeup"),
        "DesignSync": Labels(running: "Syncing design", done: "Synced design"),
        "CronCreate": Labels(running: "Creating schedule", done: "Created schedule"),
        "CronDelete": Labels(running: "Deleting schedule", done: "Deleted schedule"),
        "CronList": Labels(running: "Listing schedules", done: "Listed schedules"),
    ]

    /// Labels for a tool name, falling back to a derived readable name.
    public static func labels(for toolName: String) -> Labels {
        if let known = table[toolName] {
            return known
        }
        let readable = readableName(for: toolName)
        return Labels(running: "Running \(readable)", done: "Ran \(readable)")
    }

    /// A readable fallback: `mcp__codex__codex-reply` → `codex: codex-reply`.
    static func readableName(for toolName: String) -> String {
        if toolName.hasPrefix("mcp__") {
            let parts = toolName.dropFirst(5).split(separator: "__", maxSplits: 1)
            if parts.count == 2 {
                return "\(parts[0]): \(parts[1])"
            }
            return String(toolName.dropFirst(5))
        }
        return toolName
    }
}
