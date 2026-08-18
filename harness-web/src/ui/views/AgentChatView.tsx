import {
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type RefObject
} from "react";
import { getBridge } from "../../bridge";
import { isThreadRunning, threadBlocks } from "../../model/agentThreads";
import type { AgentThread, Block, RelayRecord } from "../../model/types";
import type { ProtocolLine } from "../../protocol/types";
import { plural, useCopy } from "../CopyContext";
import { ArrowDown, Cpu, Layers } from "../Icons";
import { formatCompactDuration, formatTokens } from "../format";
import { Elapsed } from "../primitives/Elapsed";
import { Spinner } from "../primitives/Spinner";
import { toolStatsSummary } from "../tools/toolStats";
import { BlockView } from "../transcript/BlockView";
import { OpenViewContext } from "./OpenViewContext";

/**
 * One agent's conversation, rendered as a full chat.
 *
 * The blocks are the SAME `Block` union the main transcript carries and go
 * through the SAME `BlockView`, which is the point: a tool call inside an agent
 * has to look and behave like a tool call in the main chat, or the reader is
 * learning two interfaces for one thing. Updates are block-by-block rather than
 * character-by-character because the CLI does not forward `stream_event` frames
 * for subagents (probed: parent_tool_use_id is always null on those) — full
 * blocks per completed block is what the wire gives, and that is what this
 * shows.
 */

type DiskPhase = "idle" | "loading" | "missing" | "failed";

/**
 * The disk fallback, for a thread with no live frames.
 *
 * A resumed session, or one where forwarding started after the agent did, has a
 * thread the dock knows about and nothing to read in it. The agent's own file
 * on disk has the whole conversation, and replaying it into the thread — once,
 * guarded on there being no live frames — is what makes the view work at all in
 * that state. Live frames always win afterwards: the reducer refuses a second
 * hydration and refuses any hydration of a thread that has live blocks.
 */
function useDiskFallback(
  thread: AgentThread | undefined,
  onHydrate: (toolUseId: string, events: ProtocolLine[]) => void
): { phase: DiskPhase; retry(): void } {
  const [phase, setPhase] = useState<DiskPhase>("idle");
  const [attempt, setAttempt] = useState(0);
  const requested = useRef<string | undefined>(undefined);
  const toolUseId = thread?.toolUseId;
  const empty = thread !== undefined && thread.blocks.length === 0 && !thread.hasLiveFrames;
  const target = thread?.taskId ?? thread?.agentId;
  /**
   * A RUNNING agent whose frames are being forwarded needs no disk read at all:
   * its file is mid-write, the reply is a stale prefix of what the wire is
   * already delivering, and hydrating it makes the thread grow twice. The
   * fallback exists for the thread that will never receive live frames — a
   * resumed session, a forwarding gap — which is what a settled thread with
   * nothing in it is.
   */
  const live = thread !== undefined && isThreadRunning(thread) && thread.hasLiveFrames === true;

  useEffect(() => {
    if (!toolUseId || !empty || live) return;
    if (!target) {
      // Nothing to address the file by yet: the agent was announced but its
      // task frames have not landed. Not a failure — it resolves on its own.
      setPhase("idle");
      return;
    }
    if (requested.current === `${toolUseId}|${attempt}`) return;
    requested.current = `${toolUseId}|${attempt}`;
    setPhase("loading");
    let cancelled = false;
    getBridge()
      .loadSubagentTranscript({ taskId: target })
      .then((result) => {
        if (cancelled) return;
        if (result.missing || (result.events ?? []).length === 0) {
          setPhase("missing");
          return;
        }
        setPhase("idle");
        onHydrate(toolUseId, result.events);
      })
      .catch(() => {
        if (!cancelled) setPhase("failed");
      });
    return () => {
      cancelled = true;
    };
  }, [attempt, empty, live, onHydrate, target, toolUseId]);

  const retry = useCallback(() => setAttempt((value) => value + 1), []);
  return { phase, retry };
}

