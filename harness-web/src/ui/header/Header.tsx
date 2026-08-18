import { useEffect, useRef, useState } from "react";
import type { CopyKey } from "../../copyKeys";
import { resolveModel } from "../../model/helpers";
import type { SessionMeta, UsageTotals } from "../../model/types";
import type {
  ContextUsage,
  EffortLevel,
  ModelDescriptor,
  PermissionMode,
  SessionSummary
} from "../../protocol/types";
import { useCopy } from "../CopyContext";
import {
  Bolt,
  ChevronDown,
  Folder,
  History,
  More,
  Plus,
  Scissors,
  Shield,
  Terminal,
  Trash
} from "../Icons";
import { displayDirectory, formatCost, formatRelativeTime } from "../format";
import { Spinner } from "../primitives/Spinner";
import { ContextRing } from "./ContextRing";
import { Menu, MenuItem, MenuSection } from "./Menu";

const MODES: PermissionMode[] = ["default", "acceptEdits", "plan", "bypassPermissions"];

/**
 * Effort is a per-model capability, so it cannot travel across a model switch
 * unchanged: sending `max` to a model that tops out at `high` makes the CLI
 * reject it while the pill keeps advertising a setting that does not exist.
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

export function modeLabel(mode: PermissionMode, copy: ReturnType<typeof useCopy>, short = false): string {
  switch (mode) {
    case "acceptEdits":
      return copy(short ? "supermux.harness.mode.acceptEditsShort" : "supermux.harness.mode.acceptEdits");
    case "plan":
      return copy(short ? "supermux.harness.mode.planShort" : "supermux.harness.mode.plan");
    case "bypassPermissions":
      return copy(
        short ? "supermux.harness.mode.bypassPermissionsShort" : "supermux.harness.mode.bypassPermissions"
      );
    default:
      return copy(short ? "supermux.harness.mode.defaultShort" : "supermux.harness.mode.default");
  }
}

/**
 * The catalog only reaches a pane through the `initialize` handshake of a RUNNING
 * process, so a pane on first open has `session.models = []` and the model menu
 * used to be blank — no rows, no current model, nothing to pick. Three sources
 * in falling order of authority, and a spinner rather than an empty popup when
 * none of them has answered yet.
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
        <div className="menu-loading">
          <Spinner size={11} />
          <span>{copy("supermux.harness.header.modelsLoading")}</span>
        </div>
      );
    }
    return <div className="menu-empty">{fallbackName ?? "—"}</div>;
  }

  return (
    <>
      {models.map((model) => (
        <MenuItem
          key={model.value}
          role="menuitemradio"
          active={model === activeRow}
          detail={model.description}
          onClick={() => onPick(model)}
        >
          {model.displayName}
        </MenuItem>
      ))}
    </>
  );
}

export interface HeaderProps {
  degraded?: boolean;
  session: SessionMeta;
  usage: UsageTotals;
  contextUsage?: ContextUsage;
  workingDirectory?: string;
  sessions: SessionSummary[];
  /** Catalog persisted from an earlier run of this binary; see modelMenuSource. */
  cachedModels?: ModelDescriptor[];
  onRename(title: string): void;
  onSetModel(model: string, effort?: EffortLevel): void;
  onSetPermissionMode(mode: PermissionMode): void;
  onResumeSession(sessionId: string, fork: boolean): void;
  onOpenSessionInNewPane(sessionId: string): void;
  onLoadSessions(): void;
  onCompact(): void;
  onClear(): void;
  onExport(): void;
  onOpenTerminal(): void;
  onNewSession(): void;
  onOpenBinarySettings(): void;
}

