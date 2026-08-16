import type { ProtocolLine } from "../protocol/types";
import { fixtures, richSession } from "./fixtures";
import { permissionCompletion, permissionResolution } from "./fixtures/permission";
import { questionResolution } from "./fixtures/question";
import { planApproval } from "./fixtures/plan";
import { queuedDrafts } from "./fixtures/queue";
import { resumeHistory } from "./fixtures/resume";

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
  | "resume";

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
  "resume"
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

export function scenarioFor(name: string): Scenario {
  const key = (SCENARIO_NAMES as string[]).includes(name) ? (name as ScenarioName) : "rich";
  switch (key) {
    case "empty":
      return { name: key, lines: [], cliAvailable: true, hasSessions: false };
    case "nocli":
      return { name: key, lines: [], cliAvailable: false, hasSessions: false };
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
        queuedDrafts
      };
    case "sessions":
      return { name: key, lines: [], cliAvailable: true, hasSessions: true };
    case "resume":
      return {
        name: key,
        lines: resumeHistory,
        cliAvailable: true,
        hasSessions: true,
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
