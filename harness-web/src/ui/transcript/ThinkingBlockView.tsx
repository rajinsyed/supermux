import { memo, useState } from "react";
import type { ThinkingBlock } from "../../model/types";
import { useCopy } from "../CopyContext";
import { Brain, ChevronDown, ChevronRight } from "../Icons";
import { formatDuration, formatTokens } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";

export const ThinkingBlockView = memo(function ThinkingBlockView({
  block
}: {
  block: ThinkingBlock;
}) {
  const copy = useCopy();
  const [open, setOpen] = useState(false);
  const rawDuration = block.endedAtMs !== undefined ? block.endedAtMs - block.startedAtMs : 0;
  const duration = rawDuration >= 1000 ? formatDuration(rawDuration, copy) : undefined;

  const summary =
    block.tokens && duration
      ? copy("supermux.harness.thinking.summary", {
          tokens: formatTokens(block.tokens),
          duration
        })
      : block.tokens
        ? `${copy("supermux.harness.thinking.label")} · ${formatTokens(block.tokens)} tokens`
        : duration
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
          <span className="thinking-label shimmer">
            {copy("supermux.harness.thinking.label")}
            {block.tokens ? (
              <span className="tnum"> · {formatTokens(block.tokens)} tokens</span>
            ) : null}
            <Elapsed className="tnum" startedAtMs={block.startedAtMs} prefix=" · " />
          </span>
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
