import type { HarnessBridge } from "../bridge";
import { HarnessBridgeError } from "../bridge";
import { copyDefaults } from "../copyKeys";
import type { HarnessStore } from "../model/store";
import type { BinarySetting, ModelDescriptor, NativeEvent, ProtocolLine } from "../protocol/types";
import { MOCK_FILES, mockContextUsage, mockModels, mockSessions, themeFor } from "./mockData";
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

/**
 * A monotonic counter, NOT `Date.now()`. The reducer dedups on frame uuid, and
 * several queued replies land inside the same millisecond — timestamp uuids
 * collided, the duplicates were dropped, and the dev harness showed a queue
 * that never drained. That is a defect in the mock, and it masked the very
 * drain behaviour the queue scenario exists to demonstrate.
 */
let replySeq = 0;

/**
 * One canned turn, shaped like the REAL CLI: a `result` and no trailing
 * `session_state_changed`, which is the frame sequence the live probes actually
 * produce. The mock used to append its own `state: idle` frame, which is exactly
 * what hid the stuck-busy bug from the dev harness.
 */

function replyLines(store: HarnessStore, text: string): void {
  replySeq += 1;
  const seq = replySeq;
  const messageId = `msg_dev_${seq}`;
  store.receive([
    {
      kind: "protocol",
      line: {
        type: "stream_event",
        event: { type: "message_start", message: { id: messageId, model: "claude-sonnet-5" } },
        uuid: `dev-ms-${seq}`
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
        uuid: `dev-a-${seq}`
      } as ProtocolLine
    },
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
        uuid: `dev-r-${seq}`
      } as ProtocolLine
    }
  ]);
}

function bridgeError(code: string, userMessage: string): HarnessBridgeError {
  return new HarnessBridgeError({ code, userMessage });
}

