import { useMemo, useState } from "react";
import type { StructuredPatchHunk } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { highlightToHtml } from "../highlight";

interface DiffRow {
  kind: "add" | "del" | "ctx" | "gap";
  text: string;
  oldNo?: number;
  newNo?: number;
}

function buildRows(hunks: StructuredPatchHunk[]): DiffRow[] {
  const rows: DiffRow[] = [];
  hunks.forEach((hunk, hunkIndex) => {
    if (hunkIndex > 0) rows.push({ kind: "gap", text: "" });
    let oldNo = hunk.oldStart;
    let newNo = hunk.newStart;
    for (const line of hunk.lines ?? []) {
      const marker = line.charAt(0);
      const text = line.slice(1);
      if (marker === "+") {
        rows.push({ kind: "add", text, newNo });
        newNo += 1;
      } else if (marker === "-") {
        rows.push({ kind: "del", text, oldNo });
        oldNo += 1;
      } else {
        rows.push({ kind: "ctx", text, oldNo, newNo });
        oldNo += 1;
        newNo += 1;
      }
    }
  });
  return rows;
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
  maxRows = 22
}: {
  hunks: StructuredPatchHunk[];
  language?: string;
  maxRows?: number;
}) {
  const copy = useCopy();
  const [expanded, setExpanded] = useState(false);
  const rows = useMemo(() => buildRows(hunks), [hunks]);
  const clipped = !expanded && rows.length > maxRows;
  const shown = clipped ? rows.slice(0, maxRows) : rows;

  return (
    <div className="diff">
      <div className="diff-body">
        {shown.map((row, i) => {
          if (row.kind === "gap") return <div key={i} className="diff-gap" />;
          const html = highlightToHtml(row.text, language);
          return (
            <div key={i} className={`diff-row is-${row.kind}`}>
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
      {rows.length > maxRows ? (
        <button type="button" className="diff-more" onClick={() => setExpanded((v) => !v)}>
          {expanded
            ? copy("supermux.harness.tool.showLess")
            : copy("supermux.harness.tool.showMore", { count: rows.length - maxRows })}
        </button>
      ) : null}
    </div>
  );
}
