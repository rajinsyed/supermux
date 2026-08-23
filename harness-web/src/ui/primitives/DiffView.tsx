import { useId, useMemo } from "react";
import type { StructuredPatchHunk } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { highlightToHtml } from "../highlight";
import { usePresentationState } from "../presentationState";
import { clipUtf8, utf8ByteLength } from "../utf8";

const PREVIEW_BYTES = 24 * 1024;

interface DiffRow {
  kind: "add" | "del" | "ctx" | "gap";
  text: string;
  oldNo?: number;
  newNo?: number;
}

interface DiffRows {
  rows: DiffRow[];
  total: number;
  truncated: boolean;
}

function buildRows(
  hunks: StructuredPatchHunk[],
  limitRows: number | undefined,
  limitBytes: number | undefined
): DiffRows {
  const rows: DiffRow[] = [];
  let total = 0;
  let bytes = 0;
  let truncated = false;

  const append = (row: DiffRow) => {
    total += 1;
    if (limitRows !== undefined && rows.length >= limitRows) {
      truncated = true;
      return;
    }
    if (row.kind === "gap") {
      rows.push(row);
      return;
    }
    if (limitBytes === undefined) {
      rows.push(row);
      return;
    }
    const remaining = Math.max(0, limitBytes - bytes);
    const clipped = clipUtf8(row.text, remaining);
    if (remaining === 0 && row.text.length > 0) {
      truncated = true;
      return;
    }
    rows.push({ ...row, text: clipped.text });
    bytes += utf8ByteLength(clipped.text);
    if (clipped.truncated) truncated = true;
  };

  hunks.forEach((hunk, hunkIndex) => {
    if (hunkIndex > 0) append({ kind: "gap", text: "" });
    let oldNo = hunk.oldStart;
    let newNo = hunk.newStart;
    for (const line of hunk.lines ?? []) {
      const marker = line.charAt(0);
      const text = line.slice(1);
      if (marker === "+") {
        append({ kind: "add", text, newNo });
        newNo += 1;
      } else if (marker === "-") {
        append({ kind: "del", text, oldNo });
        oldNo += 1;
      } else {
        append({ kind: "ctx", text, oldNo, newNo });
        oldNo += 1;
        newNo += 1;
      }
    }
  });
  return { rows, total, truncated };
}

export function diffStats(hunks: StructuredPatchHunk[]): { added: number; removed: number } {
  let added = 0;
  let removed = 0;
  for (const hunk of hunks) {
    for (const line of hunk.lines ?? []) {
      if (line.startsWith("+")) added += 1;
      else if (line.startsWith("-")) removed += 1;
    }
  }
  return { added, removed };
}

export function DiffView({
  hunks,
  language,
  maxRows = 22,
  stateKey
}: {
  hunks: StructuredPatchHunk[];
  language?: string;
  maxRows?: number;
  /** Stable transcript identity used to restore expansion after unmount. */
  stateKey?: string;
}) {
  const copy = useCopy();
  const localId = useId();
  const [expanded, setExpanded] = usePresentationState(
    `${stateKey ?? `diff:${localId}`}:expanded`,
    false
  );
  // Build only the bounded preview until the reader explicitly asks for all rows.
  const preview = useMemo(() => buildRows(hunks, maxRows, PREVIEW_BYTES), [hunks, maxRows]);
  const result = useMemo(
    () => (expanded ? buildRows(hunks, undefined, undefined) : preview),
    [expanded, hunks, preview]
  );

  return (
    <div className="diff">
      <div className="diff-body">
        {result.rows.map((row, index) => {
          if (row.kind === "gap") return <div key={index} className="diff-gap" />;
          const html = highlightToHtml(row.text, language);
          return (
            <div key={index} className={`diff-row is-${row.kind}`}>
              <span className="diff-no tnum">{row.oldNo ?? ""}</span>
              <span className="diff-no tnum">{row.newNo ?? ""}</span>
              <span className="diff-mark">
                {row.kind === "add" ? "+" : row.kind === "del" ? "−" : " "}
              </span>
              <code className="diff-text hljs" dangerouslySetInnerHTML={{ __html: html || "&nbsp;" }} />
            </div>
          );
        })}
      </div>
      {preview.truncated ? (
        <button type="button" className="diff-more" onClick={() => setExpanded((value) => !value)}>
          {expanded
            ? copy("supermux.harness.tool.showLess")
            : copy("supermux.harness.tool.showMore", {
                count: Math.max(1, preview.total - preview.rows.length)
              })}
        </button>
      ) : null}
    </div>
  );
}