export function Header(props: HeaderProps) {
  const copy = useCopy();
  const { session } = props;
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const [sessionQuery, setSessionQuery] = useState("");
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (editing) input.current?.select();
  }, [editing]);

  const title = session.title ?? copy("supermux.harness.app.untitledSession");
  const menuModels = modelMenuSource(session, props.cachedModels);
  // ONE resolution for the pill, the checked row, and the effort submenu. The
  // live catalog is authoritative when a process is up; before the first start
  // `session.models` is empty and only the cached catalog can resolve anything,
  // so a pill reading `activeModelFor(session)` alone printed the raw selector
  // the user had just picked ("opus") beside a menu that had a "Opus 5" row
  // checked. Same catalog, same binary — it resolves the pre-start selection
  // exactly as well as the live one.
  const activeRow = resolveModel(session, menuModels.models);
  const modelName = activeRow?.displayName ?? session.model ?? copy("supermux.harness.header.model");
  // The chip must never outlive the capability it describes: a model that has no
  // effort levels shows no effort tag, whatever the session last carried.
  const effort = clampEffort(activeRow, session.effort);

  const filtered = props.sessions.filter((item) =>
    sessionQuery.trim().length === 0
      ? true
      : `${item.title} ${item.firstPrompt ?? ""}`.toLowerCase().includes(sessionQuery.toLowerCase())
  );

  return (
    <header className="header">
      <div className="header-left">
        {editing ? (
          <input
            ref={input}
            className="title-input"
            value={draft}
            aria-label={copy("supermux.harness.header.rename")}
            title={`${copy("supermux.harness.header.renameSave")} ⏎ · ${copy(
              "supermux.harness.header.renameCancel"
            )} Esc`}
            onChange={(event) => setDraft(event.target.value)}
            onBlur={() => setEditing(false)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                const next = draft.trim();
                if (next) props.onRename(next);
                setEditing(false);
              } else if (event.key === "Escape") {
                event.preventDefault();
                setEditing(false);
              }
            }}
          />
        ) : (
          <button
            type="button"
            className="title-btn"
            onClick={() => {
              setDraft(title);
              setEditing(true);
            }}
            title={copy("supermux.harness.header.rename")}
          >
            <span className="title-text">{title}</span>
          </button>
        )}
        {props.workingDirectory ? (
          <span className="dir-chip mono" title={props.workingDirectory}>
            <Folder size={11} />
            <span className="dir-chip-text">{displayDirectory(props.workingDirectory)}</span>
          </span>
        ) : null}
      </div>

      <div className="header-right">
        {props.degraded ? null : (
          <>
        {props.usage.costUsd > 0 ? (
          <span className="cost-badge tnum" title={copy("supermux.harness.header.cost")}>
            {formatCost(props.usage.costUsd)}
          </span>
        ) : null}

        <ContextRing usage={props.contextUsage} />

        <Menu
          label={copy("supermux.harness.header.permissionMode")}
          trigger={() => (
            <span className={`mode-pill is-${session.permissionMode}`}>
              <Shield size={11} />
              <span className="pill-label">{modeLabel(session.permissionMode, copy, true)}</span>
              <ChevronDown size={10} />
            </span>
          )}
        >
          {(close) => (
            <MenuSection title={copy("supermux.harness.header.permissionMode")}>
              {MODES.map((mode) => (
                <MenuItem
                  key={mode}
                  role="menuitemradio"
                  active={mode === session.permissionMode}
                  icon={<span className={`mode-dot is-${mode}`} />}
                  onClick={() => {
                    props.onSetPermissionMode(mode);
                    close();
                  }}
                >
                  {modeLabel(mode, copy)}
                </MenuItem>
              ))}
            </MenuSection>
          )}
        </Menu>

        <Menu
          label={copy("supermux.harness.header.model")}
          trigger={() => (
            <span className="model-pill">
              <span className="pill-label">{modelName}</span>
              {effort ? <span className="effort-tag">{effortLabel(effort, copy)}</span> : null}
              <ChevronDown size={10} />
            </span>
          )}
        >
          {(close) => (
            <>
              <MenuSection title={copy("supermux.harness.header.model")}>
                {/* A menu that opens on nothing reads as broken; before the
                    first start the catalog is genuinely still on its way. */}
                <ModelRows
                  models={menuModels.models}
                  loading={menuModels.loading}
                  fallbackName={session.model}
                  activeRow={activeRow}
                  onPick={(model) => {
                    props.onSetModel(model.value, clampEffort(model, session.effort));
                    close();
                  }}
                />
              </MenuSection>
              {activeRow?.supportsEffort && activeRow.supportedEffortLevels?.length ? (
                <MenuSection title={copy("supermux.harness.header.effort")}>
                  {activeRow.supportedEffortLevels.map((level) => (
                    <MenuItem
                      key={level}
                      role="menuitemradio"
                      active={level === effort}
                      badge={
                        level === activeRow.defaultEffortLevel
                          ? copy("supermux.harness.header.effortDefault")
                          : undefined
                      }
                      onClick={() => {
                        // The catalog's `value` is the selector set_model takes;
                        // session.model may hold the resolved id, which it rejects.
                        props.onSetModel(activeRow.value, level);
                        close();
                      }}
                    >
                      {effortLabel(level, copy)}
                    </MenuItem>
                  ))}
                </MenuSection>
              ) : null}
            </>
          )}
        </Menu>

          </>
        )}

        <Menu
          label={copy("supermux.harness.header.sessions")}
          className="menu-sessions"
          trigger={() => (
            <span className="icon-pill">
              <History size={13} />
            </span>
          )}
        >
          {(close) => (
            <div className="sessions-pop" onFocus={props.onLoadSessions}>
              <input
                className="sessions-search"
                placeholder={copy("supermux.harness.header.sessionsSearch")}
                value={sessionQuery}
                onChange={(event) => setSessionQuery(event.target.value)}
              />
              {filtered.length === 0 ? (
                <div className="menu-empty">{copy("supermux.harness.header.sessionsEmpty")}</div>
              ) : (
                <ul className="sessions-list">
                  {filtered.slice(0, 24).map((item) => (
                    <li key={item.sessionId} className="session-row">
                      <div className="session-info">
                        <span className="session-title">{item.title}</span>
                        <span className="session-meta tnum">
                          {formatRelativeTime(item.updatedAtMs, copy)}
                          {item.gitBranch ? ` · ${item.gitBranch}` : ""}
                          {item.messageCount ? ` · ${item.messageCount} msgs` : ""}
                        </span>
                      </div>
                      <div className="session-actions">
                        <button
                          type="button"
                          className="btn btn-tiny"
                          title={copy("supermux.harness.header.resumeHint")}
                          onClick={() => {
                            props.onResumeSession(item.sessionId, false);
                            close();
                          }}
                        >
                          {copy("supermux.harness.header.resume")}
                        </button>
                        <button
                          type="button"
                          className="btn btn-tiny btn-ghost"
                          title={copy("supermux.harness.header.forkHint")}
                          onClick={() => {
                            props.onResumeSession(item.sessionId, true);
                            close();
                          }}
                        >
                          {copy("supermux.harness.header.fork")}
                        </button>
                        {/* One live process per pane is by design, so "run two
                            sessions at once" has to be a visible affordance
                            rather than something a user has to infer. */}
                        <button
                          type="button"
                          className="btn btn-tiny btn-ghost"
                          title={copy("supermux.harness.header.openInNewPaneHint")}
                          onClick={() => {
                            props.onOpenSessionInNewPane(item.sessionId);
                            close();
                          }}
                        >
                          {copy("supermux.harness.header.openInNewPane")}
                        </button>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          )}
        </Menu>

        <Menu
          label={copy("supermux.harness.header.more")}
          trigger={() => (
            <span className="icon-pill">
              <More size={13} />
            </span>
          )}
        >
          {(close) => (
            <MenuSection>
              <MenuItem
                icon={<Plus size={12} />}
                onClick={() => {
                  props.onNewSession();
                  close();
                }}
              >
                {copy("supermux.harness.header.newSession")}
              </MenuItem>
              <MenuItem
                icon={<Scissors size={12} />}
                onClick={() => {
                  props.onCompact();
                  close();
                }}
              >
                {copy("supermux.harness.header.compact")}
              </MenuItem>
              <MenuItem
                icon={<History size={12} />}
                onClick={() => {
                  props.onExport();
                  close();
                }}
              >
                {copy("supermux.harness.header.export")}
              </MenuItem>
              <MenuItem
                icon={<Terminal size={12} />}
                onClick={() => {
                  props.onOpenTerminal();
                  close();
                }}
              >
                {copy("supermux.harness.header.openTerminal")}
              </MenuItem>
              <MenuItem
                icon={<Bolt size={12} />}
                onClick={() => {
                  // Focus back to the More trigger BEFORE the dialog mounts: the
                  // dialog captures whatever holds focus so it can return it on
                  // close, and this row is about to unmount with the popover.
                  // Without the handover the dialog captures a detached node and
                  // closing it drops focus onto <body>.
                  close(true);
                  props.onOpenBinarySettings();
                }}
              >
                {copy("supermux.harness.header.binary")}
              </MenuItem>
              <MenuItem
                danger
                icon={<Trash size={12} />}
                onClick={() => {
                  props.onClear();
                  close();
                }}
              >
                {copy("supermux.harness.header.clear")}
              </MenuItem>
            </MenuSection>
          )}
        </Menu>
      </div>
    </header>
  );
}
