import { useCallback, useEffect, useRef, useState } from "react";
import type { CopyKey } from "../../copyKeys";
import { resolveModel } from "../../model/helpers";
import type { SessionMeta } from "../../model/types";
import type { EffortLevel, ModelDescriptor } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { ChevronDown, Undo } from "../Icons";
import { MenuEmpty, MenuItem, MenuList, MenuLoading, MenuSection } from "../primitives/MenuList";
import { PopoverSurface, usePopoverKeys } from "../primitives/Popover";
import { Spinner } from "../primitives/Spinner";

/**
 * The model picker, inside the composer pill.
 *
 * A quiet text trigger at the trailing edge of the input — no bed, no icon, just
 * the model's name with its effort folded into the label — opening ONE compact
 * panel upward, built from the shared menu kit so it is the same object as the
 * permission menu and the ••• menu at a different width.
 *
 * Reasoning is a SEGMENTED strip pinned to the panel's foot rather than a strip
 * that opens under whichever row the pointer last touched. Round 4's inline
 * strip made the panel's height jump as the reader moved down the list, and it
 * asked the reader to answer "which model" and "how hard" in two places on one
 * surface. Effort belongs to the ACTIVE model, so it sits once, at the bottom,
 * under a hairline — and it is also where the wheel and Option+,/. land, so
 * there is one visible thing those gestures move.
 */

/**
 * Effort is a per-model capability, so it cannot travel across a model switch
 * unchanged: sending `max` to a model that tops out at `high` makes the CLI
 * reject it while the trigger keeps advertising a setting that does not exist.
 */
export function clampEffort(
  model: ModelDescriptor | undefined,
  effort: EffortLevel | undefined
): EffortLevel | undefined {
  if (!effort || !model?.supportsEffort) return undefined;
  const levels = model.supportedEffortLevels;
  if (!levels || levels.length === 0) return undefined;
  return levels.includes(effort) ? effort : undefined;
}

const EFFORT_LABELS: Record<string, CopyKey> = {
  low: "supermux.harness.effort.low",
  medium: "supermux.harness.effort.medium",
  high: "supermux.harness.effort.high",
  xhigh: "supermux.harness.effort.xhigh",
  max: "supermux.harness.effort.max"
};

/** `xhigh` is a wire token, not a label; every neighbouring row is prose. */
export function effortLabel(level: string, copy: ReturnType<typeof useCopy>): string {
  const key = EFFORT_LABELS[level];
  return key ? copy(key) : level;
}

/**
 * The catalog only reaches a pane through the `initialize` handshake of a
 * RUNNING process, so a pane on first open has `session.models = []` and the
 * model menu used to be blank — no rows, no current model, nothing to pick.
 * Three sources in falling order of authority, and a spinner rather than an
 * empty popup when none of them has answered yet.
 */
export function modelMenuSource(
  session: Pick<SessionMeta, "models">,
  cachedModels: ModelDescriptor[] | undefined
): { models: ModelDescriptor[]; loading: boolean } {
  if (session.models.length > 0) return { models: session.models, loading: false };
  if (cachedModels && cachedModels.length > 0) return { models: cachedModels, loading: false };
  return { models: [], loading: true };
}

const CATALOG_TIMEOUT_MS = 8000;

export function supportsEffort(model: ModelDescriptor | undefined): model is ModelDescriptor {
  return model?.supportsEffort === true && (model.supportedEffortLevels?.length ?? 0) > 0;
}

/**
 * One step along a model's OWN effort scale.
 *
 * The levels are an ordered list on the descriptor, not a global enum, so
 * "one step up" means the next entry in that model's list — a model whose scale
 * is `[low, medium, high]` must not step into `xhigh` because another model has
 * one. Clamped at both ends rather than wrapping: a wheel that rolls `max` back
 * round to `low` is a gesture that can silently downgrade a turn.
 *
 * Returns `undefined` when nothing can move, so callers can skip the round trip
 * entirely rather than re-sending the level that is already set.
 */
