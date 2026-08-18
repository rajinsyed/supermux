import { memo, useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { getBridge } from "../../bridge";
import type { CopyKey } from "../../copyKeys";
import type { DockRow } from "../../model/dock";
import { plural, useCopy } from "../CopyContext";
import { ChevronDown, ChevronRight, Close, Stop } from "../Icons";
import { Disclosure } from "../primitives/Disclosure";
import { WorkingGlyph } from "../primitives/Spinner";
import type { HarnessView } from "../views/viewStack";
import { viewKey } from "../views/viewStack";

const UNTITLED: Record<DockRow["kind"], CopyKey> = {
  main: "supermux.harness.dock.untitledAgent",
  agent: "supermux.harness.dock.untitledAgent",
  workflow: "supermux.harness.dock.untitledWorkflow",
  shell: "supermux.harness.dock.untitledShell"
};

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
  // ONE dim phrase after the name — what the work is doing right now. Never a
  // status word (everything here is running by construction), never a pile of
  // metric chips: the panel is a glance, and the drill-in has the numbers.
  const activity =
    row.kind === "workflow" && row.agentsTotal !== undefined && row.agentsTotal > 0
      ? copy("supermux.harness.dock.workflowAgents", {
          done: row.agentsDone ?? 0,
          total: row.agentsTotal
        })
      : row.detail;

  const stop = (event: React.MouseEvent) => {
    event.stopPropagation();
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
      className={`dock-row is-${row.kind}${active ? " is-active" : ""}`}
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
        <WorkingGlyph />
        <span className="dock-label" title={label}>
          {label}
        </span>
        {/* The reference row is name + one dim phrase and NOTHING on the
            right: no timer, no counters. The drill-in has the numbers. */}
        {activity ? (
          <span className="dock-detail" title={activity}>
            {activity}
          </span>
        ) : null}
        <span className="dock-spacer" />
      </button>
      {row.stopTaskId ? (
        <button
          type="button"
          className="dock-stop"
          onClick={stop}
          disabled={busy}
          tabIndex={-1}
          title={busy ? copy("supermux.harness.dock.stopping") : copy("supermux.harness.dock.stop")}
          aria-label={copy("supermux.harness.dock.stop")}
        >
          <Stop size={9} />
        </button>
      ) : null}
      {failed ? <span className="dock-error">{copy("supermux.harness.dock.stopFailed")}</span> : null}
    </li>
  );
});

/**
 * The working panel: Cursor's "2 Working · Stop All · ✕" glass island above
 * the composer.
 *
 * It lists ONLY working subagents, workflows, and shells — main is not a row
 * (the way back to the main chat is the framed view's own close, and a row for
 * "the conversation you are already in" was chrome). Nested agents indent
 * under their parent; a row is REMOVED the instant its work is terminal.
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
  /** The ✕: the panel stays hidden until the SET of work changes again. */
  const [dismissedKey, setDismissedKey] = useState<string | undefined>(undefined);
  const refs = useRef<(HTMLButtonElement | null)[]>([]);
  const listRef = useRef<HTMLUListElement>(null);

  const work = rows.filter((row) => row.kind !== "main");
  const setKey = work.map((row) => row.id).join("|");
  const stoppable = work.filter((row) => row.stopTaskId !== undefined);
  const clamped = Math.min(focusIndex, Math.max(0, work.length - 1));

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
        focusRow(Math.min(work.length - 1, clamped + 1));
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
        focusRow(work.length - 1);
        return;
      }
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        const row = work[clamped];
        if (row) onOpen(row.view);
      }
      // Escape is deliberately NOT handled here: it belongs to the view stack,
      // which pops one level per press wherever focus happens to be.
    },
    [clamped, focusRow, onOpen, work]
  );

  /**
   * Was the reader's focus IN the panel, recorded as it happens. It cannot be
   * read back after the fact: removing the focused element resets
   * `document.activeElement` to the body, so by the time the effect below runs,
   * the one row that could prove the reader was here is exactly the row that
   * is gone.
   */
  const hadFocus = useRef(false);

  /**
   * Rows VANISH under the reader — an agent finishing removes its row — so the
   * roving tabstop has to survive its own row disappearing. The index is
   * clamped back into range, and DOM focus moves to the row that took its
   * place — but only when focus WAS in the panel. Stealing it from the
   * composer because a shell finished would eat the next typed character.
   */
  useLayoutEffect(() => {
    refs.current.length = work.length;
    if (focusIndex === clamped) return;
    setFocusIndex(clamped);
    if (hadFocus.current) refs.current[clamped]?.focus();
  }, [clamped, focusIndex, work.length]);

  // A row the reader has just opened is scrolled into the panel's own
  // viewport: the list is height-capped, and an agent selected from the chat
  // could otherwise be highlighted entirely below the fold.
  const activeKey = viewKey(activeView);
  useEffect(() => {
    const list = listRef.current;
    if (!list || !open) return;
    const index = work.findIndex((row) => viewKey(row.view) === activeKey);
    if (index < 0) return;
    const node = list.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(work[index].id)}"]`);
    node?.scrollIntoView({ block: "nearest" });
  }, [activeKey, open, work]);

  // Nothing is working, so there is nothing to dock — and a dismissal holds
  // until the set of work changes (new work re-announces itself).
  if (work.length === 0) return null;
  if (dismissedKey === setKey) return null;

  return (
    <div className="agents-dock" role="region" aria-label={copy("supermux.harness.dock.a11y")}>
      <div className="agents-dock-head">
        <button
          type="button"
          className="agents-dock-fold"
          onClick={() => setOpen((value) => !value)}
          aria-expanded={open}
          aria-label={
            open ? copy("supermux.harness.dock.collapse") : copy("supermux.harness.dock.expand")
          }
        >
          {open ? <ChevronDown size={11} /> : <ChevronRight size={11} />}
          <span className="agents-dock-title">
            {plural(
              copy,
              work.length,
              "supermux.harness.dock.workingOne",
              "supermux.harness.dock.working"
            )}
          </span>
        </button>
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
        <button
          type="button"
          className="agents-dock-close"
          onClick={() => setDismissedKey(setKey)}
          aria-label={copy("supermux.harness.banner.dismiss")}
        >
          <Close size={11} />
        </button>
      </div>
      <Disclosure open={open}>
        <ul
          className="agents-dock-list"
          ref={listRef}
          role="listbox"
          tabIndex={-1}
          aria-label={copy("supermux.harness.dock.title")}
          onKeyDown={onKeyDown}
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
          {work.map((row, index) => (
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
