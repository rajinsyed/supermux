import type { JsonObject, ProtocolLine } from "../../protocol/types";

let counter = 0;
export function uid(prefix = "u"): string {
  counter += 1;
  return `${prefix}-${counter.toString(16).padStart(6, "0")}-fixture`;
}

const SESSION = "fixture-session-0001";

export function initLine(overrides: JsonObject = {}): ProtocolLine {
  return {
    type: "system",
    subtype: "init",
    cwd: "/Users/dev/projects/supermux",
    session_id: SESSION,
    tools: ["Bash", "Read", "Edit", "Write", "Grep", "Glob", "Task", "TodoWrite", "WebSearch"],
    mcp_servers: [{ name: "linear", status: "connected" }, { name: "sentry", status: "connected" }],
    model: "claude-sonnet-5",
    permissionMode: "default",
    slash_commands: ["compact", "clear", "context", "model", "review"],
    agents: ["Explore", "Plan", "general-purpose"],
    skills: ["code-review", "verify"],
    claude_code_version: "2.1.233",
    output_style: "default",
    capabilities: ["interrupt_receipt_v1", "interrupt_cancel_queued_v1"],
    uuid: uid("init"),
    ...overrides
  } as ProtocolLine;
}

export function initializeResponse(): ProtocolLine {
  return {
    type: "control_response",
    response: {
      subtype: "success",
      request_id: "init-1",
      response: {
        commands: [
          { name: "compact", description: "Compact the conversation", argumentHint: "[instructions]" },
          { name: "clear", description: "Clear conversation history", argumentHint: "" },
          { name: "context", description: "Show context usage breakdown", argumentHint: "" },
          { name: "review", description: "Review the current diff", argumentHint: "[pr|branch]" },
          { name: "model", description: "Change the active model", argumentHint: "[model]" }
        ],
        agents: ["Explore", "Plan", "general-purpose"],
        output_style: "default",
        available_output_styles: ["default", "explanatory", "concise"],
        models: [
          {
            value: "claude-opus-5",
            resolvedModel: "claude-opus-5-20260401",
            displayName: "Opus 5",
            description: "Most capable. Best for hard reasoning and large refactors.",
            supportsEffort: true,
            supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"],
            supportsFastMode: false
          },
          {
            value: "claude-sonnet-5",
            resolvedModel: "claude-sonnet-5-20260201",
            displayName: "Sonnet 5",
            description: "Balanced speed and capability. Recommended default.",
            supportsEffort: true,
            supportedEffortLevels: ["low", "medium", "high"],
            supportsFastMode: true
          },
          {
            value: "claude-haiku-4-5",
            displayName: "Haiku 4.5",
            description: "Fastest and cheapest. Good for small edits.",
            supportsEffort: false,
            supportsFastMode: true
          }
        ],
        account: { tokenSource: "oauth", apiProvider: "firstParty" },
        current_permission_mode: "default"
      }
    }
  } as ProtocolLine;
}

export function userLine(text: string): ProtocolLine {
  return {
    type: "user",
    message: { role: "user", content: [{ type: "text", text }] },
    parent_tool_use_id: null,
    session_id: SESSION,
    uuid: uid("user"),
    timestamp: new Date().toISOString()
  } as ProtocolLine;
}

export function statusLine(status: "requesting" | "compacting" | null, extra: JsonObject = {}): ProtocolLine {
  return { type: "system", subtype: "status", status, uuid: uid("status"), ...extra } as ProtocolLine;
}

export function sessionState(state: "idle" | "running" | "requires_action"): ProtocolLine {
  return { type: "system", subtype: "session_state_changed", state, uuid: uid("state") } as ProtocolLine;
}

export function messageStart(messageId: string, parent: string | null = null): ProtocolLine {
  return {
    type: "stream_event",
    event: {
      type: "message_start",
      message: { id: messageId, type: "message", role: "assistant", model: "claude-sonnet-5", content: [] }
    },
    session_id: SESSION,
    parent_tool_use_id: parent,
    uuid: uid("ms")
  } as ProtocolLine;
}