export function stepEffort(
  model: ModelDescriptor | undefined,
  current: EffortLevel | undefined,
  delta: number
): EffortLevel | undefined {
  if (!supportsEffort(model)) return undefined;
  const levels = model.supportedEffortLevels ?? [];
  // With no level set, the model's own default is where the scale starts; if it
  // has no default either, an increase enters at the bottom and a decrease at
  // the top, so the first gesture always does something visible.
  const from = clampEffort(model, current) ?? model.defaultEffortLevel;
  const at = from ? levels.indexOf(from) : delta > 0 ? -1 : levels.length;
  const next = Math.max(0, Math.min(levels.length - 1, at + delta));
  if (next === at) return undefined;
  return levels[next];
}

export interface ModelMenuProps {
  session: Pick<SessionMeta, "model" | "models" | "effort">;
  /** Catalog persisted from an earlier run of this binary; see modelMenuSource. */
  cachedModels?: ModelDescriptor[];
  onSetModel(model: string, effort?: EffortLevel): void;
}

export function ModelMenu(props: ModelMenuProps) {
  const copy = useCopy();
  const { session } = props;
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const pop = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const onPopKeyDown = usePopoverKeys(pop);

  const source = modelMenuSource(session, props.cachedModels);
  // ONE resolution for the trigger, the checked row, and the reasoning strip.
  // The live catalog is authoritative when a process is up; before the first
  // start `session.models` is empty and only the cached catalog can resolve
  // anything, so a trigger reading `activeModelFor(session)` alone printed the
  // raw selector the user had just picked ("opus") beside a menu that had an
  // "Opus 5" row checked.
  const activeRow = resolveModel(session, props.cachedModels);
  const modelName = activeRow?.displayName ?? session.model ?? copy("supermux.harness.header.model");
  // The label must never outlive the capability it describes: a model with no
  // effort levels shows no effort word, whatever the session last carried.
  const effort = clampEffort(activeRow, session.effort);

  const close = useCallback((restoreFocus = false) => {
    setOpen(false);
    if (restoreFocus) trigger.current?.focus();
  }, []);

  useEffect(() => {
    if (!open) return;
    const onDown = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) close();
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.stopPropagation();
      close(true);
    };
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey, true);
    };
  }, [close, open]);

  // The CHECKED row takes focus on open, so ↑↓ walk the list immediately without
  // the keystroke falling through to the composer behind the panel — and the
  // focus ring lands on the model you are already using rather than announcing
  // whichever row the catalog happens to list first.
  useEffect(() => {
    if (!open) return;
    const node = pop.current;
    if (!node) return;
    const target =
      node.querySelector<HTMLElement>('[role="menuitemradio"][aria-checked="true"]') ??
      node.querySelector<HTMLElement>('[role="menuitemradio"]');
    target?.focus();
  }, [open]);

  const pick = useCallback(
    (model: ModelDescriptor, level?: EffortLevel) => {
      // The catalog's `value` is the selector set_model takes; session.model may
      // hold the resolved id, which it rejects.
      props.onSetModel(model.value, level ?? clampEffort(model, session.effort));
      close();
    },
    [close, props, session.effort]
  );

  /**
   * Item 7: the wheel over the trigger or the reasoning strip is the effort
   * dial.
   *
   * Wheel UP increases, matching every stepper the OS ships. It goes through
   * `props.onSetModel` — the one path the menu rows use — rather than keeping a
   * second copy of the setting, so the trigger label, the checked level and the
   * CLI can never disagree about what was sent. The panel STAYS OPEN: the
   * gesture is a dial, and closing under the pointer after each notch would make
   * a two-step adjustment impossible.
   *
   * `preventDefault` unconditionally while a tunable model is active, including
   * at the ends of the scale, or the dock scrolls the transcript out from under
   * a reader who was trying to nudge `max` one higher.
   */
  const onWheel = useCallback(
    (event: WheelEvent) => {
      if (!supportsEffort(activeRow)) return;
      // Trackpads emit a stream of small deltas including horizontal noise; only
      // a decisive vertical roll moves the dial.
      if (Math.abs(event.deltaY) < 1 || Math.abs(event.deltaY) < Math.abs(event.deltaX)) return;
      event.preventDefault();
      const next = stepEffort(activeRow, session.effort, event.deltaY < 0 ? 1 : -1);
      if (!next) return;
      props.onSetModel(activeRow.value, next);
    },
    [activeRow, props, session.effort]
  );

  /**
   * Bound NATIVELY, with `{ passive: false }`, rather than as React's `onWheel`.
   *
   * React attaches its wheel listener at the root container as PASSIVE, so
   * `event.preventDefault()` inside an `onWheel` prop is silently a no-op —
   * verified in the browser: the handler ran, the effort changed, and the
   * transcript scrolled out from under the pointer anyway. The gesture only
   * works if the page does not also scroll, so the listener has to be one this
   * component owns.
   *
   * Attached to the trigger AND to the open panel's reasoning strip, which are
   * the two places the gesture is advertised.
   */
  const bindWheel = useCallback(
    (node: HTMLElement | null) => {
      if (!node) return;
      const handler = (event: WheelEvent) => onWheelRef.current(event);
      node.addEventListener("wheel", handler, { passive: false });
      return () => node.removeEventListener("wheel", handler);
    },
    []
  );
  // Read through a ref so the listener is attached once per node rather than
  // torn down and rebound on every effort change.
  const onWheelRef = useRef(onWheel);
  onWheelRef.current = onWheel;

  const levels = supportsEffort(activeRow) ? activeRow.supportedEffortLevels ?? [] : [];

  return (
    <div className="composer-model" ref={root}>
      <button
        ref={(node) => {
          trigger.current = node;
          return bindWheel(node);
        }}
        type="button"
        className={`composer-model-trigger${open ? " is-open" : ""}`}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={copy("supermux.harness.header.model")}
        title={
          supportsEffort(activeRow) ? copy("supermux.harness.model.effortWheelHint") : undefined
        }
        onClick={() => (open ? close() : setOpen(true))}
      >
        <span className="composer-model-label">{modelName}</span>
        {effort ? (
          <span className="composer-model-effort">{effortLabel(effort, copy)}</span>
        ) : null}
        <ChevronDown size={9} />
      </button>

      {open ? (
        <PopoverSurface
          className="pop-model"
          role="menu"
          label={copy("supermux.harness.header.model")}
          surfaceRef={pop}
          onKeyDown={onPopKeyDown}
        >
          <ModelRows
            models={source.models}
            loading={source.loading}
            fallbackName={session.model}
            activeRow={activeRow}
            onPick={pick}
          />
          {levels.length > 0 ? (
            <EffortStrip
              model={activeRow!}
              levels={levels}
              current={effort}
              onPick={(level) => props.onSetModel(activeRow!.value, level)}
              onRestore={(level) => props.onSetModel(activeRow!.value, level)}
              bindWheel={bindWheel}
            />
          ) : null}
        </PopoverSurface>
      ) : null}
    </div>
  );
}

