import { memo, useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { getBridge } from "../../bridge";
import type { CopyKey } from "../../copyKeys";
import type { DockRow } from "../../model/dock";
import { plural, useCopy } from "../CopyContext";
import { ChevronDown, ChevronRight, Layers, Map as MapIcon, Sparkle, Stop, Terminal } from "../Icons";
import { formatTokens } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
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
 * The row's state as one word.
 *
 * Every non-main row in the panel is RUNNING by construction — the model drops
 * a row the moment its work is terminal — so there is no settled vocabulary
 * here any more. Main is the exception: it stays whether or not a turn is in
 * flight, and Idle is what it says when nothing is.
 */
function statusKey(row: DockRow): CopyKey | undefined {
  if (row.running) return "supermux.harness.dock.statusRunning";
  return row.kind === "main" ? "supermux.harness.dock.statusIdle" : undefined;
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
            row would claim a parent it does not have — and depth is counted
            over VISIBLE ancestors, so a child whose parent finished is promoted
            rather than left hanging off a row that is gone. */}
        {row.depth > 1 ? <span className="dock-guide" aria-hidden="true" /> : null}
        <span className={`dock-dot ${row.running ? "is-running" : "is-done"}`} aria-hidden="true" />
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
 * The working panel: Cursor's "3 Working · Stop All" glass island above the
 * composer.
 *
 * Rows are `main` first, then running agents in tree order (nested ones
 * indented under their parent), then running workflows and shells. A row is
 * REMOVED the instant its work is terminal: the panel says what is happening
 * now, and the transcript's own compact agent/workflow rows are where finished
 * work is read.
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
  const [stoppingAll, setStoppingAll] = useState(false);
  const refs = useRef<(HTMLButtonElement | null)[]>([]);
  const listRef = useRef<HTMLUListElement>(null);

  const workingCount = rows.filter((row) => row.kind !== "main" && row.running).length;
  const stoppable = rows.filter((row) => row.stopTaskId !== undefined);
  const clamped = Math.min(focusIndex, Math.max(0, rows.length - 1));

  const stopAll = useCallback(() => {
    if (stoppable.length === 0) return;
    setStoppingAll(true);
    void Promise.allSettled(
      stoppable.map((row) => getBridge().stopTask({ taskId: row.stopTaskId as string }))
    ).finally(() => setStoppingAll(false));
  }, [stoppable]);

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
      // it in the panel would make esc mean two different things depending on
      // whether a row had focus.
    },
    [clamped, focusRow, onOpen, rows]
  );

  /**
   * Was the reader's focus IN the panel, recorded as it happens.
   *
   * It cannot be read back after the fact: removing the focused element resets
   * `document.activeElement` to the body, so by the time the effect below runs,
   * the one row that could prove the reader was in the panel is exactly the row
   * that is gone. Answering "is focus in the panel" from the body would decline
   * to restore in precisely the case restoration exists for.
   */
  const hadFocus = useRef(false);

  /**
   * Rows VANISH under the reader — an agent finishing removes its row — so the
   * roving tabstop has to survive its own row disappearing.
   *
   * Two halves. The index is clamped back into range (above) so the walker
   * never points past the end, and DOM focus is moved to the row that took its
   * place — but only when the focus WAS in the panel. Stealing focus from the
   * composer because a background shell happened to finish would eat the next
   * character the user typed, which is the far worse failure.
   */
  useLayoutEffect(() => {
    refs.current.length = rows.length;
    if (focusIndex === clamped) return;
    setFocusIndex(clamped);
    if (hadFocus.current) refs.current[clamped]?.focus();
  }, [clamped, focusIndex, rows.length]);

  // A row the reader has just opened is scrolled into the panel's own viewport:
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

  // Nothing but main is running, so there is nothing to dock. The empty shell
  // — a header reading "0 working" over an empty list — is chrome that says
  // less than its own absence.
  if (rows.length <= 1) return null;

  return (
    <div className="agents-dock" role="region" aria-label={copy("supermux.harness.dock.a11y")}>
      <div className="agents-dock-head">
        <button
          type="button"
          className="agents-dock-fold icon-btn"
          onClick={() => setOpen((value) => !value)}
          aria-expanded={open}
          aria-label={
            open ? copy("supermux.harness.dock.collapse") : copy("supermux.harness.dock.expand")
          }
        >
          {open ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
        </button>
        <span className="agents-dock-title">
          {plural(
            copy,
            workingCount,
            "supermux.harness.dock.workingOne",
            "supermux.harness.dock.working"
          )}
        </span>
        <span className="agents-dock-spacer" />
        {stoppable.length > 0 ? (
          <button
            type="button"
            className="agents-dock-stopall"
            onClick={stopAll}
            disabled={stoppingAll}
          >
            {stoppingAll
              ? copy("supermux.harness.dock.stopping")
              : copy("supermux.harness.dock.stopAll")}
          </button>
        ) : null}
      </div>
      <Disclosure open={open}>
        <ul
          className="agents-dock-list"
          ref={listRef}
          role="listbox"
          tabIndex={-1}
          aria-label={copy("supermux.harness.dock.title")}
          onKeyDown={onKeyDown}
          // Bubbling focus events, so this is one listener for every row rather
          // than a handler per button — and it stays correct as rows come and go.
          onFocus={() => {
            hadFocus.current = true;
          }}
          onBlur={(event) => {
            // A blur INSIDE the list (row to row) is not leaving the panel, and
            // a blur caused by the focused row being removed reports no
            // relatedTarget at all — which is the case that must keep the flag.
            const next = event.relatedTarget;
            if (next instanceof HTMLElement) {
              hadFocus.current = event.currentTarget.contains(next);
            }
          }}
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