export function blockStart(index: number, block: JsonObject, parent: string | null = null): ProtocolLine {
  return {
    type: "stream_event",
    event: { type: "content_block_start", index, content_block: block },
    session_id: SESSION,
    parent_tool_use_id: parent,
    uuid: uid("cbs")
  } as ProtocolLine;
}

export function textDelta(index: number, text: string, parent: string | null = null): ProtocolLine {
  return {
    type: "stream_event",
    event: { type: "content_block_delta", index, delta: { type: "text_delta", text } },
    session_id: SESSION,
    parent_tool_use_id: parent,
    uuid: uid("td")
  } as ProtocolLine;
}

export function thinkingDelta(index: number, text: string, estimatedTokens?: number): ProtocolLine {
  return {
    type: "stream_event",
    event: {
      type: "content_block_delta",
      index,
      delta: { type: "thinking_delta", thinking: text, estimated_tokens: estimatedTokens }
    },
    session_id: SESSION,
    parent_tool_use_id: null,
    uuid: uid("thd")
  } as ProtocolLine;
}

export function jsonDelta(index: number, partial: string, parent: string | null = null): ProtocolLine {
  return {
    type: "stream_event",
    event: { type: "content_block_delta", index, delta: { type: "input_json_delta", partial_json: partial } },
    session_id: SESSION,
    parent_tool_use_id: parent,
    uuid: uid("jd")
  } as ProtocolLine;
}

export function blockStop(index: number, parent: string | null = null): ProtocolLine {
  return {
    type: "stream_event",
    event: { type: "content_block_stop", index },
    session_id: SESSION,
    parent_tool_use_id: parent,
    uuid: uid("cbe")
  } as ProtocolLine;
}

export function messageStop(parent: string | null = null): ProtocolLine {
  return {
    type: "stream_event",
    event: { type: "message_stop" },
    session_id: SESSION,
    parent_tool_use_id: parent,
    uuid: uid("mst")
  } as ProtocolLine;
}

export function assistantText(
  messageId: string,
  text: string,
  overrides: JsonObject = {}
): ProtocolLine {
  return {
    type: "assistant",
    message: {
      id: messageId,
      model: "claude-sonnet-5",
      type: "message",
      role: "assistant",
      content: [{ type: "text", text }],
      usage: { input_tokens: 4, output_tokens: 120, cache_read_input_tokens: 22000 }
    },
    parent_tool_use_id: null,
    session_id: SESSION,
    uuid: uid("asst"),
    timestamp: new Date().toISOString(),
    ...overrides
  } as ProtocolLine;
}

export function assistantThinking(messageId: string, thinking: string): ProtocolLine {
  return {
    type: "assistant",
    message: {
      id: messageId,
      model: "claude-sonnet-5",
      type: "message",
      role: "assistant",
      content: [{ type: "thinking", thinking, signature: "EtUFCokBCBAYAipA" }],
      usage: { input_tokens: 4, output_tokens: 60 }
    },
    parent_tool_use_id: null,
    session_id: SESSION,
    uuid: uid("asst"),
    timestamp: new Date().toISOString()
  } as ProtocolLine;
}

export function assistantToolUse(
  messageId: string,
  toolUseId: string,
  name: string,
  input: JsonObject,
  parent: string | null = null
): ProtocolLine {
  return {
    type: "assistant",
    message: {
      id: messageId,
      model: "claude-sonnet-5",
      type: "message",
      role: "assistant",
      content: [{ type: "tool_use", id: toolUseId, name, input, caller: { type: "direct" } }],
      usage: { input_tokens: 4, output_tokens: 90 }
    },
    parent_tool_use_id: parent,
    session_id: SESSION,
    uuid: uid("asst"),
    timestamp: new Date().toISOString()
  } as ProtocolLine;
}

