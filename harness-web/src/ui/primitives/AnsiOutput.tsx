import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { useCopy } from "../CopyContext";
import { parseAnsi, stripAnsi } from "../ansi";
import { usePresentationState } from "../presentationState";
import { clipAnsiUtf8, lineCount } from "../utf8";
import { CopyButton } from "./CopyButton";

const PREVIEW_BYTES = 24 * 1024;

export function AnsiOutput({
  text,
  maxLines = 12,
  tone = "default",
  wrap = false,
  stateKey,
  streaming = false
}: {
  text: string;
  maxLines?: number;
  tone?: "default" | "error";
  /**
   * Prose output — a failure message, not a rendered layout — wraps instead of
   * scrolling sideways. Structured output keeps `pre`, where wrapping would
   * shear aligned diagnostics and tables.
   */
  wrap?: boolean;
  /** Stable transcript identity used to restore expansion after unmount. */
  stateKey?: string;
  /** The payload is still appending; line accounting stays preview-bounded. */
  streaming?: boolean;
}) {
  const copy = useCopy();
  const localId = useId();
  const [expanded, setExpanded] = usePresentationState(
    `${stateKey ?? `ansi:${localId}`}:expanded`,
    false
  );
  const normalized = text.replace(/\n+$/, "");
  const preview = useMemo(() => clipAnsiUtf8(normalized, PREVIEW_BYTES), [normalized]);
  const totalLines = useMemo(
    () =>
      streaming && preview.truncated
        ? lineCount(preview.text) + 1
        : lineCount(normalized),
    [normalized, preview, streaming]
  );
  const source = expanded ? normalized : preview.text;
  const parsed = useMemo(
    () => parseAnsi(source, expanded ? Number.MAX_SAFE_INTEGER : maxLines + 1),
    [expanded, maxLines, source]
  );
  const lineClipped = !expanded && parsed.length > maxLines;
  const shown = lineClipped ? parsed.slice(0, maxLines) : parsed;
  const truncated = preview.truncated || totalLines > maxLines;
  const copyText = useCallback(() => stripAnsi(text), [text]);

  const body = useRef<HTMLPreElement>(null);
  const [clippedEnd, setClippedEnd] = useState(false);

  useEffect(() => {
    const node = body.current;
    if (!node || wrap) {
      setClippedEnd(false);
      return;
    }
    const measure = () => {
      setClippedEnd(node.scrollLeft + node.clientWidth < node.scrollWidth - 2);
    };
    measure();
    node.addEventListener("scroll", measure, { passive: true });
    const observer =
      typeof ResizeObserver !== "undefined" ? new ResizeObserver(measure) : undefined;
    observer?.observe(node);
    return () => {
      node.removeEventListener("scroll", measure);
      observer?.disconnect();
    };
  }, [text, wrap, expanded]);

  if (text.trim().length === 0) {
    return <div className="terminal is-empty mono">{copy("supermux.harness.tool.noOutput")}</div>;
  }

  return (
    <div className={`terminal${tone === "error" ? " is-error" : ""}`}>
      <div className="terminal-copy">
        <CopyButton text={copyText} />
      </div>
      <pre
        className={`terminal-body mono${wrap ? " is-wrapped" : ""}${clippedEnd ? " is-clipped-end" : ""}`}
        ref={body}
      >
        {shown.map((line, lineIndex) => (
          <div key={lineIndex} className="terminal-line">
            {line.spans.length === 0 ? (
              <span>&nbsp;</span>
            ) : (
              line.spans.map((span, spanIndex) => (
                <span key={spanIndex} className={span.className} style={span.style}>
                  {span.text}
                </span>
              ))
            )}
          </div>
        ))}
      </pre>
      {truncated ? (
        <button type="button" className="terminal-more" onClick={() => setExpanded((value) => !value)}>
          {expanded
            ? copy("supermux.harness.tool.showLess")
            : copy("supermux.harness.tool.showMore", {
                count: Math.max(1, totalLines - maxLines)
              })}
        </button>
      ) : null}
    </div>
  );
}
