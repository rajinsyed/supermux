import { useCallback, useEffect, useRef, useState, type RefObject } from "react";
import type { Turn } from "../../model/types";
import { useCopy } from "../CopyContext";

/**
 * The message rail — Cursor's timeline, at the pane's MIDDLE-LEFT edge.
 *
 * The previous rail ran full-height down the RIGHT edge, directly under the
 * scrollbar, as a column of 8×2px marks starting at the top and stopping
 * wherever the turns ran out. Three things were wrong with that and the round-5
 * note names all of them: it sat on the side the scrollbar already owns (two
 * position indicators, one pixel apart, disagreeing about what they measure —
 * the rail marks TURNS, the scrollbar marks PIXELS), it ran the full height so
 * it read as a second scrollbar rather than as a map, and it was on the far
 * side from the content it indexes.
 *
 * The reference is a short rail, VERTICALLY CENTRED at the left edge, one tick
 * per message, the on-screen one wider and brighter, a preview on hover, a jump
 * on click. Being centred and short is what makes it a map: it does not track
 * the viewport's height, it lists the conversation.
 *
 * Cost. The active tick is recomputed on scroll and on resize only, from
 * `offsetTop`/`offsetHeight` reads that hit the layout tree once per tick — no
 * per-frame work, no observers per turn, no React state on the scroll path. The
 * only state that renders is the hovered index; the active mark is written
 * straight to `dataset` so a scroll does not re-render the transcript.
 */

/** Below this the rail is noise: three ticks map nothing. */
const MIN_TURNS = 3;

export function MessageRail({
  turns,
  scrollRef
}: {
  turns: Turn[];
  scrollRef: RefObject<HTMLDivElement | null>;
}) {
  const copy = useCopy();
  const rail = useRef<HTMLDivElement>(null);
  const [hover, setHover] = useState<number | null>(null);

  useEffect(() => {
    const scroller = scrollRef.current;
    const node = rail.current;
    if (!scroller || !node) return;
    /**
     * The ACTIVE tick is the one whose turn owns the viewport's centre, not
     * every turn that overlaps it. The old rail lit every visible turn, so on a
     * pane showing four short turns the rail brightened four ticks at once and
     * said nothing about where the reader actually was.
     */
    const update = () => {
      const middle = scroller.scrollTop + scroller.clientHeight / 2;
      const ticks = node.querySelectorAll<HTMLElement>("[data-turn-tick]");
      let best: HTMLElement | undefined;
      let bestDistance = Infinity;
      const seen: Array<{ tick: HTMLElement; top: number; bottom: number }> = [];
      ticks.forEach((tick) => {
        const target = scroller.querySelector<HTMLElement>(
          `[data-turn-id="${CSS.escape(tick.dataset.turnTick ?? "")}"]`
        );
        tick.dataset.active = "false";
        if (!target) return;
        const top = target.offsetTop;
        seen.push({ tick, top, bottom: top + target.offsetHeight });
      });
      for (const entry of seen) {
        // Inside the turn wins outright; otherwise the nearest edge, so a gap
        // between turns still lights the one the reader just left.
        const distance =
          middle >= entry.top && middle <= entry.bottom
            ? 0
            : Math.min(Math.abs(middle - entry.top), Math.abs(middle - entry.bottom));
        if (distance < bestDistance) {
          bestDistance = distance;
          best = entry.tick;
        }
      }
      if (best) best.dataset.active = "true";
    };
    update();
    scroller.addEventListener("scroll", update, { passive: true });
    const observer = new ResizeObserver(update);
    observer.observe(scroller);
    return () => {
      scroller.removeEventListener("scroll", update);
      observer.disconnect();
    };
  }, [scrollRef, turns.length]);

  const goTo = useCallback(
    (turnId: string) => {
      const scroller = scrollRef.current;
      const target = scroller?.querySelector<HTMLElement>(`[data-turn-id="${CSS.escape(turnId)}"]`);
      if (!scroller || !target) return;
      scroller.scrollTo({ top: Math.max(0, target.offsetTop - 24), behavior: "smooth" });
    },
    [scrollRef]
  );

  if (turns.length < MIN_TURNS) return null;

  const preview = hover !== null ? turns[hover] : undefined;

  return (
    <div className="msg-rail" ref={rail} aria-label={copy("supermux.harness.a11y.timeline")}>
      <div className="msg-rail-ticks">
        {turns.map((turn, index) => (
          <button
            key={turn.id}
            type="button"
            // Pointer-only affordance (see the @media (pointer: fine) rule in
            // rail.css): it must not put twenty-four invisible stops ahead of
            // the composer in the tab order. The turns themselves are reachable
            // by scrolling, and the transcript is a labelled `log` region.
            tabIndex={-1}
            className={`msg-rail-tick is-${turn.state}`}
            data-turn-tick={turn.id}
            onClick={() => goTo(turn.id)}
            onMouseEnter={() => setHover(index)}
            onMouseLeave={() => setHover((at) => (at === index ? null : at))}
            aria-label={
              turn.userText?.slice(0, 60) ??
              copy("supermux.harness.turn.turnNumber", { seq: turn.seq })
            }
          />
        ))}
      </div>
      {preview ? (
        <div className="msg-rail-preview" role="presentation">
          <div className="msg-rail-preview-user">
            {preview.userText ?? copy("supermux.harness.turn.turnNumber", { seq: preview.seq })}
          </div>
          {previewText(preview) ? (
            <div className="msg-rail-preview-body">{previewText(preview)}</div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function previewText(turn: Turn): string {
  for (let i = turn.blocks.length - 1; i >= 0; i -= 1) {
    const block = turn.blocks[i];
    if (block.kind === "text" && block.text.trim().length > 0) return block.text.slice(0, 200);
  }
  return turn.result?.text?.slice(0, 200) ?? "";
}
