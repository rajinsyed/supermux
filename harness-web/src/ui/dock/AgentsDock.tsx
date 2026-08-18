import { memo, useCallback, useEffect, useRef, useState } from "react";
import { getBridge } from "../../bridge";
import type { CopyKey } from "../../copyKeys";
import type { DockRow } from "../../model/dock";
import { plural, useCopy } from "../CopyContext";
import { ChevronDown, ChevronRight, Layers, Map as MapIcon, Sparkle, Stop, Terminal } from "../Icons";
import { formatTokens } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
import { formatCompactDuration } from "../format";
import type { HarnessView } from "../views/viewStack";
import { viewKey } from "../views/viewStack";

const UNTITLED: Record<DockRow["kind"], CopyKey> = {
  main: "supermux.harness.dock.main",
  agent: "supermux.harness.dock.untitledAgent",
  workflow: "supermux.harness.dock.untitledWorkflow",
  shell: "supermux.harness.dock.untitledShell"
};

function RowIcon({ kind }: { kind: DockRow["kind"] }) {
  if (kind === "main") return <Sparkle size={11} />;
  if (kind === "workflow") return <MapIcon size={11} />;
  if (kind === "shell") return <Terminal size={11} />;
  return <Layers size={11} />;
}

/**
 * The row's outcome as one word, from the catalog.
 *
 * The wire's status tokens are lowercase protocol vocabulary and an
 * unrecognised one (a future `paused`) must degrade rather than leak: a dimmed
 * row that says "Done" when the CLI said something else is worse than one that
 * says nothing.
 */
function statusKey(row: DockRow): CopyKey | undefined {
  if (row.running) {
    return row.kind === "main"
      ? "supermux.harness.dock.statusRunning"
      : "supermux.harness.dock.statusRunning";
  }
  if (row.status === "failed") return "supermux.harness.dock.statusFailed";
  if (row.status === "killed" || row.status === "stopped") return "supermux.harness.dock.statusStopped";
  if (row.status === "completed") return "supermux.harness.dock.statusDone";
  if (row.kind === "main") return "supermux.harness.dock.statusIdle";
  return undefined;
}

function dotClass(row: DockRow): string {
  if (row.running) return "is-running";
  if (row.status === "failed") return "is-error";
  if (row.status === "killed" || row.status === "stopped") return "is-stopped";
  return "is-done";
}

const DockRowView = memo(function DockRowView({
  row,
  active,
  focused,
  onOpen,
  registerRef
}: {
  row: DockRow;
  active: boolean;
  focused: boolean;
  onOpen(view: HarnessView): void;
  registerRef(node: HTMLButtonElement | null): void;
}) {
  const copy = useCopy();
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);

  const label = row.label.trim().length > 0 ? row.label : copy(UNTITLED[row.kind]);
  const state = statusKey(row);
  const metrics: string[] = [];
  if (row.agentsTotal !== undefined && row.agentsTotal > 0) {
    metrics.push(
      copy("supermux.harness.dock.workflowAgents", {
        done: row.agentsDone ?? 0,
        total: row.agentsTotal
      })
    );
  }
  if (row.totalTokens) {
    metrics.push(copy("supermux.harness.subagent.tokens", { tokens: formatTokens(row.totalTokens) }));
  }
  // A settled row's elapsed is FROZEN at what the work took. A live `Elapsed`
  // left on a finished agent keeps counting, which is the dock claiming the
  // work is still going — the one thing a persisted row must never imply.
  const settledFor =
    !row.running && row.startedAtMs !== undefined && row.endedAtMs !== undefined
      ? formatCompactDuration(row.endedAtMs - row.startedAtMs, copy)
      : undefined;

  const stop = () => {
    if (!row.stopTaskId) return;
    setBusy(true);
    setFailed(false);
    getBridge()
      .stopTask({ taskId: row.stopTaskId })
      .catch(() => setFailed(true))
      .finally(() => setBusy(false));
  };

  return (
    <li
      className={`dock-row is-${row.kind}${row.running ? " is-running" : " is-settled"}${
        active ? " is-active" : ""
      }`}
      data-depth={Math.min(row.depth, 4)}
      data-row-id={row.id}
    >
      <button
        type="button"
        className="dock-row-open"
        ref={registerRef}
        // One roving tabstop for the whole list, which is what makes ↑↓ the way
        // through it rather than Tab pressed eleven times.
        tabIndex={focused ? 0 : -1}
        aria-current={active ? "true" : undefined}
        onClick={() => onOpen(row.view)}
      >
        {/* The tree guide, drawn only for a nested agent. A `└` on a top-level
            row would claim a parent it does not have. */}
        {row.depth > 1 ? <span className="dock-guide" aria-hidden="true" /> : null}
        <span className={`dock-dot ${dotClass(row)}`} aria-hidden="true" />
        <span className="dock-icon" aria-hidden="true">
          <RowIcon kind={row.kind} />
        </span>
        <span className="dock-label" title={label}>
          {label}
        </span>
        {row.kind === "main" ? (
          <span className="dock-detail">{copy("supermux.harness.dock.mainHint")}</span>
        ) : row.detail ? (
          <span className="dock-detail" title={row.detail}>
            {row.detail}
          </span>
        ) : null}
        <span className="dock-spacer" />
        {metrics.length > 0 ? <span className="dock-metrics tnum">{metrics.join(" · ")}</span> : null}
        {row.running && row.startedAtMs !== undefined ? (
          <Elapsed className="dock-elapsed tnum" startedAtMs={row.startedAtMs} />
        ) : settledFor ? (
          <span className="dock-elapsed tnum">{settledFor}</span>
        ) : null}
        {state ? <span className="dock-state">{copy(state)}</span> : null}
      </button>
      {row.stopTaskId ? (
        <button
          type="button"
          className="btn btn-quiet is-danger dock-stop"
          onClick={stop}
          disabled={busy}
          tabIndex={-1}
        >
          <Stop size={10} />
          {busy ? copy("supermux.harness.dock.stopping") : copy("supermux.harness.dock.stop")}
        </button>
      ) : null}
      {failed ? <span className="dock-error">{copy("supermux.harness.dock.stopFailed")}</span> : null}
    </li>
  );
});

