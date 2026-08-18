import type { BinarySetting, ProtocolLine } from "../protocol/types";
import { fixtures, richSession } from "./fixtures";
import {
  bgBackgroundResponse,
  epochBaseOf,
  FOREGROUND_BASH_TOOL_USE_ID,
  foregroundBashLaunch,
  nestedFixture,
  nestedTail,
  rebaseRound3,
  ROUND3_CUTS,
  shellsOpening,
  shellsStopResponse,
  withNestedToolStats,
  withWorkflowLogs,
  withWorkflowActivity,
  workflowFixture,
  workflowTail,
  type BackgroundTaskSummary
} from "./fixtures/round3";
import {
  fwdNestedFixture,
  relayFixture,
  RELAY_AGENT_TOOL_USE_ID,
  ROUND4_CUTS
} from "./fixtures/round4";
import { round3SubagentTranscripts } from "./fixtures/subagentTranscripts";
import { permissionCompletion, permissionResolution } from "./fixtures/permission";
import { questionResolution } from "./fixtures/question";
import { planApproval } from "./fixtures/plan";
import { queuedDrafts } from "./fixtures/queue";
import { resumeHistory } from "./fixtures/resume";
import { rewindHistory } from "./fixtures/rewind";

export type ScenarioName =
  | "empty"
  | "nocli"
  | "rich"
  | "streaming"
  | "thinking"
  | "permission"
  | "question"
  | "plan"
  | "todos"
  | "subagents"
  | "interrupt"
  | "errors"
  | "compact"
  | "queue"
  | "longform"
  | "sessions"
  | "resume"
  | "rewind"
  | "binary"
  | "firstopen"
  | "crash"
  | "shells"
  | "nested"
  | "relay"
  | "workflow";

export const SCENARIO_NAMES: ScenarioName[] = [
  "empty",
  "nocli",
  "rich",
  "streaming",
  "thinking",
  "permission",
  "question",
  "plan",
  "todos",
  "subagents",
  "interrupt",
  "errors",
  "compact",
  "queue",
  "longform",
  "sessions",
  "resume",
  "rewind",
  "binary",
  "firstopen",
  "crash",
  "shells",
  "nested",
  "relay",
  "workflow"
];

export interface Scenario {
  name: ScenarioName;
  lines: ProtocolLine[];
  /** Lines replayed once the first pending permission is answered. */
  followUp?: ProtocolLine[];
  /** Second stage, replayed after the second permission answer. */
  followUp2?: ProtocolLine[];
  cliAvailable: boolean;
  hasSessions: boolean;
  /** Freeze playback at this many lines so streaming UI is captured mid-flight. */
  freezeAt?: number;
  queuedDrafts?: string[];
  restoreSessionId?: string;
  /**
   * A live process exists from the start, so `start` refuses and only `restart`
   * can swap sessions — the exact state issues 1 and 3 were reported in.
   */
  processRunning?: boolean;
  /** Serve a persisted catalog from `harness.context`, as a warm pane would. */
  cachedModels?: boolean;
  /** Push a probed catalog this many ms in, for the cold "Loading models…" path. */
  probeCatalogAfterMs?: number;
  /** The dry run answers canRewind:false — conversation-only degraded mode. */
  rewindUnavailable?: boolean;
  /**
   * The dry run promises a restore and the real `rewind_files` then refuses. The
   * conversation still rewinds, so this is the one path where the two halves of
   * a rewind disagree — and the one the pane used to report as flat success.
   */
  restoreFails?: boolean;
  /** Seed the binary setting, e.g. with an override already stored. */
  binary?: BinarySetting;
  /**
   * Kill the run this many ms in, while messages are still queued behind it —
   * the state in which a queue used to be handed to the NEXT run and promoted
   * onto the wrong turn.
   */
  killAfterMs?: number;
  /**
   * Settle the scripted open turn this many ms in and then drain the queue
   * FIFO, one reply per chip — the leg the real CLI runs after a turn ends,
   * which the interrupt path alone left unreachable in the dev harness.
   */
  settleAfterMs?: number;
  /**
   * Round 3. Frames replayed on a timer AFTER the opening slice, so the pane is
   * genuinely mid-flight rather than showing a finished transcript of one: the
   * workflow's agents advance under the reader, the nested tree completes
   * inside-out, the shell keeps ticking.
   */
  liveTail?: { lines: ProtocolLine[]; startAfterMs: number; stepMs: number };
  /**
   * A foreground Bash left in flight after the opening slice, and what the CLI
   * answers when it is moved to the background. This is the ONLY state in which
   * "Move to background" and Ctrl+B are reachable, so a scenario that means to
   * demonstrate them has to construct it deliberately.
   */
  foreground?: {
    lines: ProtocolLine[];
    toolUseId: string;
    /** Given the strip as it stands, so a REPLACE cannot evict live tasks. */
    response(keep: BackgroundTaskSummary[]): ProtocolLine[];
  };
  /** What the CLI answers when a task in this scenario is stopped. */
  stopResponse?: ProtocolLine[];
  /**
   * The agent the composer relays to in this scenario, and how the mock plays
   * the relay back: main answers RELAYED, and the guidance is delivered into
   * the agent's forwarded thread after a delay — which is the probe's own
   * timing, since an agent reads its mailbox at its next tool round rather than
   * on receipt.
   */
  relay?: { toolUseId: string; description: string };
  /** Canned `readTaskOutput` tails, keyed by task id, appended to as it "runs". */
  taskOutput?: Record<string, string[]>;
  /** Canned `loadSubagentTranscript` replies, keyed by taskId or runId/agentId. */
  subagentTranscripts?: Record<string, ProtocolLine[]>;
}

