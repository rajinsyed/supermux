import { memo, useMemo, useState } from "react";
import type { Block, Turn } from "../../model/types";
import { useCopy } from "../CopyContext";
import { ChevronDown, ChevronRight, XCircle } from "../Icons";
import { formatCost, formatDuration } from "../format";
import { Elapsed } from "../primitives/Elapsed";
import { WorkingDots } from "../primitives/Spinner";
import { BlockView } from "./BlockView";
import { UserMessage } from "./UserMessage";

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

export const TurnView = memo(function TurnView({
  turn,
  isLast
}: {
  turn: Turn;
  isLast: boolean;
}) {
  const copy = useCopy();
  const [override, setOverride] = useState<boolean | undefined>(undefined);
  const { work, tail } = useMemo(() => splitBlocks(turn), [turn.blocks]);

  const settled = turn.state !== "streaming";
  const toolCount = useMemo(() => work.filter((b) => b.kind === "tool").length, [work]);
  const folded = override ?? (settled && turn.folded && !isLast && work.length > 0);
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
              {work.map((block) => (
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