/**
 * The CLI's agents dock, above the composer.
 *
 * Rows are `main` first, then agents in tree order (nested ones indented under
 * their parent), then workflows and shells. Every row PERSISTS for the session
 * once it has appeared — the CLI's own behaviour, and the reason the round-3
 * strip was wrong: an agent that finished thirty seconds ago is precisely what
 * a user goes looking for.
 */
export const AgentsDock = memo(function AgentsDock({
  rows,
  activeView,
  onOpen
}: {
  rows: DockRow[];
  activeView: HarnessView;
  onOpen(view: HarnessView): void;
}) {
  const copy = useCopy();
  const [open, setOpen] = useState(true);
  const [focusIndex, setFocusIndex] = useState(0);
  const refs = useRef<(HTMLButtonElement | null)[]>([]);
  const listRef = useRef<HTMLUListElement>(null);

  const agentCount = rows.filter((row) => row.kind !== "main").length;
  const clamped = Math.min(focusIndex, Math.max(0, rows.length - 1));

  const focusRow = useCallback((index: number) => {
    setFocusIndex(index);
    refs.current[index]?.focus();
  }, []);

  const onKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLUListElement>) => {
      if (event.key === "ArrowDown") {
        event.preventDefault();
        focusRow(Math.min(rows.length - 1, clamped + 1));
        return;
      }
      if (event.key === "ArrowUp") {
        event.preventDefault();
        focusRow(Math.max(0, clamped - 1));
        return;
      }
      if (event.key === "Home") {
        event.preventDefault();
        focusRow(0);
        return;
      }
      if (event.key === "End") {
        event.preventDefault();
        focusRow(rows.length - 1);
        return;
      }
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        const row = rows[clamped];
        if (row) onOpen(row.view);
      }
      // Escape is deliberately NOT handled here: it belongs to the view stack,
      // which pops one level per press wherever focus happens to be. Swallowing
      // it in the dock would make esc mean two different things depending on
      // whether a row had focus.
    },
    [clamped, focusRow, onOpen, rows]
  );

  useEffect(() => {
    refs.current.length = rows.length;
  }, [rows.length]);

  // A row the reader has just opened is scrolled into the dock's own viewport:
  // the list is height-capped past ~4 rows, and an agent selected from the chat
  // could otherwise be highlighted entirely below the fold.
  const activeKey = viewKey(activeView);
  useEffect(() => {
    const list = listRef.current;
    if (!list || !open) return;
    const index = rows.findIndex((row) => viewKey(row.view) === activeKey);
    if (index < 0) return;
    const node = list.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(rows[index].id)}"]`);
    node?.scrollIntoView({ block: "nearest" });
  }, [activeKey, open, rows]);

  if (rows.length <= 1) return null;

  return (
    <div className="agents-dock">
      <button
        type="button"
        className="agents-dock-head"
        onClick={() => setOpen((value) => !value)}
        aria-expanded={open}
      >
        {open ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
        <span className="agents-dock-title">{copy("supermux.harness.dock.title")}</span>
        <span className="agents-dock-count tnum">
          {plural(copy, agentCount, "supermux.harness.dock.countOne", "supermux.harness.dock.count")}
        </span>
        <span className="agents-dock-hint">{copy("supermux.harness.dock.keyHint")}</span>
        <span className="sr-only">
          {open ? copy("supermux.harness.dock.collapse") : copy("supermux.harness.dock.expand")}
        </span>
      </button>
      <Disclosure open={open}>
        <ul
          className="agents-dock-list"
          ref={listRef}
          role="listbox"
          tabIndex={-1}
          aria-label={copy("supermux.harness.dock.a11y")}
          onKeyDown={onKeyDown}
        >
          {rows.map((row, index) => (
            <DockRowView
              key={row.id}
              row={row}
              active={viewKey(row.view) === activeKey}
              focused={index === clamped}
              onOpen={onOpen}
              registerRef={(node) => {
                refs.current[index] = node;
              }}
            />
          ))}
        </ul>
      </Disclosure>
    </div>
  );
});