/**
 * "Loading…" that never resolves is the same lie an empty menu tells, just
 * slower. If no catalog has arrived by the time a probe would plainly have
 * failed, name the model the session reports and stop claiming work.
 */
function ModelRows({
  models,
  loading,
  fallbackName,
  activeRow,
  onPick
}: {
  models: ModelDescriptor[];
  loading: boolean;
  fallbackName?: string;
  activeRow?: ModelDescriptor;
  onPick(model: ModelDescriptor): void;
}) {
  const copy = useCopy();
  const [timedOut, setTimedOut] = useState(false);

  useEffect(() => {
    if (!loading) return;
    const timer = window.setTimeout(() => setTimedOut(true), CATALOG_TIMEOUT_MS);
    return () => window.clearTimeout(timer);
  }, [loading]);

  if (loading) {
    if (!timedOut) {
      return (
        <MenuLoading glyph={<Spinner size={11} />}>
          {copy("supermux.harness.header.modelsLoading")}
        </MenuLoading>
      );
    }
    return <MenuEmpty>{fallbackName ?? "—"}</MenuEmpty>;
  }

  if (models.length === 0) return <MenuEmpty>{fallbackName ?? "—"}</MenuEmpty>;

  return (
    <MenuList className="model-rows">
      {models.map((model) => (
        <MenuItem
          key={model.value}
          role="menuitemradio"
          active={model === activeRow}
          className="model-row"
          // NO detail line, deliberately. The catalog ships descriptions ("Opus
          // 5 with a 1M context window") and rendering them doubled every row's
          // height for a list whose rows are already self-explanatory — a
          // decision from the previous round that the compactness bar here only
          // reinforces. The mode menu keeps its detail because "Accept edits"
          // does not say what it lets through; "Opus (1M context)" does.
          onClick={() => onPick(model)}
        >
          {model.displayName}
        </MenuItem>
      ))}
    </MenuList>
  );
}

