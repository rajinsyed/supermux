import { memo, useMemo, useRef, useState } from "react";
import { hasLiveBackgroundWork } from "../../model/tasks";
import type { Block, RelayRecord, Turn } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import { Check, ChevronDown, ChevronRight, XCircle } from "../Icons";
import { formatDuration } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
import { WorkingDots } from "../primitives/Spinner";
import { isRelayAck } from "../views/relay";
import { BlockView } from "./BlockView";
import { useFoldGuardHost } from "./foldGuard";
import { RelayChip } from "./RelayChip";
import { UserMessage } from "./UserMessage";

/** Trailing work rows kept visible while a turn is still running. */
const LIVE_TAIL = 1;

function splitBlocks(turn: Turn): { work: Block[]; tail: Block[] } {
  const blocks = turn.blocks;
  let cut = blocks.length;
  for (let i = blocks.length - 1; i >= 0; i -= 1) {
    const block = blocks[i];
    if (block.kind === "text" && block.text.trim().length > 0) {
      cut = i;
      continue;
    }
    if (block.kind === "notice" || block.kind === "divider") {
      cut = i;
      continue;
    }
    break;
  }
  return { work: blocks.slice(0, cut), tail: blocks.slice(cut) };
}

/**
 * A running turn shows only its latest work plus anything still live. Forty
 * fully-expanded tool cards push the "Working for Ns" indicator and the answer
 * itself off-screen, and the rows a user cares about while Claude works are the
 * current one and any subagent that has not finished.
 */
function isLive(block: Block): boolean {
  if (block.kind !== "tool") return false;
  if (block.status === "running" || block.status === "pending") return true;
  // A backgrounded command or an async agent returns its tool_result IMMEDIATELY
  // — "running in background", "async_launched" — so the card settles while the
  // work it launched keeps going for another minute. Judged on tool status alone
  // it is history, and the live progress card the user is watching gets folded
  // away behind "3 earlier tool calls" seconds after it appears.
  return hasLiveBackgroundWork({ blocks: [block] } as Turn);
}

/**
 * Which work rows are folded away while the turn streams. Empty once the turn
 * settles: a settled turn shows everything (behind the fold header).
 *
 * `wasLive` is the set of blocks that have been live at any point in this turn,
 * and membership is permanent. Liveness alone is not enough: pressing Stop on a
 * background shell settles its task, which un-lives the card, which drops it
 * behind "3 earlier tool calls" IN THE SAME FRAME — the row the user just acted
 * on disappearing as the acknowledgement of the act. A card that earned a place
 * on screen by running keeps it until the turn settles and the whole tree opens.
 */
function hiddenWhileStreaming(
  work: Block[],
  settled: boolean,
  wasLive: Set<string>
): boolean[] {
  if (settled || work.length <= LIVE_TAIL) return work.map(() => false);
  const keepFrom = work.length - LIVE_TAIL;
  // Anything still running stays on screen wherever it sits: a subagent that
  // spawned ten tools ago is the row a user most wants to watch.
  return work.map((block, index) => index < keepFrom && !wasLive.has(block.key));
}

