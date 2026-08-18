import { useCallback, useEffect, useRef, useState } from "react";
import type { CopyKey } from "../../copyKeys";
import { resolveModel } from "../../model/helpers";
import type { SessionMeta } from "../../model/types";
import type { EffortLevel, ModelDescriptor } from "../../protocol/types";
import { useCopy } from "../CopyContext";
import { Check, ChevronDown, Sliders, Undo } from "../Icons";
import { Spinner } from "../primitives/Spinner";

/**
 * The model picker, inside the composer pill.
 *
 * A quiet text trigger at the trailing edge of the input — no bed, no icon, just
 * the model's name with its effort folded into the label — opening ONE compact
 * panel upward. It lives here rather than in the bottom bar because the model is
 * a property of the message you are about to send, not of the session's chrome.
 *
 * The panel is deliberately flat: rows, and nothing else. The previous build put
 * a search field above a list of four models (a filter for a list that fits on
 * screen) and hung a floating side flyout off whichever row the pointer happened
 * to be over, measured and lifted per row so it would not fall off the pane —
 * three positioned layers to change one enum. Reasoning is now an INLINE strip
 * that opens under the row it belongs to, so the panel has exactly one surface,
 * one z-index, and no geometry to get wrong.
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
  /**
   * The one row whose reasoning strip is expanded, by catalog `value`. Inline
   * and single-open: two strips down at once would make the panel taller than
   * the list it is a detail of.
   */
  const [expanded, setExpanded] = useState<string | undefined>(undefined);
  const root = useRef<HTMLDivElement>(null);
  const pop = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);

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
    setExpanded(undefined);
    if (restoreFocus) trigger.current?.focus();
  }, []);

  // The active row's own strip starts open, so the setting the trigger is
  // advertising is the one thing already on screen when the panel appears.
  const openPanel = useCallback(() => {
    setOpen(true);
    setExpanded(activeRow && supportsEffort(activeRow) ? activeRow.value : undefined);
  }, [activeRow]);

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

  // Arrow keys walk the rows and Tab cycles inside the popup: leaving Tab to the
  // browser walks into the send button while the popup stays mounted, which is
  // how a keyboard user ends up operating the composer from a menu row.
  const onPopKeyDown = useCallback((event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp" && event.key !== "Tab") return;
    const stops = Array.from(
      pop.current?.querySelectorAll<HTMLElement>(
        event.key === "Tab"
          ? '[role="menuitemradio"], button:not([disabled])'
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
        onClick={() => (open ? close() : openPanel())}
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
          <ModelRows
            models={source.models}
            loading={source.loading}
            fallbackName={session.model}
            activeRow={activeRow}
            sessionEffort={session.effort}
            expanded={expanded}
            onToggle={(value) => setExpanded((prev) => (prev === value ? undefined : value))}
            onPick={pick}
          />
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
  fallbackName,
  activeRow,
  sessionEffort,
  expanded,
  onToggle,
  onPick
}: {
  models: ModelDescriptor[];
  loading: boolean;
  fallbackName?: string;
  activeRow?: ModelDescriptor;
  sessionEffort?: EffortLevel;
  expanded?: string;
  onToggle(value: string): void;
  onPick(model: ModelDescriptor, level?: EffortLevel): void;
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

  if (models.length === 0) return <div className="menu-empty">{fallbackName ?? "—"}</div>;

  return (
    <div className="model-rows">
      {models.map((model) => {
        const tunable = supportsEffort(model);
        // Exactly what `onPick(model)` would send for this row — the session's
        // level if the row supports it, nothing if it does not. Showing the
        // row's own DEFAULT here instead would have the strip advertise one
        // level while clicking the row applied another.
        const level = clampEffort(model, sessionEffort);
        const isOpen = tunable && expanded === model.value;
        return (
          <div key={model.value} className={`model-row-wrap${isOpen ? " is-open" : ""}`}>
            <div className="model-row-line">
              <button
                type="button"
                className={`model-row${model === activeRow ? " is-active" : ""}`}
                role="menuitemradio"
                aria-checked={model === activeRow}
                onClick={() => onPick(model)}
              >
                <span className="model-check" aria-hidden="true">
                  {model === activeRow ? <Check size={12} /> : null}
                </span>
                <span className="model-row-name">{model.displayName}</span>
                {/* The level the row would apply, stated on the row itself —
                    the old build hid it behind a hover flyout, so the list gave
                    no answer at all to "what reasoning is Sonnet on". */}
                {tunable && level ? (
                  <span className="model-row-effort">{effortLabel(level, copy)}</span>
                ) : null}
              </button>
              {tunable ? (
                <button
                  type="button"
                  className={`model-tune${isOpen ? " is-open" : ""}`}
                  aria-expanded={isOpen}
                  aria-label={copy("supermux.harness.model.reasoning")}
                  title={copy("supermux.harness.model.reasoning")}
                  onClick={() => onToggle(model.value)}
                >
                  <Sliders size={12} />
                </button>
              ) : null}
            </div>

            {isOpen ? (
              <div className="model-efforts">
                {(model.supportedEffortLevels ?? []).map((option) => (
                  <button
                    key={option}
                    type="button"
                    className={`model-effort${option === level ? " is-active" : ""}`}
                    onClick={() => onPick(model, option)}
                  >
                    {effortLabel(option, copy)}
                    {/* States a fact about the option, not its state — it is
                        what "Restore defaults" restores to. */}
                    {option === model.defaultEffortLevel ? (
                      <span className="model-effort-default" aria-hidden="true">
                        ·
                      </span>
                    ) : null}
                  </button>
                ))}
                <button
                  type="button"
                  className="model-restore"
                  title={copy("supermux.harness.header.effortDefault")}
                  onClick={() => onPick(model, model.defaultEffortLevel)}
                >
                  <Undo size={11} />
                  {copy("supermux.harness.model.restoreDefaults")}
                </button>
              </div>
            ) : null}
          </div>
        );
      })}
    </div>
  );
}
