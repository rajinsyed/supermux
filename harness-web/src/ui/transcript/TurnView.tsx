import { Fragment, memo, useMemo, useState } from "react";
import { hasLiveBackgroundWork } from "../../model/tasks";
import type { Block, Turn } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import { ChevronDown, ChevronRight, XCircle } from "../Icons";
import { formatCost, formatDuration } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
import { WorkingDots } from "../primitives/Spinner";
import { BlockView } from "./BlockView";
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

interface WorkSegment {
  hidden: boolean;
  blocks: Block[];
}

interface RunningWork {
  earlier: Block[];
  /** Runs of consecutive blocks, so revealing the hidden ones keeps work order. */
  segments: WorkSegment[];
}

function splitRunningWork(work: Block[]): RunningWork {
  if (work.length <= LIVE_TAIL) return { earlier: [], segments: [{ hidden: false, blocks: work }] };
  const keepFrom = work.length - LIVE_TAIL;
  const earlier: Block[] = [];
  const segments: WorkSegment[] = [];
  work.forEach((block, index) => {
    // Anything still running stays on screen wherever it sits: a subagent that
    // spawned ten tools ago is the row a user most wants to watch.
    const hidden = index < keepFrom && !isLive(block);
    if (hidden) earlier.push(block);
    const tail = segments[segments.length - 1];
    if (tail && tail.hidden === hidden) tail.blocks.push(block);
    else segments.push({ hidden, blocks: [block] });
  });
  return { earlier, segments };
}

export const TurnView = memo(function TurnView({
  turn,
  isLast,
  onRewind
}: {
  turn: Turn;
  isLast: boolean;
  /** Given the turn's user-message uuid; absent when the pane cannot rewind. */
  onRewind?: (uuid: string) => void;
}) {
  const copy = useCopy();
  const [override, setOverride] = useState<boolean | undefined>(undefined);
  const [showEarlier, setShowEarlier] = useState(false);
  const { work, tail } = useMemo(() => splitBlocks(turn), [turn.blocks]);

  const settled = turn.state !== "streaming";
  const toolCount = useMemo(() => work.filter((b) => b.kind === "tool").length, [work]);
  const folded = override ?? (settled && turn.folded && !isLast && work.length > 0);
  const running = useMemo(() => splitRunningWork(work), [work]);
  const earlierCount = useMemo(() => {
    const tools = running.earlier.filter((b) => b.kind === "tool").length;
    return tools > 0 ? tools : running.earlier.length;
  }, [running.earlier]);
  const duration =
    turn.result?.durationMs ??
    (turn.endedAtMs !== undefined ? turn.endedAtMs - turn.startedAtMs : undefined);

  const durationText = formatDuration(duration, copy);
  const foldLabel =
    turn.state === "aborted"
      ? copy("supermux.harness.turn.stoppedAfter", { duration: durationText })
      : turn.state === "error"
        ? copy("supermux.harness.turn.failedAfter", { duration: durationText })
        : copy("supermux.harness.turn.workedFor", { duration: durationText });

  return (
    <article className={`turn is-${turn.state}`} data-turn-id={turn.id}>
      {turn.userText !== undefined ? (
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
          settled ? (
            <>
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
              {/* The settled fold stays an unwrapped swap: `.turn-work` owns the
                  work rail as a pseudo-element at a negative offset, and the
                  Disclosure's `overflow: hidden` would clip that rail away for
                  the whole animation. */}
              {!folded ? (
                <div className="turn-work">
                  {work.map((block) => (
                    <BlockView key={block.key} block={block} />
                  ))}
                </div>
              ) : null}
            </>
          ) : (
            <div className="turn-work">
              {running.earlier.length > 0 ? (
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
              {/* Hidden runs get the shared Disclosure so revealing them eases
                  open like every other collapse, instead of jumping the
                  reading position by hundreds of pixels in one frame. */}
              {running.segments.map((segment) =>
                segment.hidden ? (
                  <Disclosure
                    key={`hidden:${segment.blocks[0].key}`}
                    open={showEarlier}
                    className="turn-work-hidden"
                  >
                    {segment.blocks.map((block) => (
                      <BlockView key={block.key} block={block} />
                    ))}
                  </Disclosure>
                ) : (
                  <Fragment key={`shown:${segment.blocks[0].key}`}>
                    {segment.blocks.map((block) => (
                      // Marked live: this is the one row the tail keeps on
                      // screen, so nothing about it may auto-size and drag the
                      // settled transcript above it up and down.
                      <BlockView key={block.key} block={block} live />
                    ))}
                  </Fragment>
                )
              )}
            </div>
          )
        ) : null}

        {tail.map((block) => (
          <BlockView key={block.key} block={block} />
        ))}

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

        {turn.result && settled && turn.result.costDeltaUsd !== undefined && work.length > 0 ? (
          <div className="turn-footer tnum">
            {durationText} · {formatCost(turn.result.costDeltaUsd)}
          </div>
        ) : null}
      </div>
    </article>
  );
});