export const TurnView = memo(function TurnView({
  turn,
  onRewind,
  relay
}: {
  turn: Turn;
  /** Kept for caller compatibility; folding no longer exempts the last turn. */
  isLast?: boolean;
  /** Given the turn's user-message uuid; absent when the pane cannot rewind. */
  onRewind?: (uuid: string) => void;
  /**
   * This turn carries a message the user addressed to an AGENT, which the pane
   * routed through main. It is not a conversation with Claude, so it does not
   * get a bubble and its "RELAYED" answer does not get an answer's weight.
   */
  relay?: RelayRecord;
}) {
  const copy = useCopy();
  const [override, setOverride] = useState<boolean | undefined>(undefined);
  const [showEarlier, setShowEarlier] = useState(false);
  const { work, tail } = useMemo(() => splitBlocks(turn), [turn.blocks]);

  const settled = turn.state !== "streaming";
  const toolCount = useMemo(() => work.filter((b) => b.kind === "tool").length, [work]);
  /**
   * Something inside this turn is open because the reader opened it — a workflow
   * card, a subagent drill-in, a log strip, an output tail. The automatic fold
   * (the `result`, or a background task settling minutes later) is a
   * housekeeping convenience and loses to that: a turn that sweeps the reader's
   * open disclosures behind "6 earlier tool calls" while they are reading them
   * is the worst thing this pane can do with a scroll position.
   *
   * Their OWN click on the fold header still wins — `override` is checked first
   * — so the affordance never stops working; only the automatic sweep defers.
   */
  const { held, Provider: FoldGuardProvider } = useFoldGuardHost();
  // The just-finished turn folds its work tree the moment it settles — the
  // answer is what remains on screen, the way Cursor collapses a finished run.
  const folded = override ?? (settled && turn.folded && work.length > 0 && !held);
  /**
   * A turn that has been ON SCREEN unfolded keeps its work tree mounted through
   * a later fold (hidden by class), so the reader's expanded disclosures and
   * scroll positions inside it survive. A turn that mounts already-folded —
   * history replay, the virtualized scrollback window — skips the render
   * entirely until first opened: a 200-turn session must not mount every card
   * it will never show.
   */
  const everOpen = useRef(!folded);
  if (!folded) everOpen.current = true;
  const renderWork = everOpen.current;
  /**
   * Every block that has run at some point in this turn. Written during render
   * on purpose — it is derived from the blocks being rendered right now, and an
   * effect would run a frame LATE, which is exactly the frame in which a stopped
   * card would vanish.
   */
  const wasLive = useRef<Set<string>>(new Set());
  for (const block of work) {
    if (isLive(block)) wasLive.current.add(block.key);
  }
  const hidden = useMemo(
    () => hiddenWhileStreaming(work, settled, wasLive.current),
    [work, settled]
  );
  const earlierCount = useMemo(() => {
    const earlier = work.filter((_, i) => hidden[i]);
    const tools = earlier.filter((b) => b.kind === "tool").length;
    return tools > 0 ? tools : earlier.length;
  }, [work, hidden]);
  /**
   * The turn's own span when it is the larger number: a turn that settled and
   * REOPENED (a workflow's summary leg) carries only its LAST result's
   * duration_ms, and "Worked for 2s" over a 40-second run under-reports the
   * very work the fold is summarizing.
   */
  const span = turn.endedAtMs !== undefined ? turn.endedAtMs - turn.startedAtMs : undefined;
  const reported = turn.result?.durationMs;
  const duration =
    reported !== undefined && span !== undefined
      ? Math.max(reported, span)
      : reported ?? span;

  const durationText = formatDuration(duration, copy);
  const foldLabel =
    turn.state === "aborted"
      ? copy("supermux.harness.turn.stoppedAfter", { duration: durationText })
      : turn.state === "error"
        ? copy("supermux.harness.turn.failedAfter", { duration: durationText })
        : copy("supermux.harness.turn.workedFor", { duration: durationText });

  return (
    <article className={`turn is-${turn.state}${relay ? " is-relay" : ""}`} data-turn-id={turn.id}>
      {relay ? (
        <RelayChip relay={relay} />
      ) : turn.userText !== undefined ? (
        <UserMessage
          text={turn.userText}
          images={turn.userImages}
          onRewind={
            onRewind && turn.userUuid ? () => onRewind(turn.userUuid as string) : undefined
          }
        />
      ) : null}

      <div className="turn-body">
        {work.length > 0 ? (
          <>
            {/* One button slot for both states: the settled fold header and the
                streaming overflow expander swap PROPS on the same element, so
                settling never rebuilds the sibling work tree below. */}
            {settled ? (
              <button
                type="button"
                className="fold-head"
                onClick={() => setOverride(!folded)}
                aria-expanded={!folded}
              >
                {folded ? <ChevronRight size={12} /> : <ChevronDown size={12} />}
                <span className="fold-label">{foldLabel}</span>
                {toolCount > 0 ? (
                  <span className="fold-count tnum">
                    {plural(
                      copy,
                      toolCount,
                      "supermux.harness.turn.previousToolCallsOne",
                      "supermux.harness.turn.previousToolCalls"
                    )}
                  </span>
                ) : null}
              </button>
            ) : earlierCount > 0 ? (
              <button
                type="button"
                className="work-overflow"
                onClick={() => setShowEarlier((v) => !v)}
                aria-expanded={showEarlier}
              >
                {showEarlier ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
                <span className="tnum">
                  {plural(
                    copy,
                    earlierCount,
                    "supermux.harness.turn.previousToolCallsOne",
                    "supermux.harness.turn.previousToolCalls"
                  )}
                </span>
              </button>
            ) : null}
            {/* ONE work tree for the turn's whole life. Every block keeps the
                same parent and key from its first frame to the fold, so a turn
                settling — or a block moving out of the streaming overflow — is a
                prop change and a Disclosure animation, never a remount. An
                expanded subagent drill-in, workflow log strip, or scrolled
                transcript therefore survives the streaming→complete edge intact,
                and folding hides via a class rather than unmounting so a reader
                who walks away finds everything exactly where they left it. */}
            <div className={`turn-work${folded ? " is-folded" : ""}`}>
              <FoldGuardProvider>
                {renderWork &&
                  work.map((block, i) => (
                    <Disclosure
                      key={block.key}
                      // Streaming overflow hides a block until "N earlier tool
                      // calls" reveals it; at settle every block eases open.
                      open={!hidden[i] || showEarlier}
                      // `keepMounted` is what makes the whole tree stable: a card
                      // sliding into the overflow, or easing open at settle, is
                      // the SAME mounted subtree changing visibility — its open
                      // drill-ins and scroll positions ride along.
                      keepMounted
                      className={hidden[i] ? "turn-work-hidden" : "turn-work-item"}
                    >
                      {/* Marked live while it is the visible tail of a streaming
                          turn: that row must not auto-size and drag the settled
                          transcript above it. */}
                      <BlockView block={block} live={!settled && !hidden[i]} />
                    </Disclosure>
                  ))}
              </FoldGuardProvider>
            </div>
          </>
        ) : null}

        {/* A relay turn's answer is the single word "RELAYED" — main confirming
            it did the plumbing. Shown as an assistant message it reads as
            Claude replying to the user with a shout, in a turn whose actual
            content is elsewhere. It is compacted to a receipt beside the chip;
            anything main says BEYOND the acknowledgment still renders, because
            then it is telling the user something. */}
        {tail.map((block) =>
          relay && block.kind === "text" && isRelayAck(block.text) ? (
            <div key={block.key} className="relay-ack">
              <Check size={10} className="mark-ok" />
              {copy("supermux.harness.relay.ack")}
            </div>
          ) : (
            <BlockView key={block.key} block={block} />
          )
        )}

        {turn.state === "streaming" ? (
          <div className="turn-live">
            <WorkingDots />
            <Elapsed
              className="turn-live-label tnum"
              startedAtMs={turn.startedAtMs}
              prefix={`${copy("supermux.harness.status.workingFor", { duration: "" }).trim()} `}
            />
          </div>
        ) : null}

        {turn.state === "aborted" ? (
          <div className="turn-interrupted">
            <XCircle size={12} />
            {copy("supermux.harness.turn.interrupted")}
          </div>
        ) : null}
      </div>
    </article>
  );
});