function RelayStatus({ relays }: { relays: RelayRecord[] }) {
  const copy = useCopy();
  const latest = relays[relays.length - 1];
  if (!latest) return null;
  const label =
    latest.state === "delivered"
      ? copy("supermux.harness.agentView.relayDelivered")
      : latest.state === "failed"
        ? copy("supermux.harness.agentView.relayFailed")
        : latest.state === "relayed"
          ? copy("supermux.harness.agentView.relayRelayed")
          : copy("supermux.harness.agentView.relaySending");
  return (
    <div className={`agent-relay-status is-${latest.state}`} role="status">
      {latest.state === "sending" ? <Spinner size={10} /> : null}
      <span>{label}</span>
      {/* The one honest caveat: a relay reaches main's model at ITS next turn,
          and if main is blocked on this very agent's foreground Task, that is
          after the agent finishes. Backgrounding it first is what avoids that,
          and when that could not be done the view says so rather than implying
          an instant delivery. */}
      {latest.state !== "delivered" && latest.state !== "failed" ? (
        <span className="agent-relay-hint">
          {latest.backgrounded === false
            ? copy("supermux.harness.agentView.relayQueuedForeground")
            : copy("supermux.harness.agentView.relayHint")}
        </span>
      ) : null}
    </div>
  );
}