function streamingCut(): number {
  // Stop just after a text delta inside the second turn so a live caret shows.
  for (let i = 30; i < richSession.length; i += 1) {
    const line = richSession[i] as { type?: string; event?: { type?: string; delta?: { type?: string } } };
    if (
      line.type === "stream_event" &&
      line.event?.type === "content_block_delta" &&
      line.event.delta?.type === "text_delta" &&
      i > 36
    ) {
      return i + 1;
    }
  }
  return Math.min(40, richSession.length);
}

export interface ScenarioOptions {
  /**
   * `?degraded=1` on the rewind scenario, so the conversation-only fallback is
   * reachable without a second scenario that differs in one boolean.
   */
  degraded?: boolean;
  /**
   * `?restorefail=1` on the rewind scenario. Distinct from `degraded`: there the
   * dry run says up front that files cannot be restored and the checkbox is
   * never armable, while here the preview promises a restore and the real one
   * then fails — which is the only way to reach the degraded note.
   */
  restoreFails?: boolean;
}

/**
 * A frame that belongs to the AGENT rather than to main's relay turn.
 *
 * The relay probe's tail interleaves two stories: the agent's four sleeps, and
 * main taking a turn to run ListAgents/SendMessage. The dev scenario plays the
 * agent's half on a timer so its view is live, and leaves main's half to the
 * MOCK — which synthesizes it in response to a real send, so the scenario
 * demonstrates the relay rather than replaying a recording of one.
 */
function isAgentSideFrame(line: ProtocolLine): boolean {
  const frame = line as { type?: string; parent_tool_use_id?: string | null; subtype?: string };
  if (frame.type === "system") return true;
  return frame.parent_tool_use_id === RELAY_AGENT_TOOL_USE_ID;
}