export function installMockBridge(store: HarnessStore): Scenario {
  const params = new URLSearchParams(window.location.search);
  const scenario = scenarioFor(params.get("scenario") ?? "rich", {
    degraded: params.get("degraded") === "1",
    restoreFails: params.get("restorefail") === "1"
  });
  const speed = (params.get("speed") as Speed) ?? "instant";
  const theme = themeFor(params.get("theme"));
  const sessions = scenario.hasSessions ? mockSessions() : [];
  const player = createPlayer(store, speed === "instant" ? "instant" : speed, scenario.freezeAt);

  let stage = 0;
  let tokenTotal = 24800;
  let runCounter = 0;
  let running = false;
  const replyTo = (text: string) => replyLines(store, text);

  /**
   * The mock's model of the Swift controller: exactly one live process, and a
   * plain `start` against a live one FAILS. That refusal is the whole of issues
   * 1 and 3 — a mock that quietly accepted it could not have shown them.
   */
  const nextRunId = (): string => {
    runCounter += 1;
    return `run-dev-${runCounter}`;
  };

  const startRun = (resumeSessionId?: string): string => {
    const runId = nextRunId();
    running = true;
    store.receive([{ kind: "runStarted", runId, resumedSessionId: resumeSessionId }]);
    return runId;
  };

  const stopRun = (status = 0, error?: string): void => {
    if (!running) return;
    running = false;
    store.receive([{ kind: "runExited", runId: `run-dev-${runCounter}`, status, error }]);
  };

  let binary: BinarySetting = scenario.binary ?? {
    resolvedPath: "/opt/homebrew/bin/claude",
    version: "2.1.233"
  };

  const cachedModels: ModelDescriptor[] | undefined = scenario.cachedModels
    ? mockModels()
    : undefined;

  const bridge: HarnessBridge = {
    async context() {
      return {
        panelId: "panel-dev",
        workspaceId: "workspace-dev",
        workingDirectory: "/Users/dev/projects/supermux",
        theme,
        copy: { ...copyDefaults },
        cliStatus: scenario.cliAvailable
          ? { available: true, version: binary.version, path: binary.resolvedPath }
          : {
              available: false,
              error:
                "spawn claude ENOENT — searched PATH, ~/.local/bin, ~/.bun/bin, nvm, volta, fnm, mise, asdf"
            },
        restore: scenario.restoreSessionId
          ? { sessionId: scenario.restoreSessionId, model: "sonnet", permissionMode: "default" }
          : undefined,
        cachedModels
      };
    },
    async listSessions() {
      return { sessions };
    },
    async loadSessionHistory() {
      return { events: scenario.lines, truncated: false };
    },
    async start({ resumeSessionId } = {}) {
      if (running) {
        throw bridgeError(
          "session_already_running",
          "A Claude session is already running in this pane. Stop it or open a new Claude pane."
        );
      }
      return { runId: startRun(resumeSessionId) };
    },
    async restart({ resumeSessionId } = {}) {
      // Tear the old one down FIRST and let it fully exit, which is what makes
      // this legal where `start` is not.
      stopRun();
      await new Promise((resolve) => window.setTimeout(resolve, 220));
      // History is NOT replayed here. The web layer loads it through
      // `loadSessionHistory` before it restarts, exactly as it does against the
      // native bridge; replaying it again from inside the restart reopened the
      // last turn on top of the live run, and the first real reply was filed
      // into that resurrected turn instead of its own.
      return { runId: startRun(resumeSessionId) };
    },
    async openSessionInNewPane({ sessionId }) {
      // No pane factory in the browser harness; say what the native side would
      // have done so the affordance is still verifiable here.
      window.setTimeout(
        () => window.alert(`Would open a new Claude pane resuming ${sessionId}`),
        0
      );
    },
    async send({ text }) {
      window.setTimeout(() => replyTo(text), 320);
      return { sent: true };
    },
    async interrupt({ cancelQueued }) {
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
      // The CLI keeps running whatever is still queued after an interrupt
      // (`still_queued` on the receipt), so the chips drain into real turns —
      // `ensureTurn` promotes queued[0] on the first frame of each. Without
      // this leg the dev harness left chips parked forever and made a drained
      // queue indistinguishable from a stuck one.
      if (cancelQueued) return;
      let delay = 240;
      for (const message of store.getSnapshot().queued) {
        window.setTimeout(() => replyTo(message.text), delay);
        delay += 420;
      }
    },
    async cancelQueued() {},
    async stop() {
      stopRun();
    },
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
    async saveDraft() {},
    async getBinarySetting() {
      await new Promise((resolve) => window.setTimeout(resolve, 120));
      return binary;
    },
    async setBinaryPath({ path }) {
      await new Promise((resolve) => window.setTimeout(resolve, 160));
      const trimmed = path?.trim();
      if (!trimmed) {
        binary = { resolvedPath: "/opt/homebrew/bin/claude", version: "2.1.233" };
        return binary;
      }
      // Mirrors SupermuxHarnessBinarySetting.setPath: a tilde is expanded, the
      // result must be absolute, and it must name an existing executable regular
      // file. The scripted rejections make each of those reachable here; a mock
      // that accepted what Swift rejects would send the dev harness a message
      // the app never shows.
      const expanded = trimmed.startsWith("~/")
        ? `/Users/dev${trimmed.slice(1)}`
        : trimmed;
      if (!expanded.startsWith("/")) {
        throw bridgeError("binary_invalid", "Enter an absolute path to the Claude executable.");
      }
      if (expanded.endsWith("/") || expanded.includes("isdir")) {
        throw bridgeError("binary_invalid", `${expanded} is a directory, not an executable.`);
      }
      if (expanded.includes("missing")) {
        throw bridgeError("binary_invalid", `No file at ${expanded}.`);
      }
      if (expanded.includes("noexec")) {
        throw bridgeError("binary_invalid", `${expanded} is not executable.`);
      }
      binary = { resolvedPath: expanded, overridePath: expanded, version: "2.1.233-ccx" };
      return binary;
    },
    async rewindPreview() {
      await new Promise((resolve) => window.setTimeout(resolve, 260));
      // A session recorded before SDK file checkpointing answers exactly this,
      // which is the degraded conversation-only path.
      if (scenario.rewindUnavailable) {
        return { canRewind: false, filesChanged: [], insertions: 0, deletions: 0 };
      }
      return {
        canRewind: true,
        filesChanged: [
          "/Users/dev/projects/supermux/Sources/SessionIndexView.swift",
          "/Users/dev/projects/supermux/Sources/Workspace.swift"
        ],
        insertions: 12,
        deletions: 4
      };
    },
    async rewind({ restoreFiles, resumeAtUuid }) {
      stopRun();
      await new Promise((resolve) => window.setTimeout(resolve, 260));
      const runId = startRun(resumeAtUuid);
      // The half-failure the controller used to swallow into a stderr line and
      // report as success: `rewind_files` refuses, the CONVERSATION rewind still
      // stands, and the pane has to say which half happened. It is not a
      // rejection — a rejection would claim the whole rewind failed.
      if (restoreFiles && scenario.restoreFails) {
        return {
          runId,
          filesRestored: false,
          reason: "rewind_files: no checkpoint recorded for this message"
        };
      }
      // No restore was requested, so nothing was restored — the web layer keeps
      // its conversation-only note for that, rather than reading it as a failure.
      return { runId, filesRestored: restoreFiles };
    }
  };

  window.supermuxHarnessMock = bridge;

  window.setTimeout(() => {
    if (scenario.lines.length > 0) {
      player.play(scenario.lines);
      // Playing history is not the same as having a process; scenarios that
      // want a live one say so, and that is what makes `start` refuse.
      if (scenario.processRunning) startRun(scenario.restoreSessionId);
    }
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

  // A process that dies with messages still queued behind it. The CLI-side queue
  // dies with it, so the pane has to say those messages are still waiting and
  // re-send them once a run is back up.
  if (scenario.killAfterMs !== undefined) {
    window.setTimeout(
      () => stopRun(1, "claude exited unexpectedly (signal 9)"),
      scenario.killAfterMs
    );
  }

  // A pane whose binary has no cached catalog gets one pushed a beat later —
  // the "Loading models…" row is what fills that gap, and it has to be visible
  // in the dev harness or nobody can check it.
  if (scenario.probeCatalogAfterMs !== undefined) {
    window.setTimeout(
      () => store.receive([{ kind: "modelCatalog", models: mockModels() }]),
      scenario.probeCatalogAfterMs
    );
  }

  return scenario;
}
