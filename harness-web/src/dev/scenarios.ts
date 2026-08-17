import type { BinarySetting, ProtocolLine } from "../protocol/types";
import { fixtures, richSession } from "./fixtures";
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
  | "crash";

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
  "crash"
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
        queuedDrafts
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
