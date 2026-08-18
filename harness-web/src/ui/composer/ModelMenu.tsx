import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { CopyKey } from "../../copyKeys";
import { resolveModel } from "../../model/helpers";
import type { SessionMeta } from "../../model/types";
import type { EffortLevel, ModelDescriptor } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { Check, ChevronDown, ChevronRight } from "../Icons";
import { Spinner } from "../primitives/Spinner";

/**
 * The model picker, inside the composer pill.
 *
 * Cursor's grammar, deliberately: a quiet text trigger at the trailing edge of
 * the input — no bed, no icon, just the model's name with its effort folded
 * into the label — opening a popover UPWARD with a search field, one row per
 * model, and a side flyout for the per-model reasoning setting. It lives here
 * rather than in the bottom bar because the model is a property of the message
 * you are about to send, not of the session's chrome.
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

/** Room the flyout needs on the row's right before it has to open on the left. */
const FLYOUT_WIDTH = 200;

function supportsEffort(model: ModelDescriptor): boolean {
  return model.supportsEffort === true && (model.supportedEffortLevels?.length ?? 0) > 0;
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
  const [query, setQuery] = useState("");
  /**
   * The row whose flyout is showing, WITH the offset it was measured at.
   *
   * The flyout is rendered as a sibling of the popover rather than inside the
   * row, because the row list scrolls: a panel absolutely positioned inside a
   * scroller is clipped by it, and the first version of this lost everything
   * past the list's right edge. Anchoring by measured offset keeps it hinged on
   * the row while living outside anything that clips.
   */
  const [flyoutFor, setFlyoutFor] = useState<{ value: string; top: number } | undefined>(
    undefined
  );
  const [levelsOpen, setLevelsOpen] = useState(false);
  const [flipFlyout, setFlipFlyout] = useState(false);
  /** Pixels the flyout is pulled UP by so its foot clears the viewport. */
  const [lift, setLift] = useState(0);
  const root = useRef<HTMLDivElement>(null);
  const pop = useRef<HTMLDivElement>(null);
  const flyout = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const search = useRef<HTMLInputElement>(null);

  const source = modelMenuSource(session, props.cachedModels);
  // ONE resolution for the trigger, the checked row, and the reasoning flyout.
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
    setQuery("");
    setFlyoutFor(undefined);
    setLevelsOpen(false);
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

  // The search field is the point of the popover: it opens with the caret in it
  // so the first keystroke filters rather than falling through to the composer.
  useEffect(() => {
    if (open) search.current?.focus();
  }, [open]);

  // A right-aligned popover sits against the pane's trailing edge, where a
  // right-hand flyout would open off-screen. Measured once per opening rather
  // than guessed from a breakpoint.
  useEffect(() => {
    if (!open) return;
    const rect = pop.current?.getBoundingClientRect();
    if (!rect) return;
    setFlipFlyout(rect.right + FLYOUT_WIDTH > window.innerWidth);
  }, [open]);

  /**
   * The flyout hangs from the row, so a row near the bottom of a long list —
   * and especially one whose levels are open — runs its foot off the bottom of
   * the pane. Opening the levels grows it AFTER it is positioned, so the lift
   * is remeasured whenever either changes, and it only ever pulls up: a flyout
   * that fits is left exactly on its row.
   */
  useLayoutEffect(() => {
    const node = flyout.current;
    if (!node) {
      setLift(0);
      return;
    }
    // The measured rect ALREADY has the current lift applied, so the correction
    // is relative to it — adding `lift` again would compound every pass.
    const overflow = node.getBoundingClientRect().bottom - (window.innerHeight - 8);
    const next = Math.max(0, Math.round(lift + overflow));
    if (next !== lift) setLift(next);
  }, [flyoutFor, levelsOpen, lift]);

  const models = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return source.models;
    return source.models.filter((model) =>
      `${model.displayName} ${model.description ?? ""}`.toLowerCase().includes(needle)
    );
  }, [query, source.models]);

  const pick = useCallback(
    (model: ModelDescriptor, level?: EffortLevel) => {
      // The catalog's `value` is the selector set_model takes; session.model may
      // hold the resolved id, which it rejects.
      props.onSetModel(model.value, level ?? clampEffort(model, session.effort));
      close();
    },
    [close, props, session.effort]
  );

  /** The row the flyout describes, and the effort level THAT model is at. */
  const flyoutRow = models.find(
    (model) => model.value === flyoutFor?.value && supportsEffort(model)
  );
  // Exactly what `pick(model)` would send for this row — the session's level if
  // the row supports it, nothing if it does not. Showing the row's own DEFAULT
  // here instead would have the flyout advertise one level while clicking the
  // row applied another.
  const flyoutEffort = clampEffort(flyoutRow, session.effort);

  // Arrow keys walk the rows and Tab cycles inside the popup: leaving Tab to the
  // browser walks into the send button while the popup stays mounted, which is
  // how a keyboard user ends up operating the composer from a menu row.
  const onPopKeyDown = useCallback((event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp" && event.key !== "Tab") return;
    const stops = Array.from(
      pop.current?.querySelectorAll<HTMLElement>(
        event.key === "Tab"
          ? '[role="menuitemradio"], button:not([disabled]), input:not([disabled])'
          : '[role="menuitemradio"]'
      ) ?? []
    );
    if (stops.length === 0) return;
    event.preventDefault();
    const at = stops.indexOf(document.activeElement as HTMLElement);
    const back = event.key === "ArrowUp" || (event.key === "Tab" && event.shiftKey);
    const next =
      at < 0 ? (back ? stops.length - 1 : 0) : (at + (back ? -1 : 1) + stops.length) % stops.length;
    stops[next].focus();
  }, []);

  return (
    <div className="composer-model" ref={root}>
      <button
        ref={trigger}
        type="button"
        className={`composer-model-trigger${open ? " is-open" : ""}`}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={copy("supermux.harness.header.model")}
        onClick={() => (open ? close() : setOpen(true))}
      >
        <span className="composer-model-label">{modelName}</span>
        {effort ? (
          <span className="composer-model-effort">{effortLabel(effort, copy)}</span>
        ) : null}
        <ChevronDown size={9} />
      </button>

      {open ? (
        <div
          className="model-pop"
          role="menu"
          aria-label={copy("supermux.harness.header.model")}
          ref={pop}
          onKeyDown={onPopKeyDown}
        >
          <input
            ref={search}
            className="model-search"
            placeholder={copy("supermux.harness.model.search")}
            value={query}
            aria-label={copy("supermux.harness.model.search")}
            onChange={(event) => setQuery(event.target.value)}
          />
          <div className="model-rows">
            <ModelRows
              models={models}
              loading={source.loading}
              filtered={query.trim().length > 0}
              fallbackName={session.model}
              activeRow={activeRow}
              flyoutFor={flyoutFor?.value}
              onHover={(value, top) => {
                setFlyoutFor(value === undefined ? undefined : { value, top: top ?? 0 });
                setLevelsOpen(false);
              }}
              onPick={pick}
            />
          </div>

          {/* Outside the scroller, hinged on the measured row. Kept mounted
              while the pointer is over IT as well as over the row, or crossing
              the gap between the two would close it mid-reach. */}
          {flyoutRow ? (
            <div
              ref={flyout}
              className={`model-flyout${flipFlyout ? " is-flipped" : ""}`}
              style={{ top: flyoutFor!.top - lift }}
              onMouseEnter={() => setFlyoutFor(flyoutFor)}
            >
              <div className="model-flyout-title">{flyoutRow.displayName}</div>
              <button
                type="button"
                className="model-flyout-row"
                aria-expanded={levelsOpen}
                onClick={() => setLevelsOpen((v) => !v)}
              >
                <span>{copy("supermux.harness.model.reasoning")}</span>
                <span className="model-flyout-value">
                  {flyoutEffort ? effortLabel(flyoutEffort, copy) : "—"}
                </span>
                <ChevronRight size={10} />
              </button>
              {levelsOpen ? (
                <div className="model-flyout-levels">
                  {(flyoutRow.supportedEffortLevels ?? []).map((level) => (
                    <button
                      key={level}
                      type="button"
                      className={`model-flyout-level${level === flyoutEffort ? " is-active" : ""}`}
                      onClick={() => pick(flyoutRow, level)}
                    >
                      <span>{effortLabel(level, copy)}</span>
                      {/* States a fact about the row, not its state — it is what
                          "Restore defaults" below restores to. */}
                      {level === flyoutRow.defaultEffortLevel ? (
                        <span className="model-flyout-default">
                          {copy("supermux.harness.header.effortDefault")}
                        </span>
                      ) : null}
                      {level === flyoutEffort ? <Check size={11} /> : null}
                    </button>
                  ))}
                </div>
              ) : null}
              <button
                type="button"
                className="model-flyout-row"
                onClick={() => pick(flyoutRow, flyoutRow.defaultEffortLevel)}
              >
                <span>{copy("supermux.harness.model.restoreDefaults")}</span>
              </button>
            </div>
          ) : null}
        </div>
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
  filtered,
  fallbackName,
  activeRow,
  flyoutFor,
  onHover,
  onPick
}: {
  models: ModelDescriptor[];
  loading: boolean;
  /** A search that matched nothing is a different state from no catalog at all. */
  filtered: boolean;
  fallbackName?: string;
  activeRow?: ModelDescriptor;
  flyoutFor?: string;
  /** `top` is the row's offset inside the popover — the flyout's hinge. */
  onHover(value: string | undefined, top?: number): void;
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
        <div className="menu-loading">
          <Spinner size={11} />
          <span>{copy("supermux.harness.header.modelsLoading")}</span>
        </div>
      );
    }
    return <div className="menu-empty">{fallbackName ?? "—"}</div>;
  }

  if (models.length === 0) {
    return (
      <div className="menu-empty">
        {filtered ? copy("supermux.harness.model.noMatches") : (fallbackName ?? "—")}
      </div>
    );
  }

  /** Offset of the row inside the popover, which is the flyout's offset parent. */
  const anchor = (node: HTMLElement | null): number => {
    const pop = node?.closest(".model-pop");
    if (!node || !pop) return 0;
    return node.getBoundingClientRect().top - pop.getBoundingClientRect().top;
  };

  return (
    <>
      {models.map((model) => (
        <div
          key={model.value}
          className="model-row-wrap"
          onMouseEnter={(event) =>
            onHover(model.value, anchor(event.currentTarget))
          }
          onMouseLeave={() => onHover(undefined)}
        >
          <button
            type="button"
            className={`model-row${model === activeRow ? " is-active" : ""}${
              flyoutFor === model.value ? " is-peeked" : ""
            }`}
            role="menuitemradio"
            aria-checked={model === activeRow}
            onFocus={(event) => onHover(model.value, anchor(event.currentTarget.parentElement))}
            onClick={() => onPick(model)}
          >
            <span className="model-row-name">{model.displayName}</span>
            {supportsEffort(model) ? <ChevronRight size={10} className="model-row-more" /> : null}
            {model === activeRow ? <Check size={12} /> : null}
          </button>
        </div>
      ))}
    </>
  );
}
