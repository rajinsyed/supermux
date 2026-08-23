import { memo, useId } from "react";
import type { ThinkingBlock } from "../../model/types";
import { useCopy } from "../CopyContext";
import { Brain, ChevronDown, ChevronRight } from "../Icons";
import { formatDuration } from "../format";
import { usePresentationState } from "../presentationState";
import { Disclosure } from "../primitives/Disclosure";

export const ThinkingBlockView = memo(function ThinkingBlockView({
  block,
  stateKey
}: {
  block: ThinkingBlock;
  stateKey?: string;
}) {
  const copy = useCopy();
  const localId = useId();
  const [open, setOpen] = usePresentationState(
    `${stateKey ?? `thinking:${localId}`}:open`,
    false
  );
  const rawDuration = block.endedAtMs !== undefined ? block.endedAtMs - block.startedAtMs : 0;
  const duration = rawDuration >= 1000 ? formatDuration(rawDuration, copy) : undefined;

  // Cursor's grammar: a live shimmer with no counters, then "Thinking · 4s".
  // Token tallies and a ticking clock are metric chrome the transcript no
  // longer carries; the numbers live in the header and the export.
  const summary = duration
    ? copy("supermux.harness.thinking.summaryNoTokens", { duration })
    : copy("supermux.harness.thinking.label");

  return (
    <div className={`thinking${block.streaming ? " is-streaming" : ""}${open ? " is-open" : ""}`}>
      <button type="button" className="thinking-head" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <span className="thinking-caret" aria-hidden="true">
          {open ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
        </span>
        <Brain size={12} className="thinking-icon" />
        {block.streaming ? (
          <span className="thinking-label shimmer">{copy("supermux.harness.thinking.label")}</span>
        ) : (
          <span className="thinking-label">{summary}</span>
        )}
      </button>
      <Disclosure open={open} className="thinking-body">
        {block.text.trim().length > 0 ? (
          block.text.split(/\n{2,}/).map((paragraph, i) => <p key={i}>{paragraph}</p>)
        ) : (
          <p className="thinking-redacted">{copy("supermux.harness.thinking.redacted")}</p>
        )}
      </Disclosure>
    </div>
  );
});
