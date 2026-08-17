import { memo, useMemo, useState } from "react";
import type { Block, Turn } from "../../model/types";
import { useCopy } from "../CopyContext";
import { ChevronDown, ChevronRight, XCircle } from "../Icons";
import { formatCost, formatDuration } from "../format";
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
  return block.status === "running" || block.status === "pending";
}

function splitRunningWork(work: Block[]): { earlier: Block[]; visible: Block[] } {
  if (work.length <= LIVE_TAIL) return { earlier: [], visible: work };
  const keepFrom = work.length - LIVE_TAIL;
  const earlier: Block[] = [];
  const visible: Block[] = [];
  work.forEach((block, index) => {
    // Anything still running stays on screen wherever it sits: a subagent that
    // spawned ten tools ago is the row a user most wants to watch.
    if (index >= keepFrom || isLive(block)) visible.push(block);
    else earlier.push(block);
  });
  return { earlier, visible };
}

export const TurnView = memo(function TurnView({
  turn,
  isLast
}: {
  turn: Turn;
  isLast: boolean;
}) {
  const copy = useCopy();
  const [override, setOverride] = useState<boolean | undefined>(undefined);
  const [showEarlier, setShowEarlier] = useState(false);
  const { work, tail } = useMemo(() => splitBlocks(turn), [turn.blocks]);

  const settled = turn.state !== "streaming";
  const toolCount = useMemo(() => work.filter((b) => b.kind === "tool").length, [work]);
  const folded = override ?? (settled && turn.folded && !isLast && work.length > 0);
  const running = useMemo(() => splitRunningWork(work), [work]);
  const earlierTools = useMemo(
    () => running.earlier.filter((b) => b.kind === "tool").length,
    [running.earlier]
  );
  const duration =
    turn.result?.durationMs ??
    (turn.endedAtMs !== undefined ? turn.endedAtMs - turn.startedAtMs : undefined);

  const foldLabel =
    turn.state === "aborted"
      ? copy("supermux.harness.turn.stoppedAfter", { duration: formatDuration(duration) })
      : turn.state === "error"
        ? copy("supermux.harness.turn.failedAfter", { duration: formatDuration(duration) })
        : copy("supermux.harness.turn.workedFor", { duration: formatDuration(duration) });

  return (
    <article className={`turn is-${turn.state}`} data-turn-id={turn.id}>
      {turn.userText !== undefined ? (
        <UserMessage text={turn.userText} images={turn.userImages} />
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
                    {copy("supermux.harness.turn.previousToolCalls", { count: toolCount })}
                  </span>
                ) : null}
              </button>
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
                    {copy("supermux.harness.turn.previousToolCalls", {
                      count: earlierTools > 0 ? earlierTools : running.earlier.length
                    })}
                  </span>
                </button>
              ) : null}
              {(showEarlier ? work : running.visible).map((block) => (
                <BlockView key={block.key} block={block} />
              ))}
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
            {formatDuration(duration)} · {formatCost(turn.result.costDeltaUsd)}
          </div>
        ) : null}
      </div>
    </article>
  );
});
