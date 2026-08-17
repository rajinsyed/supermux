import type { HarnessBridge } from "../bridge";
import { copyDefaults } from "../copyKeys";
import type { HarnessStore } from "../model/store";
import type { NativeEvent, ProtocolLine } from "../protocol/types";
import { MOCK_FILES, mockContextUsage, mockSessions, themeFor } from "./mockData";
import { delayFor, scenarioFor, type Scenario, type Speed } from "./scenarios";

interface Player {
  play(lines: ProtocolLine[]): void;
  stop(): void;
}

function createPlayer(store: HarnessStore, speed: Speed, freezeAt?: number): Player {
  let timer = 0;
  let cancelled = false;

  const emit = (line: ProtocolLine) => {
    const event: NativeEvent = { kind: "protocol", line };
    store.receive([event]);
  };

  const play = (lines: ProtocolLine[]) => {
    const limit = freezeAt !== undefined ? Math.min(freezeAt, lines.length) : lines.length;
    if (speed === "instant") {
      store.receive(lines.slice(0, limit).map((line) => ({ kind: "protocol" as const, line })));
      store.flushNow();
      return;
    }
    let index = 0;
    const step = () => {
      if (cancelled || index >= limit) return;
      const line = lines[index];
      emit(line);
      index += 1;
      timer = window.setTimeout(step, delayFor(speed, line));
    };
    step();
  };

  return {
    play,
    stop() {
      cancelled = true;
      if (timer) window.clearTimeout(timer);
    }
  };
}

export function installMockBridge(store: HarnessStore): Scenario {
  const params = new URLSearchParams(window.location.search);
  const scenario = scenarioFor(params.get("scenario") ?? "rich");
  const speed = (params.get("speed") as Speed) ?? "instant";
  const theme = themeFor(params.get("theme"));
  const sessions = scenario.hasSessions ? mockSessions() : [];
  const player = createPlayer(store, speed === "instant" ? "instant" : speed, scenario.freezeAt);

  let stage = 0;
  let tokenTotal = 24800;

  const bridge: HarnessBridge = {
    async context() {
      return {
        panelId: "panel-dev",
        workspaceId: "workspace-dev",
        workingDirectory: "/Users/dev/projects/supermux",
        theme,
        copy: { ...copyDefaults },
        cliStatus: scenario.cliAvailable
          ? { available: true, version: "2.1.233", path: "/opt/homebrew/bin/claude" }
          : {
              available: false,
              error:
                "spawn claude ENOENT — searched PATH, ~/.local/bin, ~/.bun/bin, nvm, volta, fnm, mise, asdf"
            },
        restore: scenario.restoreSessionId
          ? { sessionId: scenario.restoreSessionId, model: "sonnet", permissionMode: "default" }
          : undefined
      };
    },
    async listSessions() {
      return { sessions };
    },
    async loadSessionHistory() {
      return { events: scenario.lines, truncated: false };
    },
    async start() {
      return { runId: "run-dev-1" };
    },
    async send({ text }) {
      window.setTimeout(() => {
        const messageId = `msg_dev_${Date.now()}`;
        store.receive([
          { kind: "protocol", line: { type: "system", subtype: "session_state_changed", state: "running" } as ProtocolLine },
          {
            kind: "protocol",
            line: {
              type: "stream_event",
              event: { type: "message_start", message: { id: messageId, model: "claude-sonnet-5" } },
              uuid: `dev-ms-${Date.now()}`
            } as ProtocolLine
          },
          {
            kind: "protocol",
            line: {
              type: "assistant",
              message: {
                id: messageId,
                role: "assistant",
                content: [
                  {
                    type: "text",
                    text: `Mock reply — you sent: “${text.slice(0, 120)}”. Wire the native bridge for real answers.`
                  }
                ]
              },
              uuid: `dev-a-${Date.now()}`
            } as ProtocolLine
          },
          { kind: "protocol", line: { type: "system", subtype: "session_state_changed", state: "idle" } as ProtocolLine },
          {
            kind: "protocol",
            line: {
              type: "result",
              subtype: "success",
              is_error: false,
              result: "Mock reply delivered.",
              duration_ms: 820,
              num_turns: 1,
              total_cost_usd: 0.0031,
              usage: { input_tokens: 12, output_tokens: 42 },
              uuid: `dev-r-${Date.now()}`
            } as ProtocolLine
          }
        ]);
      }, 320);
      return { sent: true };
    },
    async interrupt() {
      store.receive([
        {
          kind: "protocol",
          line: {
            type: "result",
            subtype: "error_during_execution",
            is_error: true,
            result: "Interrupted by user",
            terminal_reason: "aborted_streaming",
            duration_ms: 1400,
            uuid: `dev-int-${Date.now()}`
          } as ProtocolLine
        }
      ]);
    },
    async cancelQueued() {},
    async stop() {},
    async setModel() {},
    async setPermissionMode() {},
    async respondPermission() {
      const next = stage === 0 ? scenario.followUp : scenario.followUp2;
      stage += 1;
      if (next) window.setTimeout(() => player.play(next), 260);
    },
    async renameSession() {},
    async getContextUsage() {
      tokenTotal = Math.min(190000, tokenTotal + 8600);
      return mockContextUsage(tokenTotal);
    },
    async fileSuggestions({ query }) {
      const q = query.toLowerCase();
      return { paths: MOCK_FILES.filter((path) => path.toLowerCase().includes(q)) };
    },
    async pickFiles() {
      return { images: [], paths: [] };
    },
    async openFile() {},
    async copyText({ text }) {
      await navigator.clipboard?.writeText(text).catch(() => undefined);
    },
    async saveFile() {
      // No native save panel in the dev harness; savePlanMarkdown falls back to
      // an anchor download, which is exactly what a real browser should do.
      return { saved: false };
    },
    async notify() {},
    async saveDraft() {}
  };

  window.supermuxHarnessMock = bridge;

  window.setTimeout(() => {
    if (scenario.lines.length > 0) player.play(scenario.lines);
    if (scenario.queuedDrafts) {
      window.setTimeout(() => {
        scenario.queuedDrafts!.forEach((text, i) => {
          store.dispatch({
            kind: "localSend",
            uuid: `queued-dev-${i}`,
            text,
            atMs: Date.now()
          });
        });
      }, 120);
    }
    store.dispatch({ kind: "contextUsage", usage: mockContextUsage(tokenTotal) });
  }, 0);

  return scenario;
}