/**
 * Reasoning, for the ACTIVE model, pinned under a hairline at the panel's foot.
 *
 * A segmented scale rather than a list of rows: the levels are ORDERED, and five
 * checkable rows under a list of four models made the panel read as a nested
 * menu of unrelated options. Being in one fixed place is what lets the wheel and
 * Option+,/. have a visible target — the round-4 build opened a strip under
 * whichever row the pointer touched, so there was no stable thing for a gesture
 * to move.
 */
function EffortStrip({
  model,
  levels,
  current,
  onPick,
  onRestore,
  bindWheel
}: {
  model: ModelDescriptor;
  levels: EffortLevel[];
  current?: EffortLevel;
  onPick(level: EffortLevel): void;
  onRestore(level: EffortLevel | undefined): void;
  /** See ModelMenu: the wheel listener must be non-passive to preventDefault. */
  bindWheel(node: HTMLElement | null): (() => void) | undefined;
}) {
  const copy = useCopy();
  return (
    <MenuSection className="effort-strip" title={copy("supermux.harness.model.reasoning")}>
      {/* A segmented control, so the steps are pressed BUTTONS rather than
          `menuitemradio`s. Two reasons, and the first is not cosmetic: the
          panel's arrow keys walk `menuitemradio`, and folding five effort steps
          into that list would make ↓ from the last model land on "Low" instead
          of wrapping to the first model — the levels are a property of the
          selection, not five more things to select between. Second, "which
          model" and "how hard" are two different questions, and one radio group
          spanning both says they are the same one. Tab still reaches every
          step. */}
      <div
        className="effort-scale"
        role="group"
        aria-label={copy("supermux.harness.model.reasoning")}
        ref={bindWheel}
      >
        {levels.map((option) => (
          <button
            key={option}
            type="button"
            aria-pressed={option === current}
            className={`effort-step${option === current ? " is-active" : ""}`}
            title={
              option === model.defaultEffortLevel
                ? copy("supermux.harness.header.effortDefault")
                : undefined
            }
            onClick={() => onPick(option)}
          >
            {effortLabel(option, copy)}
            {/* States a fact about the option, not its state — it is what
                "Restore defaults" restores to. */}
            {option === model.defaultEffortLevel ? (
              <span className="effort-default-mark" aria-hidden="true" />
            ) : null}
          </button>
        ))}
      </div>
      {/* Offered only when there is something to restore. A catalog that ships
          no `defaultEffortLevel` still has one — "whatever the CLI picks" — and
          restoring to it means sending no level at all, which is why the
          undefined case is a real target rather than a disabled button. */}
      {current !== model.defaultEffortLevel ? (
        <button
          type="button"
          className="effort-restore"
          onClick={() => onRestore(model.defaultEffortLevel)}
        >
          <Undo size={11} />
          {copy("supermux.harness.model.restoreDefaults")}
        </button>
      ) : null}
    </MenuSection>
  );
}
