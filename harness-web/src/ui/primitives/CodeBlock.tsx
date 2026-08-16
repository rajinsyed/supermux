import { useMemo, useState } from "react";
import { useCopy } from "../CopyContext";
import { Wrap } from "../Icons";
import { highlightToHtml } from "../highlight";
import { CopyButton } from "./CopyButton";

interface CodeBlockProps {
  code: string;
  language?: string;
  filename?: string;
  streaming?: boolean;
  maxLines?: number;
  dense?: boolean;
}

export function CodeBlock({
  code,
  language,
  filename,
  streaming = false,
  maxLines,
  dense = false
}: CodeBlockProps) {
  const copy = useCopy();
  const [wrap, setWrap] = useState(false);
  const [expanded, setExpanded] = useState(false);

  const body = code.replace(/\n$/, "");
  const lines = body.split("\n");
  const limit = maxLines ?? 0;
  const clipped = limit > 0 && !expanded && lines.length > limit;
  const shown = clipped ? lines.slice(0, limit).join("\n") : body;

  const html = useMemo(
    () => highlightToHtml(shown, language, !streaming),
    [shown, language, streaming]
  );

  const chip = filename ?? (language && language !== "plaintext" ? language : undefined);

  return (
    <div className={`code-block${dense ? " is-dense" : ""}`}>
      <div className="code-block-head">
        <span className="code-chip mono">{chip ?? "text"}</span>
        <span className="code-block-spacer" />
        <button
          type="button"
          className={`icon-btn${wrap ? " is-on" : ""}`}
          onClick={() => setWrap((v) => !v)}
          title={copy("supermux.harness.tool.wrap")}
          aria-pressed={wrap}
        >
          <Wrap size={12} />
        </button>
        <CopyButton text={body} />
      </div>
      <pre className={`code-block-body${wrap ? " is-wrapped" : ""}`}>
        <code className="hljs" dangerouslySetInnerHTML={{ __html: html }} />
      </pre>
      {clipped ? (
        <button type="button" className="code-block-more" onClick={() => setExpanded(true)}>
          {copy("supermux.harness.tool.showMore", { count: lines.length - limit })}
        </button>
      ) : null}
      {limit > 0 && expanded && lines.length > limit ? (
        <button type="button" className="code-block-more" onClick={() => setExpanded(false)}>
          {copy("supermux.harness.tool.showLess")}
        </button>
      ) : null}
    </div>
  );
}