export function scenarioFor(name: string, options: ScenarioOptions = {}): Scenario {
  const key = (SCENARIO_NAMES as string[]).includes(name) ? (name as ScenarioName) : "rich";
  switch (key) {
    case "empty":
      // A warm binary: the catalog was persisted by an earlier run, so the model
      // menu is populated before this pane has ever started a process.
      return { name: key, lines: [], cliAvailable: true, hasSessions: false, cachedModels: true };
    case "nocli":
      return { name: key, lines: [], cliAvailable: false, hasSessions: false };
    case "firstopen":
      // The cold half of issue 5: no cache for this binary, so the menu shows
      // the loading row until the background probe answers.
      return {
        name: key,
        lines: [],
        cliAvailable: true,
        hasSessions: false,
        probeCatalogAfterMs: 2400
      };
    case "binary":
      return {
        name: key,
        lines: [],
        cliAvailable: true,
        hasSessions: false,
        cachedModels: true,
        binary: {
          resolvedPath: "/Users/dev/.local/bin/ccx",
          overridePath: "/Users/dev/.local/bin/ccx",
          version: "2.1.233-ccx"
        }
      };
    case "rewind":
      // Multi-turn history with stable user uuids, so every bubble has a rewind
      // target and the truncation is visible.
      return {
        name: key,
        lines: rewindHistory,
        cliAvailable: true,
        hasSessions: true,
        cachedModels: true,
        processRunning: true,
        restoreSessionId: "rewind-session-7712",
        rewindUnavailable: options.degraded === true,
        restoreFails: options.restoreFails === true
      };
    case "streaming":
      return {
        name: key,
        lines: richSession,
        cliAvailable: true,
        hasSessions: true,
        freezeAt: streamingCut()
      };
    case "permission":
      return {
        name: key,
        lines: fixtures.permission,
        followUp: permissionResolution,
        followUp2: permissionCompletion,
        cliAvailable: true,
        hasSessions: true
      };
    case "question":
      return {
        name: key,
        lines: fixtures.question,
        followUp: questionResolution,
        cliAvailable: true,
        hasSessions: true
      };
    case "plan":
      return {
        name: key,
        lines: fixtures.plan,
        followUp: planApproval,
        cliAvailable: true,
        hasSessions: true
      };
    case "queue":
      return {
        name: key,
        lines: fixtures.queue,
        cliAvailable: true,
        hasSessions: true,
        cachedModels: true,
        processRunning: true,
        queuedDrafts,
        settleAfterMs: 2600
      };
    case "crash":
      // The queue outlives its process here: chips are waiting when the run dies,
      // so the strip must keep saying so and the messages must be re-sent in
      // order rather than promoted onto a later turn or dropped.
      return {
        name: key,
        lines: fixtures.queue,
        cliAvailable: true,
        hasSessions: true,
        cachedModels: true,
        processRunning: true,
        queuedDrafts,
        killAfterMs: 1600
      };
    case "shells": {
      // Feature 3, end to end. The opening slice launches a background shell —
      // dock row appears — and then leaves a FOREGROUND Bash in flight beside
      // it, which is the only state where Move-to-background and Ctrl+B exist.
      // Stop on the dock row replays the CLI's real kill sequence.
      //
      // Round 4 checks the DOCK against this scenario rather than changing it.
      // A second row is one click away and always was: Move to background (or
      // Ctrl+B) on the foreground Bash makes the CLI answer with a second
      // `background_tasks_changed`, and the dock then holds two shells — one
      // running, and, after Stop, one persisting dimmed. Replaying the probe's
      // own tail here instead would settle main and REMOVE the foreground Bash
      // the scenario exists to demonstrate that button on.
      return {
        name: key,
        lines: rebaseRound3(shellsOpening, epochBaseOf(shellsOpening)),
        cliAvailable: true,
        hasSessions: true,
        cachedModels: true,
        processRunning: true,
        foreground: {
          lines: foregroundBashLaunch,
          toolUseId: FOREGROUND_BASH_TOOL_USE_ID,
          response: (keep: BackgroundTaskSummary[]) => bgBackgroundResponse(keep)
        },
        stopResponse: shellsStopResponse,
        // The CLI streams no shell output at all, so the tail IS the feature:
        // the view polls, and each poll must show more than the last or nothing
        // has been demonstrated.
        taskOutput: {
          bnopezzr7: [
            "tick-1\n",
            "tick-1\ntick-2\n",
            "tick-1\ntick-2\ntick-3\n",
            "tick-1\ntick-2\ntick-3\ntick-4\n",
            "tick-1\ntick-2\ntick-3\ntick-4\ntick-5\n"
          ],
          b20r5l4dg: [
            "slow-1\n",
            "slow-1\nslow-2\n",
            "slow-1\nslow-2\nslow-3\n",
            "slow-1\nslow-2\nslow-3\nslow-4\n"
          ]
        }
      };
    }
    case "nested": {
      // Rebuilt in round 4 on the fwd2 probe, which is the SAME nested-agent
      // story recorded with `forwardSubagentText` — so both agents' whole
      // conversations are on the wire and their views have something to show.
      // The round-3 recording had only tool frames, which is exactly why its
      // agent views would have been empty.
      //
      // The slice stops with BOTH agents live: the outer has spoken and spawned
      // the inner, the inner has its prompt. The tail completes them
      // inside-out, which is where the AgentOutput metrics and toolStats land.
      const nested = withNestedToolStats(fwdNestedFixture);
      const base = epochBaseOf(nested);
      const now = Date.now();
      return {
        name: key,
        lines: rebaseRound3(nested.slice(0, ROUND4_CUTS.nested), base, now),
        cliAvailable: true,
        hasSessions: true,
        cachedModels: true,
        processRunning: true,
        liveTail: {
          lines: rebaseRound3(nested.slice(ROUND4_CUTS.nested), base, now),
          startAfterMs: 2600,
          stepMs: 900
        },
        subagentTranscripts: round3SubagentTranscripts
      };
    }
    case "relay": {
      // Round 4's composer-to-agent path, end to end.
      //
      // The slice stops at the launching turn's `result`: a backgrounded 'Slow
      // summarizer' is running, its dock row is up, and its agent view has a
      // composer pointed at it. Sending there runs the real relay — background
      // the Task, ask main to pass it on — and the mock answers RELAYED and
      // then delivers the guidance into the agent's forwarded thread a few
      // seconds later, which is the timing the probe actually observed (the
      // agent reads its mailbox at its NEXT tool round, not on receipt).
      const base = epochBaseOf(relayFixture);
      const now = Date.now();
      return {
        name: key,
        lines: rebaseRound3(relayFixture.slice(0, ROUND4_CUTS.relay), base, now),
        cliAvailable: true,
        hasSessions: true,
        cachedModels: true,
        processRunning: true,
        // The agent's own work carries on under the reader, so the view it is
        // read in is genuinely live rather than a finished transcript.
        liveTail: {
          lines: rebaseRound3(
            relayFixture.slice(ROUND4_CUTS.relay).filter(isAgentSideFrame),
            base,
            now
          ),
          startAfterMs: 2000,
          stepMs: 1400
        },
        relay: { toolUseId: RELAY_AGENT_TOOL_USE_ID, description: "Slow summarizer" },
        stopResponse: shellsStopResponse
      };
    }
    case "workflow": {
      // Round 4: the compact inline row and the multi-pane BROWSER it opens.
      //
      // Phases Gather/Merge with three agents. The slice stops at the first
      // progress frame — both Gather agents queued — and the tail advances them
      // live, so the browser can be opened MID-RUN: the phases column's done
      // counts climb under the reader, the selected agent's detail swaps from a
      // live Activity line to an Outcome, and ↑↓ / x / esc all act on a moving
      // target. The launching turn's `result` lands mid-workflow (the turn must
      // not reopen when progress keeps arriving after it), the workflow settles
      // in the background, and the CLI's own summary turn opens.
      //
      // Logs and per-agent activity are hand-added: the probe's workflow never
      // called log() and its agents used no tools, which left the log strip and
      // the browser's Activity section unreachable in the one scenario pinned
      // to show them. `subagentTranscripts` supplies prompts and outcomes that
      // are LONGER than their previews, so expand-from-disk visibly does
      // something.
      const flow = withWorkflowActivity(withWorkflowLogs(workflowFixture));
      // Rebased on the fixture's FIRST epoch (agent-alpha's queuedAt), shared by
      // both slices: anchoring on the probe's session init put every startedAt
      // ~7.5s in the future and the live elapsed read a clamped 0s for an
      // agent's whole lifetime.
      const base = epochBaseOf(flow);
      const now = Date.now();
      return {
        name: key,
        lines: rebaseRound3(flow.slice(0, ROUND3_CUTS.workflow), base, now),
        cliAvailable: true,
        hasSessions: true,
        cachedModels: true,
        processRunning: true,
        liveTail: {
          lines: rebaseRound3(flow.slice(ROUND3_CUTS.workflow), base, now),
          startAfterMs: 1800,
          stepMs: 1100
        },
        stopResponse: shellsStopResponse,
        subagentTranscripts: round3SubagentTranscripts
      };
    }
    case "sessions":
      // A pane with a LIVE session, which is what makes picking another session
      // from the browser exercise the replace-while-running path rather than a
      // cold first start.
      return {
        name: key,
        lines: fixtures.resume,
        cliAvailable: true,
        hasSessions: true,
        cachedModels: true,
        processRunning: true,
        restoreSessionId: "resumed-session-4821"
      };
    case "resume":
      return {
        name: key,
        lines: resumeHistory,
        cliAvailable: true,
        hasSessions: true,
        cachedModels: true,
        restoreSessionId: "resumed-session-4821"
      };
    default:
      return {
        name: key,
        lines: fixtures[key] ?? richSession,
        cliAvailable: true,
        hasSessions: true
      };
  }
}

export type Speed = "instant" | "fast" | "realtime";

export function delayFor(speed: Speed, line: ProtocolLine): number {
  if (speed === "instant") return 0;
  const type = (line as { type?: string }).type;
  const base = speed === "fast" ? 1 : 6;
  if (type === "stream_event") return base * 2;
  if (type === "assistant" || type === "user") return base * 8;
  if (type === "result") return base * 20;
  return base * 4;
}
