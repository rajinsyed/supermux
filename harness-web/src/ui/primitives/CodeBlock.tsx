import { useId, useMemo } from "react";
import { plural, useCopy } from "../CopyContext";
import { Wrap } from "../Icons";
import { escapeHtml, highlightToHtml } from "../highlight";
import { usePresentationState } from "../presentationState";
import { clipUtf8, lineCount } from "../utf8";
import { CopyButton } from "./CopyButton";

const PREVIEW_BYTES = 24 * 1024;
let maxScannedCodeUnitsPerRender = 0;

/** Neutral performance observation used by the streaming fence regression. */
export function codePreviewDiagnostics(): { maxScannedCodeUnitsPerRender: number } {
  return { maxScannedCodeUnitsPerRender };
}

export function resetCodePreviewDiagnostics(): void {
  maxScannedCodeUnitsPerRender = 0;
}

interface CodeBlockProps {
  code: string;
  language?: string;
  filename?: string;
  streaming?: boolean;
  maxLines?: number;
  dense?: boolean;
  /** Stable transcript identity used to restore reader state after unmount. */
  stateKey?: string;
}

export function CodeBlock({
  code,
  language,
  filename,
  streaming = false,
  maxLines,
  dense = false,
  stateKey
}: CodeBlockProps) {
  const copy = useCopy();
  const localId = useId();
  const rootKey = stateKey ?? `code:${localId}`;
  const [wrap, setWrap] = usePresentationState(`${rootKey}:wrap`, false);
  const [expanded, setExpanded] = usePresentationState(`${rootKey}:expanded`, false);

  const body = code.endsWith("\r\n")
    ? code.slice(0, -2)
    : code.endsWith("\r") || code.endsWith("\n")
      ? code.slice(0, -1)
      : code;
  const limit = maxLines ?? 0;
  const preview = useMemo(() => codePreview(body, limit), [body, limit]);
  const totalLines = useMemo(
    () =>
      streaming && preview.truncated && !expanded
        ? lineCount(preview.text) + 1
        : lineCount(body),
    [body, expanded, preview, streaming]
  );
  const clipped = !expanded && preview.truncated;
  const shown = clipped ? preview.text : body;

  const html = useMemo(
    // A mutable fence is re-rendered for every streamed fragment. Escaping the
    // bounded preview is linear and exact; syntax highlighting waits until the
    // fence settles so Highlight.js never reparses the growing prefix.
    () => (streaming ? escapeHtml(shown) : highlightToHtml(shown, language)),
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
          onClick={() => setWrap((value) => !value)}
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
      {preview.truncated ? (
        <button type="button" className="code-block-more" onClick={() => setExpanded((value) => !value)}>
          {expanded
            ? copy("supermux.harness.tool.showLess")
            : plural(
                copy,
                Math.max(1, totalLines - lineCount(preview.text)),
                "supermux.harness.tool.showMoreOne",
                "supermux.harness.tool.showMore"
              )}
        </button>
      ) : null}
    </div>
  );
}

function codePreview(body: string, maxLines: number): { text: string; truncated: boolean } {
  maxScannedCodeUnitsPerRender = Math.max(
    maxScannedCodeUnitsPerRender,
    Math.min(body.length, PREVIEW_BYTES + 1)
  );
  const bytePreview = clipUtf8(body, PREVIEW_BYTES);
  if (maxLines <= 0) return bytePreview;
  const lines = bytePreview.text.split("\n");
  const lineTruncated = lines.length > maxLines;
  return {
    text: lineTruncated ? lines.slice(0, maxLines).join("\n") : bytePreview.text,
    truncated: bytePreview.truncated || lineTruncated
  };
}