export function AgentChatView({
  thread,
  threads,
  relays,
  scrollRef,
  contentRef,
  showPill = false,
  onJump,
  onHydrate
}: {
  thread: AgentThread | undefined;
  /** Every thread, so a child row can wear the child's NAME, not its wire id. */
  threads?: Record<string, AgentThread>;
  /** Relays addressed to THIS agent, oldest first. */
  relays: RelayRecord[];
  scrollRef: RefObject<HTMLDivElement | null>;
  contentRef?: RefObject<HTMLDivElement | null>;
  /**
   * The reader has scrolled away from the bottom of a thread that is still
   * growing. The main chat has always had this; an agent view is exactly as
   * live and needs the same way back, or scrolling up during a run is a
   * one-way trip.
   */
  showPill?: boolean;
  onJump?(): void;
  onHydrate(toolUseId: string, events: ProtocolLine[]): void;
}) {
  const copy = useCopy();
  const openView = useContext(OpenViewContext);
  const { phase, retry } = useDiskFallback(thread, onHydrate);
  const running = thread !== undefined && isThreadRunning(thread);

  const metrics = useMemo(() => {
    if (!thread) return [];
    const out: string[] = [];
    if (thread.totalTokens) {
      out.push(copy("supermux.harness.subagent.tokens", { tokens: formatTokens(thread.totalTokens) }));
    }
    if (thread.toolUses) {
      out.push(
        plural(
          copy,
          thread.toolUses,
          "supermux.harness.subagent.toolUsesOne",
          "supermux.harness.subagent.toolUses"
        )
      );
    }
    if (!running && thread.durationMs) out.push(formatCompactDuration(thread.durationMs, copy));
    return out;
  }, [copy, running, thread]);

  if (!thread) {
    return (
      <div className="harness-scroll transcript" ref={scrollRef}>
        <div className="transcript-inner">
          <div className="drill-status">{copy("supermux.harness.agentView.unavailable")}</div>
        </div>
      </div>
    );
  }

  // Through the shared resolver, so the brief at the top of an agent's chat
  // comes from the same three-source rule everywhere and is not present for
  // some agents and absent for others.
  const blocks: Block[] = threadBlocks(thread);
  const stats = !running && thread.toolStats ? toolStatsSummary(thread.toolStats, copy) : [];

  return (
    <div className={`transcript-wrap${showPill ? " has-pill" : ""}`}>
    <div className="harness-scroll transcript agent-view" ref={scrollRef} tabIndex={-1} role="log">
      <div className="transcript-inner" ref={contentRef}>
        {/* One quiet header row: the frame's breadcrumb already names the
            agent, so this line carries only the facts — type, model, tallies —
            with no icon chrome. */}
        <div className="agent-view-head">
          <span className="agent-view-identity">
            <span className="agent-view-name">
              {thread.description ?? copy("supermux.harness.dock.untitledAgent")}
            </span>
            <span className="agent-view-meta">
              {thread.subagentType ? (
                <span className="subagent-type">{thread.subagentType}</span>
              ) : null}
              {thread.model ? (
                <span className="subagent-model" title={thread.model}>
                  <Cpu size={9} />
                  <span className="subagent-model-name">{thread.model}</span>
                </span>
              ) : null}
              {metrics.length > 0 ? <span className="tnum">{metrics.join(" · ")}</span> : null}
              {/* The agent's own badge, so a chat opened from the dock still
                  says WHAT it is when the type is absent. */}
              {!thread.subagentType ? (
                <span className="tool-badge is-quiet">
                  {copy("supermux.harness.subagent.badge")}
                </span>
              ) : null}
              {thread.background ? (
                <span className="tool-badge is-quiet">
                  {copy("supermux.harness.subagent.background")}
                </span>
              ) : null}
            </span>
            {/* What it did, once it is done — files edited, lines changed,
                searches run. Only after the fact: while it runs these are
                partial counts that walk backwards as often as forwards. */}
            {stats.length > 0 ? (
              <span className="agent-view-stats tnum">{stats.join(" · ")}</span>
            ) : null}
          </span>
          {running ? (
            <>
              <Elapsed className="agent-view-elapsed tnum" startedAtMs={thread.startedAtMs} />
              <Spinner size={12} />
            </>
          ) : null}
        </div>

        {thread.hydratedFromDisk ? (
          <div className="agent-view-source">{copy("supermux.harness.agentView.fromDisk")}</div>
        ) : null}

        {/* The brief renders even when the agent has not answered yet — it is
            the one thing that is knowable the instant the agent is spawned, and
            an agent view that opens blank while its prompt sits in the model is
            the report this round is fixing. The status line below is about the
            agent's OUTPUT, so it is keyed on there being none. */}
        {blocks.map((block) => (
          <BlockView key={block.key} block={block} />
        ))}

        {thread.blocks.length === 0 ? (
          phase === "loading" ? (
            <div className="drill-status">
              <Spinner size={12} />
              {copy("supermux.harness.agentView.loading")}
            </div>
          ) : phase === "failed" ? (
            <div className="drill-status is-error">
              {copy("supermux.harness.agentView.failed")}
              <button type="button" className="link-btn" onClick={retry}>
                {copy("supermux.harness.agentView.retry")}
              </button>
            </div>
          ) : phase === "missing" ? (
            <div className="drill-status">{copy("supermux.harness.agentView.unavailable")}</div>
          ) : running ? (
            // A live agent that has not spoken yet is WORKING, not empty. The
            // empty copy reads as "there is nothing here", which is wrong for a
            // thread whose first block is seconds away.
            <div className="drill-status">
              <Spinner size={12} />
              {copy("supermux.harness.agentView.working")}
            </div>
          ) : (
            <div className="drill-status">{copy("supermux.harness.agentView.empty")}</div>
          )
        ) : null}

        {thread.childIds.length > 0 ? (
          <div className="agent-view-children">
            <div className="agent-view-children-title">
              {copy("supermux.harness.agentView.childAgents")}
            </div>
            {thread.childIds.map((id) => (
              <ChildRow
                key={id}
                label={threads?.[id]?.description}
                onOpen={() => openView({ kind: "agent", toolUseId: id })}
              />
            ))}
          </div>
        ) : null}

        <RelayStatus relays={relays} />
        <div className="transcript-pad" />
      </div>
    </div>
    {showPill && onJump ? (
      <button type="button" className="jump-pill" onClick={onJump}>
        <ArrowDown size={12} />
        {copy("supermux.harness.status.jumpToLatest")}
      </button>
    ) : null}
    </div>
  );
}

/**
 * A child thread, as a row that opens it. Deliberately NOT the child's blocks
 * inline: descending is a navigation, so the view stack records it and Escape
 * comes back here rather than to the main chat.
 */
function ChildRow({ label, onOpen }: { label: string | undefined; onOpen(): void }) {
  const copy = useCopy();
  return (
    <button type="button" className="agent-view-child" onClick={onOpen}>
      <Layers size={11} />
      <span className="agent-view-child-id">
        {label ?? copy("supermux.harness.dock.untitledAgent")}
      </span>
      <span className="agent-view-child-open">{copy("supermux.harness.agentView.openChild")}</span>
    </button>
  );
}
