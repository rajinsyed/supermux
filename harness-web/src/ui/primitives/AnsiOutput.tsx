import { useMemo, useState } from "react";
import { useCopy } from "../CopyContext";
import { parseAnsi, stripAnsi } from "../ansi";
import { CopyButton } from "./CopyButton";

export function AnsiOutput({
  text,
  maxLines = 12,
  tone = "default",
  wrap = false
}: {
  text: string;
  maxLines?: number;
  tone?: "default" | "error";
  /**
   * Prose output — a failure message, not a rendered layout — wraps instead of
   * scrolling sideways. A one-line ENOENT naming a 90-character path is exactly
   * the string the reader opened the card for, and `pre` puts its second half
   * behind a horizontal scrollbar. Structured output (aligned compiler
   * diagnostics, tables) keeps `pre`, where a wrap would shear the columns.
   */
  wrap?: boolean;
}) {
  const copy = useCopy();
  const [expanded, setExpanded] = useState(false);
  const lines = useMemo(() => parseAnsi(text.replace(/\n+$/, "")), [text]);
  const clipped = !expanded && lines.length > maxLines;
  const shown = clipped ? lines.slice(0, maxLines) : lines;
  const plain = useMemo(() => stripAnsi(text), [text]);

  if (text.trim().length === 0) {
    return <div className="terminal is-empty mono">{copy("supermux.harness.tool.noOutput")}</div>;
  }

  return (
    <div className={`terminal${tone === "error" ? " is-error" : ""}`}>
      <div className="terminal-copy">
        <CopyButton text={plain} />
      </div>
      <pre className={`terminal-body mono${wrap ? " is-wrapped" : ""}`}>
        {shown.map((line, i) => (
          <div key={i} className="terminal-line">
            {line.spans.length === 0 ? (
              <span>&nbsp;</span>
            ) : (
              line.spans.map((span, j) => (
                <span key={j} className={span.className} style={span.style}>
                  {span.text}
                </span>
              ))
            )}
          </div>
        ))}
      </pre>
      {lines.length > maxLines ? (
        <button type="button" className="terminal-more" onClick={() => setExpanded((v) => !v)}>
          {expanded
            ? copy("supermux.harness.tool.showLess")
            : copy("supermux.harness.tool.showMore", { count: lines.length - maxLines })}
        </button>
      ) : null}
    </div>
  );
}