export function toolResult(
  toolUseId: string,
  content: string,
  structured?: JsonObject,
  isError = false,
  parent: string | null = null
): ProtocolLine {
  return {
    type: "user",
    message: {
      role: "user",
      content: [{ type: "tool_result", tool_use_id: toolUseId, content, is_error: isError }]
    },
    parent_tool_use_id: parent,
    session_id: SESSION,
    uuid: uid("tr"),
    timestamp: new Date().toISOString(),
    tool_use_result: structured
  } as ProtocolLine;
}

export function resultLine(overrides: JsonObject = {}): ProtocolLine {
  return {
    type: "result",
    subtype: "success",
    is_error: false,
    result: "Done.",
    duration_ms: 18420,
    duration_api_ms: 17300,
    num_turns: 4,
    total_cost_usd: 0.1832,
    usage: {
      input_tokens: 12,
      output_tokens: 1840,
      cache_creation_input_tokens: 4210,
      cache_read_input_tokens: 128400,
      output_tokens_details: { thinking_tokens: 612 }
    },
    modelUsage: {
      "claude-sonnet-5": { costUSD: 0.1832, contextWindow: 200000 }
    },
    permission_denials: [],
    terminal_reason: "completed",
    ttft_ms: 940,
    session_id: SESSION,
    uuid: uid("res"),
    ...overrides
  } as ProtocolLine;
}

export function canUseTool(
  requestId: string,
  toolName: string,
  input: JsonObject,
  overrides: JsonObject = {}
): ProtocolLine {
  return {
    type: "control_request",
    request_id: requestId,
    request: {
      subtype: "can_use_tool",
      tool_name: toolName,
      display_name: toolName,
      input,
      tool_use_id: `toolu_${requestId}`,
      ...overrides
    }
  } as ProtocolLine;
}

export function streamText(
  messageId: string,
  index: number,
  text: string,
  chunk = 18
): ProtocolLine[] {
  const lines: ProtocolLine[] = [blockStart(index, { type: "text", text: "" })];
  for (let i = 0; i < text.length; i += chunk) {
    lines.push(textDelta(index, text.slice(i, i + chunk)));
  }
  lines.push(assistantText(messageId, text));
  lines.push(blockStop(index));
  return lines;
}

export function streamThinking(
  messageId: string,
  index: number,
  text: string,
  tokens: number
): ProtocolLine[] {
  const lines: ProtocolLine[] = [blockStart(index, { type: "thinking", thinking: "", signature: "" })];
  const chunk = Math.max(1, Math.ceil(text.length / 6));
  let emitted = 0;
  for (let i = 0; i < text.length; i += chunk) {
    emitted += 1;
    lines.push(thinkingDelta(index, text.slice(i, i + chunk)));
    lines.push({
      type: "system",
      subtype: "thinking_tokens",
      estimated_tokens: Math.round((tokens * emitted) / 6),
      estimated_tokens_delta: Math.round(tokens / 6),
      uuid: uid("tt")
    } as ProtocolLine);
  }
  lines.push(assistantThinking(messageId, text));
  lines.push(blockStop(index));
  return lines;
}

export function streamToolUse(
  messageId: string,
  index: number,
  toolUseId: string,
  name: string,
  input: JsonObject,
  parent: string | null = null
): ProtocolLine[] {
  const json = JSON.stringify(input);
  const lines: ProtocolLine[] = [
    blockStart(index, { type: "tool_use", id: toolUseId, name, input: {} }, parent)
  ];
  const chunk = Math.max(8, Math.ceil(json.length / 5));
  for (let i = 0; i < json.length; i += chunk) {
    lines.push(jsonDelta(index, json.slice(i, i + chunk), parent));
  }
  lines.push(assistantToolUse(messageId, toolUseId, name, input, parent));
  lines.push(blockStop(index, parent));
  return lines;
}
