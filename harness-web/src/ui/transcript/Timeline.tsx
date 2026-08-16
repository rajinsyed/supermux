import { useEffect, useRef, useState, type RefObject } from "react";
import type { Turn } from "../../model/types";
import { useCopy } from "../CopyContext";

interface TimelineProps {
  turns: Turn[];
  scrollRef: RefObject<HTMLDivElement | null>;
}

export function Timeline({ turns, scrollRef }: TimelineProps) {
  const copy = useCopy();
  const railRef = useRef<HTMLDivElement>(null);
  const [hover, setHover] = useState<{ index: number; top: number } | null>(null);

  useEffect(() => {
    const scroller = scrollRef.current;
    const rail = railRef.current;
    if (!scroller || !rail) return;
    const update = () => {
      const viewTop = scroller.scrollTop;
      const viewBottom = viewTop + scroller.clientHeight;
      const ticks = rail.querySelectorAll<HTMLElement>("[data-turn-tick]");
      ticks.forEach((tick) => {
        const id = tick.dataset.turnTick;
        const target = scroller.querySelector<HTMLElement>(`[data-turn-id="${CSS.escape(id ?? "")}"]`);
        if (!target) return;
        const top = target.offsetTop;
        const bottom = top + target.offsetHeight;
        tick.dataset.active = bottom > viewTop && top < viewBottom ? "true" : "false";
      });
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

  if (turns.length < 3) return null;

  const goTo = (turnId: string) => {
    const scroller = scrollRef.current;
    const target = scroller?.querySelector<HTMLElement>(`[data-turn-id="${CSS.escape(turnId)}"]`);
    if (!scroller || !target) return;
    scroller.scrollTo({ top: Math.max(0, target.offsetTop - 24), behavior: "smooth" });
  };

  const preview = hover !== null ? turns[hover.index] : undefined;

  return (
    <div className="timeline" ref={railRef} aria-label={copy("supermux.harness.a11y.timeline")}>
      {turns.map((turn, index) => (
        <button
          key={turn.id}
          type="button"
          className={`timeline-tick is-${turn.state}`}
          data-turn-tick={turn.id}
          onClick={() => goTo(turn.id)}
          onMouseEnter={(event) =>
            setHover({ index, top: event.currentTarget.offsetTop })
          }
          onMouseLeave={() => setHover(null)}
          aria-label={turn.userText?.slice(0, 60) ?? `Turn ${turn.seq}`}
        />
      ))}
      {preview ? (
        <div className="timeline-preview" style={{ top: hover!.top - 12 }}>
          <div className="timeline-preview-user">{preview.userText ?? `Turn ${preview.seq}`}</div>
          <div className="timeline-preview-body">{previewText(preview)}</div>
        </div>
      ) : null}
    </div>
  );
}

function previewText(turn: Turn): string {
  for (let i = turn.blocks.length - 1; i >= 0; i -= 1) {
    const block = turn.blocks[i];
    if (block.kind === "text" && block.text.trim().length > 0) return block.text.slice(0, 220);
  }
  return turn.result?.text?.slice(0, 220) ?? "";
}
